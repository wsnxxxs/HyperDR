/* Exercise the request boundaries that must survive moving the stage closure. */
import assert from "node:assert/strict";
import fs from "node:fs";
const read = path => fs.readFileSync(new URL(`../../apps/panel/web/js/${path}`, import.meta.url), "utf8");
const { createStore } = await import(`data:text/javascript;base64,${Buffer.from(read("core/store.js")).toString("base64")}`);
const policy = await import(`data:text/javascript;base64,${Buffer.from(read("preview/stage/policy.js")).toString("base64")}`);
let moduleId = 0;
async function load(path, dependencies) {
  globalThis.stageTestDependencies = dependencies;
  const code = `const { ${Object.keys(dependencies).join(", ")} } = globalThis.stageTestDependencies;\n`
    + read(path).replace(/^import [\s\S]*?;\r?\n/gm, "") + `\n// case ${++moduleId}`;
  const module = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
  delete globalThis.stageTestDependencies;
  return module;
}
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
const tick = () => new Promise(resolve => setImmediate(resolve));
const element = () => ({ style: { removeProperty() {} }, classList: { add() {}, remove() {}, toggle() {} },
  dataset: {}, setAttribute() {}, removeAttribute() {}, getBoundingClientRect: () => ({ width: 800, height: 600 }) });
const pixels = label => ({ width: 2, height: 1, base: label, byteLength: 24,
  metadata: { inputDomain: "display-referred-sdr", baseId: label } });
const t = key => key;
const prefs = { get: () => ({ hdrPreview: true }), watch() {} };
let frames;
globalThis.requestAnimationFrame = callback => (frames.push(callback), frames.length);
globalThis.cancelAnimationFrame = () => {};
globalThis.window = { devicePixelRatio: 1, isSecureContext: true, matchMedia: () => ({ matches: true }) };
Object.defineProperty(globalThis, "navigator", { configurable: true, value: { gpu: {} } });
const { createStageContext } = await load("preview/stage/context.js", {
  role: () => ({ ...element(), querySelector: () => element(), closest: () => element() }),
});

function context() {
  const dom = Object.fromEntries(["stage", "frame", "empty", "emptyTitle", "progressBar", "progressText",
    "divider", "hdrCanvas", "sdrCanvas", "originalCanvas", "hdrStatus"].map(key => [key, element()]));
  const ctx = createStageContext({ toast: message => { throw new Error(message); } });
  Object.assign(ctx, { dom,
    previewScheduler: { cancel() {} }, toast: message => { throw new Error(message); },
    refreshScope() {},
    actions: { detail: { closeDetail() {} }, view: { fitStageToImage() {}, paintOriginal() {}, applyZoom() {}, syncView() {} },
      rendering: { setCapability() {}, reportInitialCapability() {}, chooseRenderer: async () => {} } } });
  return ctx;
}

const first = context();
const second = context();
first.invalidateImage();
first.invalidateRenderer();
first.detail.active = true;
assert.equal(second.imageGeneration, 0);
assert.equal(second.rendererGeneration, 0);
assert.equal(second.detail.active, false, "stage mounts never share request epochs or detail state");

async function photoFixture(preview) {
  frames = [];
  const ctx = context();
  const store = createStore({ sessionId: "photo", encoding: "adaptive", capabilities: { previewMaxEdge: 2048 } });
  const { createPhoto } = await load("preview/stage/photo.js", {
    api: { preview }, store, prefs, t, onLocaleChange() {}, setText() {}, previewCeilingPx: () => 2048,
    AI_POST_KEYS: [], CONTROLS: [], defaultSettings: () => ({}), isHdrSource: () => false,
    referenceSettings: encoding => ({ encoding, brightness: 0 }), toOptions: state => ({ ...state }),
    planeToImageData: (label, width, height) => ({ label, width, height }),
    diagnosticFrame: frame => frame, analyse: () => ({}), histogramFromPlane: () => ({}),
    createPreviewScheduler() {}, quantizedPreviewTier: policy.quantizedPreviewTier,
  });
  return { ctx, store, photo: createPhoto(ctx) };
}

