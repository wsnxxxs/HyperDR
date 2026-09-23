/* The editor's interaction rules that are pure decisions: typed slider values,
 * zoom steps, what the header says about the edit, why export is unavailable,
 * which export matches the edit on screen, and shortcut labels. Each module is
 * loaded with its imports replaced by small stubs, as the other tests here do. */
import assert from "node:assert/strict";
import fs from "node:fs";

const source = (path) => fs.readFileSync(new URL(`../../apps/panel/web/js/${path}`, import.meta.url), "utf8")
  .replace(/^import [\s\S]*?;\r?\n/gm, "");
const load = (path, prelude = "", edit = (text) => text) =>
  import(`data:text/javascript;base64,${Buffer.from(prelude + edit(source(path))).toString("base64")}`);

const T = `const t = (key, params) => key === "unit.auto" ? "自动"
  : key === "keys.space" ? "空格" : params ? key + JSON.stringify(params) : key;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));\n`;

/* ── typed slider values ────────────────────────────────────────────── */
const { parseTypedValue, editableValue } = await load("settings/controls.js", T);
const brightness = { key: "brightness", min: 0, max: 2, step: 0.05 };
const strength = { key: "hdrStrength", min: 0, max: 1, step: 0.05, unit: "percent" };
const aiRange = { key: "aiHdrRange", min: -1, max: 3, step: 0.1, auto: true };
const aiStart = { key: "aiExpansionStart", min: -1, max: 0.75, step: 0.01, unit: "percent", auto: true };
const quality = { key: "quality", min: 0, max: 100, step: 1 };

assert.equal(parseTypedValue(brightness, "+0.30 EV"), 0.3, "units are ignored");
assert.equal(parseTypedValue(brightness, "0,45"), 0.45, "a decimal comma is a decimal point");
assert.equal(parseTypedValue(brightness, "0.62"), 0.6, "snapped to the step");
assert.equal(parseTypedValue(brightness, "9"), 2, "clamped to the maximum");
assert.equal(parseTypedValue(brightness, "−1"), 0, "a typographic minus is a minus, then clamped");
assert.equal(parseTypedValue({ ...brightness, min: -2 }, "−1"), -1,
  "HDR exposure accepts a negative trim");
assert.equal(parseTypedValue(brightness, "abc"), null, "nothing numeric changes nothing");
assert.equal(parseTypedValue(strength, "25"), 0.25, "a percentage control takes the displayed number");
assert.equal(parseTypedValue(strength, "40%"), 0.4);
assert.equal(parseTypedValue(aiRange, ""), -1, "an empty auto field means automatic");
assert.equal(parseTypedValue(aiRange, "自动"), -1, "so does the word itself");
assert.equal(parseTypedValue(aiRange, "2.3"), 2.3);
assert.equal(parseTypedValue(aiRange, "5", 2.3), 2.3, "the format ceiling beats the schema maximum");
assert.equal(parseTypedValue(aiStart, "30"), 0.3);
assert.equal(parseTypedValue(quality, "85.4"), 85);
assert.equal(editableValue(brightness, 0.6), "0.60");
assert.equal(editableValue(strength, 0.4), "40");
assert.equal(editableValue(aiRange, -1), "自动");
assert.equal(editableValue(aiRange, 2.5), "2.5");
assert.equal(editableValue(quality, 90), "90");

/* ── zoom steps and the header's document status ────────────────────── */
const editor = await load("ui/editor.js",
  "const currentResult = (state) => state.result && state.result.key === state.key ? state.result : null;\n");
assert.equal(editor.zoomStep(1, 1), 1.25);
assert.equal(editor.zoomStep(1.37, 1), 1.5, "a wheel zoom snaps back onto the grid");
assert.equal(editor.zoomStep(1.37, -1), 1.25);
assert.equal(editor.zoomStep(1.25, -1), 1, "never below fit");
assert.equal(editor.zoomStep(4, 1), 4, "never above the maximum");
const file = { name: "a.arw", size: 1 };
const result = { exportId: "e1", key: "k" };
assert.equal(editor.documentStatus({}).state, "empty");
assert.equal(editor.documentStatus({ file, exports: [] }).key, "workspace.notExported");
assert.equal(editor.documentStatus({ file, exports: [{}], result, key: "other" }).key, "workspace.dirty");
assert.equal(editor.documentStatus({ file, exports: [{}], result, key: "k" }).state, "exported",
  "an export in the workspace is not yet saved");
