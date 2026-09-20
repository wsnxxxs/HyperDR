import assert from "node:assert/strict";
import fs from "node:fs";

const source = (path) => fs.readFileSync(new URL(path, import.meta.url), "utf8");
const html = source("../../apps/panel/web/index.html");
const aiStart = html.indexOf('data-role="submenu-ai"');
const aiEnd = html.indexOf('data-role="lut-panel"', aiStart);
for (const name of ["model-field", "model-select", "model-hint", "model-note"]) {
  const position = html.indexOf(`data-role="${name}"`);
  assert.ok(position > aiStart && position < aiEnd,
    `${name} belongs inside AI settings, not above the mode toggle`);
}
const url = (text) => `data:text/javascript;base64,${Buffer.from(text).toString("base64")}`;
const storeUrl = url(source("../../apps/panel/web/js/core/store.js"));
const idsUrl = url(source("../../apps/panel/web/js/settings/model-ids.js"));
// Minimal DOM boundary; mount the actual selector and actual store listeners.
const domUrl = url(`
  const nodes = new Map();
  export function el(tag, attrs = {}, text = '') {
    return { tag, ...attrs, textContent: text, children: [], hidden: false,
      append(child) { this.children.push(child); },
      replaceChildren() { this.children = []; },
      addEventListener(name, fn) { this[name] = fn; },
      removeAttribute(name) { delete this[name]; },
    };
  }
  export function role(name) {
    if (!nodes.has(name)) nodes.set(name, el('div'));
    return nodes.get(name);
  }
  export function setText(node, value) { node.textContent = value; }
`);
const i18nUrl = url("export const t = key => key; export const onLocaleChange = () => {};");
const selectorUrl = url(source("../../apps/panel/web/js/settings/model-select.js")
  .replace('"../core/store.js"', JSON.stringify(storeUrl))
  .replace('"../core/dom.js"', JSON.stringify(domUrl))
  .replace('"../i18n/index.js"', JSON.stringify(i18nUrl))
  .replace('"./model-ids.js"', JSON.stringify(idsUrl)));
const { store } = await import(storeUrl);
const { role } = await import(domUrl);
const { mountModelSelect } = await import(selectorUrl);
store.set({ modelId: "research-exif-v1" });
const selector = mountModelSelect();
store.set({ capabilities: { model: { models: [
  { id: "production-v3", displayName: "Production", available: true },
  { id: "research-cnn-v1", displayName: "CNN", available: true },
  { id: "research-exif-v1", displayName: "EXIF", available: true },
] } } });
assert.deepEqual(role("model-select").children.map((node) => node.textContent),
  ["CNN"], "photos without EXIF only offer CNN");
assert.equal(store.get().modelId, "research-cnn-v1");
assert.equal(role("model-field").hidden, true);
store.set({ hasCaptureMetadata: true });
assert.deepEqual(role("model-select").children.map((node) => node.textContent), ["CNN", "EXIF"]);
assert.equal(role("model-field").hidden, false);
store.set({ modelId: "research-exif-v1" });
assert.equal(selector.restoredId({ modelId: "research-cnn-v1" }), "research-cnn-v1");
for (const busy of ["uploading", "restoring", "starting", "optimizing", "jobId"]) {
  store.set({ [busy]: true });
  assert.equal(role("model-select").disabled, true, `${busy} locks selection`);
  store.set({ [busy]: false });
}
store.set({ previewOptimized: true, modelIdentity: {
  requestedModelId: "research-cnn-v1", effectiveModelId: "research-cnn-v1",
} });
assert.equal(role("model-note").hidden, true, "old identity cannot label the new selection");
store.set({ modelIdentity: {
  requestedModelId: "research-exif-v1", effectiveModelId: "research-cnn-v1",
  inferenceMode: "pixel_only_fallback", fallbackReason: "missing_capture_fields:iso",
} });
assert.equal(role("model-note").hidden, false);
assert.equal(role("model-select").value, "research-exif-v1", "fallback keeps the requested model selected");
store.set({ hasCaptureMetadata: false });
assert.equal(store.get().modelId, "research-cnn-v1", "switching to a photo without EXIF selects CNN");
assert.equal(role("model-select").children.length, 1);
store.set({ modelId: "production-v3" });
assert.equal(store.get().modelId, "research-cnn-v1", "legacy restoration must use a visible model");
console.log("Model selector: capability mount, busy states, restoration and fallback identity passed");
