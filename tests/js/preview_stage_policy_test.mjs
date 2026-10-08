import assert from "node:assert/strict";
import fs from "node:fs";
const { sdrReasonFor, canReuseRenderer, quantizedPreviewTier } = await import(`data:text/javascript;base64,${fs.readFileSync(
  new URL("../../apps/panel/web/js/preview/stage/policy.js", import.meta.url)).toString("base64")}`);

const capable = { encoding: "adaptive", hdrPreview: true, hdrDisplay: true, secure: true, webgpu: true };
assert.equal(sdrReasonFor(capable), "");
for (const encoding of ["sdr-jpeg", "sdr-tiff"]) {
  assert.equal(sdrReasonFor({ ...capable, encoding, hdrPreview: false, hdrDisplay: false,
    secure: false, webgpu: false }), "hdr.reason.sdrOutput");
}
const vetoes = [
  ["hdrPreview", "hdr.reason.disabledByPreference"],
  ["hdrDisplay", "hdr.reason.sdrScreen"],
  ["secure", "hdr.reason.httpMode"],
  ["webgpu", "hdr.reason.noWebgpu"],
];
for (let i = 0; i < vetoes.length; ++i) {
  const blocked = { ...capable, ...Object.fromEntries(vetoes.slice(i).map(([key]) => [key, false])) };
  assert.equal(sdrReasonFor(blocked), vetoes[i][1], "the first veto owns the diagnostic reason");
}
for (const kind of [null, "hdr", "sdr-gpu"]) {
  assert.equal(canReuseRenderer(true, kind), kind === "hdr");
  assert.equal(canReuseRenderer(false, kind), kind === "sdr-gpu");
}
assert.equal(quantizedPreviewTier(2048, 0, 0, undefined), 960, "empty geometry still requests a tier");
assert.equal(quantizedPreviewTier(2048, 960, 400, 1), 960);
assert.equal(quantizedPreviewTier(2048, 961, 400, 1), 1280);
assert.equal(quantizedPreviewTier(2048, 1280, 400, 1), 1280);
assert.equal(quantizedPreviewTier(2048, 1281, 400, 1), 2048);
assert.equal(quantizedPreviewTier(2048, 400, 1300, 1), 2048, "portrait height chooses the tier");
assert.equal(quantizedPreviewTier(2048, 400, 400, 2), 1280);
assert.equal(quantizedPreviewTier(2048, 700, 400, 4), 2048, "DPR is capped at two");
assert.equal(quantizedPreviewTier(1500, 1400, 900, 1), 1280, "ceilings never create intermediate tiers");
assert.equal(quantizedPreviewTier(800, 1400, 900, 1), 800, "a ceiling below the first tier is respected");
console.log("Preview stage policy: HDR veto precedence, renderer reuse and quantized tiers passed");