assert.equal(editor.documentStatus({ file, exports: [{}], result, key: "k", savedExports: { e1: "a.heic" } }).state,
  "saved");

/* ── why export is unavailable ──────────────────────────────────────── */
const { runBlocker } = await load("run/runner.js");
const ready = { capabilities: { ready: true }, file, previewReady: true };
assert.equal(runBlocker(ready), "");
assert.equal(runBlocker({ ...ready, capabilities: null }), "run.reason.booting");
assert.equal(runBlocker({ ...ready, capabilities: { ready: false } }), "run.reason.noConverter");
assert.equal(runBlocker({ ...ready, file: null }), "run.reason.noPhoto");
assert.equal(runBlocker({ ...ready, uploading: true }), "run.reason.uploading");
assert.equal(runBlocker({ ...ready, optimizing: true }), "run.reason.optimizing");
assert.equal(runBlocker({ ...ready, previewReady: false }), "run.reason.preview");
assert.equal(runBlocker({ ...ready, jobId: "j", previewReady: false }), "",
  "a running export reports progress instead of a reason");

/* ── matching exports to the edit ───────────────────────────────────── */
const options = await load("run/options.js", `
  const toOptions = (state) => ({ encoding: state.encoding, brightness: state.brightness, modelId: state.modelId });
  const restoredModelId = (saved) => saved?.modelId || "research-cnn-v1";\n`);
const edit = { encoding: "adaptive", brightness: 0.6, modelId: "research-cnn-v1", previewOptimized: false, sourceDomain: "scene-referred" };
const entry = { id: "e1", options: { encoding: "adaptive", brightness: 0.6, useModel: false } };
assert.equal(options.entryKeyFor(entry, edit), options.exportKeyFor(edit),
  "an export made from these settings matches them");
assert.notEqual(options.entryKeyFor(entry, { ...edit, brightness: 0.8 }), options.exportKeyFor({ ...edit, brightness: 0.8 }),
  "a moved slider no longer matches");
assert.notEqual(options.entryKeyFor({ ...entry, options: { ...entry.options, useModel: true } }, edit),
  options.exportKeyFor(edit), "an AI export is not the manual edit");
const selected = { ...edit, result: { exportId: "e1", optionsKey: options.entryKeyFor(entry, edit) } };
assert.equal(options.currentResult(selected)?.exportId, "e1");
assert.equal(options.currentResult({ ...selected, brightness: 1 }), null);
assert.notEqual(options.exportKeyFor({ ...edit, hevcPreset: "medium" }),
  options.entryKeyFor(entry, { ...edit, hevcPreset: "medium" }),
  "a legacy slow HEIC export does not match the fast setting");
assert.equal(options.exportKeyFor({ ...edit, encoding: "avif-pq", hevcPreset: "medium" }),
  options.exportKeyFor({ ...edit, encoding: "avif-pq", hevcPreset: "slow" }),
  "HEIC speed does not change AVIF export identity");

/* ── shortcut labels follow the platform ────────────────────────────── */
const keysFor = (platform) => load("core/keys.js", T,
  (text) => text.replaceAll("globalThis.navigator", `({ platform: ${JSON.stringify(platform)} })`));
const windows = await keysFor("Win32");
assert.equal(windows.keyLabel("mod+o"), "Ctrl+O");
assert.equal(windows.keyLabel("mod+shift+z"), "Ctrl+Shift+Z");
assert.equal(windows.keyLabel("mod+,"), "Ctrl+,");
assert.equal(windows.keyLabel("space"), "空格");
assert.equal(windows.keyLabel("+ / -"), "+ / −");
const mac = await keysFor("MacIntel");
assert.equal(mac.keyLabel("mod+o"), "⌘O");
assert.equal(mac.keyLabel("mod+shift+z"), "⇧⌘Z");

console.log("Panel interaction: typed values, zoom steps, export status, blockers, matching and shortcut labels passed");
