import assert from 'node:assert/strict';
import fs from 'node:fs';
const source=fs.readFileSync(new URL('../../apps/panel/web/js/preview/packet.js',import.meta.url),'utf8')
  .replace('import { t } from "../i18n/index.js";', 'const t = value => value;');
const {decodePreview,sampleHdr,diagnosticFrame}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const metadata={width:3,height:1,gainWidth:2,gainHeight:1,baseId:'example',gainMin:0,gainMax:2,gainGamma:2,
  baseOffset:.01,alternateOffset:.02,gainWeight:1};
const base=new Float32Array([.1,.2,.3,.4,.5,.6,.7,.8,.9]),gain=new Float32Array([0,1]);
function packet(omitted=false){
 let header=JSON.stringify({...metadata,baseOmitted:omitted});while(header.length%4)header+=' ';
 const size=12+header.length;
 const bytes=new Uint8Array(size+(omitted?gain.byteLength:base.byteLength+gain.byteLength));
 bytes.set(new TextEncoder().encode('HYPREV2\n'));new DataView(bytes.buffer).setUint32(8,header.length,true);
 bytes.set(new TextEncoder().encode(header),12);
 if(!omitted)bytes.set(new Uint8Array(base.buffer),size);
 bytes.set(new Uint8Array(gain.buffer),size+(omitted?0:base.byteLength));return bytes.buffer;
}
const decoded=decodePreview(packet()), delta=decodePreview(packet(true),decoded);
assert.strictEqual(delta.base,decoded.base,'delta retains its exact base');
assert.throws(()=>decodePreview(packet(true)),/previewPixels/);
const actual=sampleHdr(delta,1,[]), multiplier=2**(2*Math.sqrt(.5));
for(let c=0;c<3;c++)assert.ok(Math.abs(actual[c]-((base[3+c]+.01)*multiplier-.02))<1e-6,'interpolate codes before decoding gamma');
assert.equal(diagnosticFrame(delta).hdr.length,9);
assert.deepEqual(delta.hdr,decoded.hdr);
console.log('Compact preview: alignment, delta base, interpolation, offsets and diagnostics passed');