for (const boundary of ["reference", "effect", "renderer", "presentation"]) {
  const pending = deferred();
  let calls = 0;
  const fixture = await photoFixture(async () => {
    ++calls;
    return ["reference", "effect"].includes(boundary) ? pending.promise : pixels("effect");
  });
  const { ctx, store, photo } = fixture;
  if (boundary !== "reference") {
    ctx.image.original = { label: "neutral", width: 2, height: 1 };
    ctx.image.originalEdge = 2048;
    ctx.image.source = { label: "previous" };
  }
  if (boundary === "renderer") ctx.actions.rendering.chooseRenderer = () => pending.promise;
  const work = photo.load();
  await tick();
  ctx.invalidateImage();
  pending.resolve(pixels("stale"));
  if (boundary === "presentation") frames.shift()();
  await work;
  assert.notEqual(store.get().previewReady, true, `${boundary}: stale work cannot mark a photo ready`);
  assert.equal(calls, 1, `${boundary}: no extra decode`);
  if (["reference", "effect"].includes(boundary)) assert.equal(ctx.image.frame, null);
  if (boundary !== "reference") assert.equal(ctx.image.original.label, "neutral", "the reference stays independent of the effect");
  if (boundary === "renderer") assert.equal(frames.length, 0, "stale renderer completion skips presentation");
}

async function rendererFixture(createHdrRenderer, createSdrGpuRenderer = () => { throw new Error("No WebGL"); }) {
  frames = [];
  const ctx = context();
  ctx.image.source = {};
  ctx.image.frame = pixels("effect");
  const store = createStore({ encoding: "adaptive" });
  const draws = [];
  const { createRendering } = await load("preview/stage/rendering.js", {
    store, prefs, t, onLocaleChange() {}, setText() {}, effectiveOutputGamut: () => "p3",
    renderSdr: canvas => draws.push(canvas), createHdrRenderer, createSdrGpuRenderer,
    ...policy,
  });
  ctx.actions.view.showingOriginal = () => false;
  return { ctx, draws, rendering: createRendering(ctx) };
}

let created = 0;
let fixture = await rendererFixture(async () => { ++created; });
let work = fixture.rendering.chooseRenderer();
fixture.ctx.invalidateRenderer();
frames.shift()();
await work;
assert.equal(created, 0, "a stale pre-swap-chain animation frame never creates HDR");

const pendingHdr = deferred();
let destroyed = 0;
fixture = await rendererFixture(() => pendingHdr.promise);
work = fixture.rendering.chooseRenderer();
frames.shift()();
await tick();
fixture.ctx.invalidateRenderer();
pendingHdr.resolve({ destroy() { ++destroyed; } });
await work;
assert.equal(destroyed, 1, "discarded HDR renderers release their device resources");
assert.equal(fixture.ctx.renderer, null);

let uploads = 0;
let gpuDraws = 0;
fixture = await rendererFixture(async () => { throw new Error("HDR should be reused"); });
fixture.ctx.renderer = { kind: "hdr", outputColorSpace: "display-p3", upload() { ++uploads; },
  draw(_frame, options) { assert.equal(options.original, false); ++gpuDraws; } };
await fixture.rendering.chooseRenderer();
frames.shift()();
assert.equal(uploads, 1);
assert.equal(gpuDraws, 1, "the effect renderer continues drawing below the original layer");

fixture = await rendererFixture(async () => { throw new Error("HDR must not be probed"); });
const replacement = element();
const oldCanvas = fixture.ctx.dom.sdrCanvas;
oldCanvas.cloneNode = () => replacement;
oldCanvas.replaceWith = canvas => assert.equal(canvas, replacement);
Object.defineProperty(navigator, "gpu", { get() { throw new Error("Fallback must not probe GPU availability"); } });
fixture.rendering.chooseSdrRenderer("hdr.reason.sdrScreen", 0);
frames.shift()();
assert.equal(fixture.ctx.dom.sdrCanvas, replacement);
assert.deepEqual(fixture.draws, [replacement], "CPU draw uses the replacement canvas shared through context");
console.log("Preview stage lifecycle: stale await results, neutral reference, renderer reuse and CPU replacement passed");
