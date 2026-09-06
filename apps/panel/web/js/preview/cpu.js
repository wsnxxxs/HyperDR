/* Last-resort SDR presentation for native float preview planes. */
const contexts = new WeakMap();
const encode8 = (value) => {
  const v = Math.max(0, Math.min(1, value));
  const e = v <= 0.0031308 ? 12.92*v : 1.055*Math.pow(v, 1/2.4)-0.055;
  return Math.round(e * 255);
};

export function planeToImageData(values, width, height) {
  let image;
  try { image = new ImageData(width, height, { colorSpace: "display-p3" }); }
  catch (_) { image = new ImageData(width, height); }
  for (let s = 0, d = 0; s < values.length; s += 3, d += 4) {
    image.data[d] = encode8(values[s]);
    image.data[d+1] = encode8(values[s+1]);
    image.data[d+2] = encode8(values[s+2]);
    image.data[d+3] = 255;
  }
  return image;
}

export function renderSdr(canvas, { frame }) {
  let context = contexts.get(canvas);
  if (!context) {
    context = canvas.getContext("2d", { colorSpace: "display-p3" }) || canvas.getContext("2d");
    contexts.set(canvas, context);
  }
  context.putImageData(planeToImageData(
    frame.base, frame.width, frame.height), 0, 0);
}
