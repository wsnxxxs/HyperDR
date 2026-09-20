import assert from "node:assert/strict";
import fs from "node:fs";
globalThis.ImageData = class { constructor(width, height) { this.data = new Uint8ClampedArray(width*height*4); } };
const code = fs.readFileSync(new URL("../../apps/panel/web/js/preview/cpu.js", import.meta.url));
const { planeToImageData, renderSdr } = await import(`data:text/javascript;base64,${code.toString("base64")}`);
const base = new Float32Array([.18,.18,.18, .9,.9,.9, 1,1,1]);
const expected = planeToImageData(base,3,1);
assert.equal(expected.data[8],255);
let actual;
const canvas = { getContext: () => ({putImageData: image => { actual = image; }}) };
for (const hdr of [base, base.map(v=>v*4)]) {
  renderSdr(canvas,{frame:{base,hdr,width:3,height:1},original:false});
  assert.deepEqual(actual.data,expected.data,"SDR presentation uses the developed base without a second shoulder");
}
console.log("SDR preview: white preservation and HDR fallback passed");

/* `schema.js` has two dependencies. The i18n catalogue is a translation table,
 * so it is replaced with an identity lookup; `model-ids.js` is a real module
 * with rules worth exercising, so it is inlined by URL rather than restated
 * here -- a copy of the model defaults in this file is exactly how the two would
 * drift apart. */
const dataUrl = (code) =>
  `data:text/javascript;base64,${Buffer.from(code).toString("base64")}`;
const modelIdsUrl = dataUrl(
  fs.readFileSync(new URL("../../apps/panel/web/js/settings/model-ids.js", import.meta.url)));
const schemaText = fs.readFileSync(new URL("../../apps/panel/web/js/settings/schema.js",import.meta.url),"utf8")
  .replace('import { t } from "../i18n/index.js";', 'const t = key => key;')
  .replaceAll('"./model-ids.js"', JSON.stringify(modelIdsUrl));
const {
  neutralSettings, validatedSettings, toOptions, defaultSettings, referenceSettings,
  HDR_SOURCE_DOMAIN, isHdrSource,
} = await import(`data:text/javascript;base64,${Buffer.from(schemaText).toString("base64")}`);
const neutral = neutralSettings("hlg");
assert.equal(neutral.brightness,0);
assert.equal(neutral.hdrStrength,0);
assert.equal(neutral.hdrRange,0);
assert.equal(neutral.contrast,1);
assert.equal(neutral.vibrance,0);
assert.equal(neutral.lutId,"");
assert.deepEqual(validatedSettings(JSON.parse(JSON.stringify(toOptions(neutral)))) ,neutral,
  "saving and restoring a reset must not reintroduce adjustments");
assert.equal(defaultSettings().brightness,.6,"initial enhancement remains a separate choice");
const savedModel = { ...defaultSettings(), modelId: "research-cnn-v1" };
assert.equal(validatedSettings(toOptions(savedModel)).modelId, "research-cnn-v1",
  "model choice survives the same settings round trip as all other controls");
assert.equal(validatedSettings({ encoding: "adaptive" }).modelId, "research-cnn-v1",
  "a pre-selector export restores the incumbent, not the demo default");
console.log("Neutral reset: settings round trip passed");

/* An HDR photograph opens as itself. For it "unchanged" means no exposure
 * offset, full strength of its own highlights and a range that does not cut
 * into them -- not the SDR preset, and not a reset that flattens it to SDR. */
assert.equal(HDR_SOURCE_DOMAIN, "display-referred-hdr");
assert.ok(isHdrSource("display-referred-hdr") && !isHdrSource("display-referred-sdr")
  && !isHdrSource("scene-referred") && !isHdrSource(""));
for (const encoding of ["adaptive", "ultrahdr", "hlg", "pq", "sdr-jpeg"]) {
  const maxRange = { adaptive: 3, ultrahdr: 4, hlg: 2.3, pq: 4, "sdr-jpeg": 4 }[encoding];
  for (const settings of [defaultSettings(encoding, HDR_SOURCE_DOMAIN),
                          neutralSettings(encoding, HDR_SOURCE_DOMAIN),
                          referenceSettings(encoding)]) {
    assert.equal(settings.brightness, 0, `${encoding}: an HDR photo opens without an exposure offset`);
    assert.equal(settings.hdrStrength, 1, `${encoding}: an HDR photo keeps its own highlights`);
    assert.equal(settings.hdrRange, maxRange, `${encoding}: the range ceiling does not cut the photo`);
    assert.equal(settings.contrast, 1);
    assert.equal(settings.vibrance, 0);
    assert.equal(settings.encoding, encoding, "the output format is kept");
  }
  assert.deepEqual(
    validatedSettings(JSON.parse(JSON.stringify(toOptions(neutralSettings(encoding, HDR_SOURCE_DOMAIN))))),
    neutralSettings(encoding, HDR_SOURCE_DOMAIN),
    `${encoding}: saving and restoring an HDR reset must not reintroduce adjustments`);
}
assert.equal(neutralSettings("adaptive", HDR_SOURCE_DOMAIN).lutStrength, 0, "reset still clears the LUT grade");
// SDR and RAW photographs are unaffected: their defaults remain the preset and
// their reset remains neutral. The reference request serves every domain
// because HDR strength and range never move an SDR or RAW base.
for (const domain of ["display-referred-sdr", "scene-referred", ""]) {
  assert.equal(defaultSettings("adaptive", domain).brightness, .6);
  assert.equal(defaultSettings("adaptive", domain).hdrStrength, .4);
  assert.equal(neutralSettings("adaptive", domain).hdrStrength, 0);
}
const reference = referenceSettings("adaptive");
assert.equal(reference.areaCoverage, 0, "the reference adds no area weighting");
assert.equal(reference.lutStrength, 0, "the reference is ungraded");
console.log("HDR source identity defaults passed");
