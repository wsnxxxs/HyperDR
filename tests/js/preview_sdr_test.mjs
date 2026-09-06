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

const schemaText = fs.readFileSync(new URL("../../apps/panel/web/js/settings/schema.js",import.meta.url),"utf8")
  .replace('import { t } from "../i18n/index.js";', 'const t = key => key;');
const { neutralSettings, validatedSettings, toOptions, defaultSettings } = await import(`data:text/javascript;base64,${Buffer.from(schemaText).toString("base64")}`);
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
console.log("Neutral reset: settings round trip passed");
