import { t } from "../i18n/index.js";
/* v1 full planes and v2 SDR base + encoded monochrome gain. */
export function decodePreview(buffer, previous = null) {
  const bytes = new Uint8Array(buffer);
  const magic = new TextDecoder().decode(bytes.subarray(0, 8));
  const compact = magic === "HYPREV2\n";
  if ((!compact && magic !== "HYPREV1\n") || bytes.length < 12) throw new Error(t("err.previewData"));
  const jsonSize = new DataView(buffer).getUint32(8, true);
  let metadata;
  try { metadata = JSON.parse(new TextDecoder().decode(bytes.subarray(12, 12 + jsonSize))); }
  catch (_) { throw new Error(t("err.previewMeta")); }
  const width = Number(metadata.width), height = Number(metadata.height);
  const count = width * height * 3, offset = 12 + jsonSize;
  const gainCount = Number(metadata.gainWidth) * Number(metadata.gainHeight);
  const omitted = compact && metadata.baseOmitted === true;
  const expected = offset + (compact ? (omitted ? 0 : count) + gainCount : count * 2) * 4;
  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0
      || (compact && (!Number.isInteger(metadata.gainWidth) || metadata.gainWidth <= 0
          || !Number.isInteger(metadata.gainHeight) || metadata.gainHeight <= 0
          || ![metadata.gainMin, metadata.gainMax, metadata.gainGamma, metadata.baseOffset,
               metadata.alternateOffset, metadata.gainWeight ?? 1].every(Number.isFinite) || metadata.gainGamma <= 0))
      || expected !== bytes.length) throw new Error(t("err.previewPixels"));
  const plane = (start, length) => start % 4 === 0
    ? new Float32Array(buffer, start, length)
    : new Float32Array(bytes.slice(start, start + length * 4).buffer);
  if (omitted && (!previous || previous.metadata.baseId !== metadata.baseId
      || previous.width !== width || previous.height !== height)) throw new Error(t("err.previewPixels"));
  const frame = { width, height, metadata, byteLength: bytes.length,
    base: omitted ? previous.base : plane(offset, count) };
  if (!compact) { frame.hdr = plane(offset + count * 4, count); return frame; }
  frame.gain = plane(offset + (omitted ? 0 : count * 4), gainCount);
  let hdr = null;
  Object.defineProperty(frame, "hdr", { get() {
    if (!hdr) {
      hdr = new Float32Array(count);
      const rgb = [0, 0, 0];
      for (let i = 0; i < width * height; i++) { sampleHdr(frame, i, rgb); hdr.set(rgb, i * 3); }
    }
    return hdr;
  } });
  return frame;
}

export function sampleHdr(frame, pixel, rgb) {
  if (!frame.gain) {
    for (let c = 0; c < 3; c++) rgb[c] = frame.hdr[pixel * 3 + c];
    return rgb;
  }
  const m = frame.metadata, gw = m.gainWidth, gh = m.gainHeight;
  const x = Math.max(0, Math.min(gw - 1, (pixel % frame.width + .5) * gw / frame.width - .5));
  const y = Math.max(0, Math.min(gh - 1, (Math.floor(pixel / frame.width) + .5) * gh / frame.height - .5));
  const x0 = Math.floor(x), y0 = Math.floor(y), x1 = Math.min(x0 + 1, gw - 1), y1 = Math.min(y0 + 1, gh - 1);
  const mix = (a, b, w) => a + (b - a) * w;
  const code = Math.max(0, Math.min(1, mix(
    mix(frame.gain[y0*gw+x0], frame.gain[y0*gw+x1], x-x0),
    mix(frame.gain[y1*gw+x0], frame.gain[y1*gw+x1], x-x0), y-y0)));
  const multiplier = 2 ** ((m.gainMin + (m.gainMax - m.gainMin) * code ** (1 / m.gainGamma)) * (m.gainWeight ?? 1));
  for (let c = 0; c < 3; c++) rgb[c] = Math.max(0, (frame.base[pixel*3+c] + m.baseOffset) * multiplier - m.alternateOffset);
  return rgb;
}

// Diagnostics sample native linear pixels without allocating a full HDR plane.
export function diagnosticFrame(frame, maxEdge = 320) {
  const scale = Math.min(1, maxEdge / Math.max(frame.width, frame.height));
  const width = Math.max(1, Math.round(frame.width * scale)), height = Math.max(1, Math.round(frame.height * scale));
  const base = new Float32Array(width * height * 3), hdr = new Float32Array(base.length), rgb = [0, 0, 0];
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const sx = Math.min(frame.width-1, Math.floor((x+.5)*frame.width/width));
    const sy = Math.min(frame.height-1, Math.floor((y+.5)*frame.height/height));
    const pixel = sy * frame.width + sx, dst = (y * width + x) * 3;
    base.set(frame.base.subarray(pixel*3, pixel*3+3), dst);
    sampleHdr(frame, pixel, rgb); hdr.set(rgb, dst);
  }
  return { width, height, base, hdr, metadata: frame.metadata };
}
