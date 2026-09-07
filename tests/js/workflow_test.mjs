import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs.readFileSync(new URL("../../apps/panel/web/js/settings/workflow.js", import.meta.url), "utf8").replace(/^import .*;\r?\n/gm, "");
const { workflowPatch } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
const original = { encoding: "pq", previewOptimized: true, modelGainReady: true,
  hdrRange: 3, brightness: .3, lutId: "warm", lutInput: "srgb", lutStrength: .7 };
const color = { ...original, ...workflowPatch(original, true) };
assert.equal(color.encoding, "sdr-jpeg");
assert.equal(color.previewOptimized, false);
assert.equal(color.hdrRange, original.hdrRange);
assert.equal(color.brightness, original.brightness);
assert.equal(color.lutId, original.lutId);
assert.equal(color.lutStrength, original.lutStrength);
const hdr = { ...color, ...workflowPatch(color, false) };
assert.equal(hdr.encoding, original.encoding);
assert.equal(hdr.previewOptimized, true);
assert.deepEqual(workflowPatch(color, true), {});
assert.equal(workflowPatch({ ...color, modelGainReady: false }, false).previewOptimized, false);
assert.equal(workflowPatch({ ...color, lutInput: "hlg" }, false).previewOptimized, false);
console.log("Workflow: preserves grade and HDR settings; restores only compatible cached AI");
