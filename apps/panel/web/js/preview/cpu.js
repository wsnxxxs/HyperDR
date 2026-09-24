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
  const outputP3 = image.colorSpace === "display-p3";
  for (let s = 0, d = 0; s < values.length; s += 3, d += 4) {
    const r = values[s], g = values[s+1], b = values[s+2];
    // ImageData defaults to sRGB on older browsers. Convert the native linear
    // Display-P3 pixels before transfer encoding instead of relabelling them.
    image.data[d] = encode8(outputP3 ? r : 1.2249401*r - 0.2249401*g);
    image.data[d+1] = encode8(outputP3 ? g : -0.0420569*r + 1.0420569*g);
    image.data[d+2] = encode8(outputP3 ? b : -0.0196376*r - 0.0786361*g + 1.0982737*b);
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
