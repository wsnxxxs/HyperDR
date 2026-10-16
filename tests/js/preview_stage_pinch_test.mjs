/* A pinch that starts from the fit view must not fall into press-and-hold
 * compare. The first finger reaches gestures.js and the second is taken by
 * view.js, so this runs both real modules on one stage with a fake clock. */
import assert from "node:assert/strict";
import fs from "node:fs";
const read = path => fs.readFileSync(new URL(`../../apps/panel/web/js/${path}`, import.meta.url), "utf8");
const { createStore } = await import(`data:text/javascript;base64,${Buffer.from(read("core/store.js")).toString("base64")}`);
const geometry = await import(`data:text/javascript;base64,${Buffer.from(read("preview/stage/geometry.js")
  .replace(/^import [\s\S]*?;\r?\n/gm, "") + "\nconst clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));").toString("base64")}`);
async function load(path, dependencies) {
  globalThis.pinchTestDependencies = dependencies;
  const code = `const { ${Object.keys(dependencies).join(", ")} } = globalThis.pinchTestDependencies;\n`
    + read(path).replace(/^import [\s\S]*?;\r?\n/gm, "");
  const module = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
  delete globalThis.pinchTestDependencies;
  return module;
}

const timers = new Map(); let timerId = 0;
const clock = { setTimeout: (fn) => (timers.set(++timerId, fn), timerId), clearTimeout: (id) => timers.delete(id) };
class Element { closest() { return null; } }
const stage = Object.assign(new Element(), {
  listeners: {}, classList: { toggle() {}, add() {}, remove() {} }, style: {},
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
  setPointerCapture() {}, hasPointerCapture: () => false, releasePointerCapture() {}, setAttribute() {},
  dispatch(type, init) {
    let stopped = false;
    const event = { type, button: 0, target: this, ...init,
      preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() { stopped = true; } };
    for (const listener of this.listeners[type] || []) { if (stopped) break; listener(event); }
  },
});
const frame = { clientWidth: 800, clientHeight: 600, getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }) };
const store = createStore({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0, comparing: false });
const shared = { store, t: (key) => key, onLocaleChange() {}, Element, performance: { now: () => 0 }, ...clock };
const { createView } = await load("preview/stage/view.js", { ...shared, setText() {},
  clamp: (v, lo, hi) => Math.min(hi, Math.max(lo, v)), ...geometry });
// A hybrid device: the primary pointer is fine, so the media query says "not touch".
const { createGestures } = await load("preview/stage/gestures.js", { ...shared, touchQuery: { matches: false } });

const ctx = { image: { source: { width: 4, height: 3 } }, dom: { stage, frame },
  actions: { intake: { canReplace: () => true, openPicker() {} } } };
const view = ctx.actions.view = createView(ctx);
const gestures = ctx.actions.gestures = createGestures(ctx);
view.mountPan();        // stage.js mounts the pan before the gestures
gestures.mountPointer();

const touch = (type, pointerId, clientX) =>
  stage.dispatch(type, { pointerType: "touch", pointerId, clientX, clientY: 300 });
touch("pointerdown", 1, 300);
touch("pointerdown", 2, 500);
touch("pointermove", 2, 700);
assert.equal(timers.size, 0, "no press-and-hold timer survives the second finger");
assert.ok(store.get().viewerZoom > 1, "the fingers zoomed the photograph");
assert.equal(store.get().comparing, false, "the pinch never switches to the original");

// A mouse hold on the same device still compares; the decision is per pointer.
store.set({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0 });
stage.dispatch("pointerdown", { pointerType: "mouse", pointerId: 9, clientX: 100, clientY: 100 });
assert.equal(timers.size, 1);
[...timers.values()][0]();
assert.equal(store.get().comparing, true);

console.log("Preview stage pinch: second finger cancels press-and-hold, mouse hold still compares");
