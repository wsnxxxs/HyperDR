import assert from "node:assert/strict";
import fs from "node:fs";
const { sdrReasonFor, canReuseRenderer } = await import(`data:text/javascript;base64,${fs.readFileSync(
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
console.log("Preview stage policy: HDR veto precedence and renderer reuse passed");
