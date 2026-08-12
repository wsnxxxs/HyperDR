/* Last-resort SDR presentation for native float preview planes. */
const contexts = new WeakMap();
const encode8 = (value) => {
  const v = Math.max(0, Math.min(1, value));
  const e = v <= 0.0031308 ? 12.92*v : 1.055*Math.pow(v, 1/2.4)-0.055;
  return Math.round(e * 255);
};
const shoulder = (v) => v <= 0.8 ? v : 0.8 + 0.2*(1-Math.exp(-(v-0.8)/0.2));

export function planeToImageData(values, width, height, foldHdr = false) {
  let image;
  try { image = new ImageData(width, height, { colorSpace: "display-p3" }); }
  catch (_) { image = new ImageData(width, height); }
  for (let s = 0, d = 0; s < values.length; s += 3, d += 4) {
    image.data[d] = encode8(foldHdr ? shoulder(values[s]) : values[s]);
    image.data[d+1] = encode8(foldHdr ? shoulder(values[s+1]) : values[s+1]);
    image.data[d+2] = encode8(foldHdr ? shoulder(values[s+2]) : values[s+2]);
    image.data[d+3] = 255;
  }
  return image;
}

export function renderSdr(canvas, { frame, original }) {
  let context = contexts.get(canvas);
  if (!context) {
    context = canvas.getContext("2d", { colorSpace: "display-p3" }) || canvas.getContext("2d");
    contexts.set(canvas, context);
  }
  context.putImageData(planeToImageData(
    original ? frame.base : frame.hdr, frame.width, frame.height, !original), 0, 0);
}

export const __math = { shoulder };
