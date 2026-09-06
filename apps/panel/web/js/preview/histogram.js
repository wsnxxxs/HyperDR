/* Fixed photographic coordinates: SDR gets 70%, HDR gets 30% (+0..4 EV).
 * Bins come from linear pixels, never display mapping. */
export const HISTOGRAM_BINS = 256;
export const SDR_WIDTH = 0.7;
export const HDR_STOPS = 4;
const P3_LUMA = [0.2289746, 0.6917385, 0.0792869];

function decodeTone(v) {
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

export function toneToNorm(value) {
  const v = Math.max(0, value);
  return v <= 1
    ? SDR_WIDTH * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055)
    : Math.min(1, SDR_WIDTH + (1 - SDR_WIDTH) * Math.log2(v) / HDR_STOPS);
}

export function emptyHistogram(total = 0) {
  return { total, luma: new Uint32Array(HISTOGRAM_BINS),
    red: new Uint32Array(HISTOGRAM_BINS), green: new Uint32Array(HISTOGRAM_BINS),
    blue: new Uint32Array(HISTOGRAM_BINS) };
}

function addPixel(hist, r, g, b) {
  const y = P3_LUMA[0] * r + P3_LUMA[1] * g + P3_LUMA[2] * b;
  for (const [channel, value] of [["red", r], ["green", g], ["blue", b], ["luma", y]]) {
    const bin = Math.min(HISTOGRAM_BINS - 1, Math.floor(toneToNorm(value) * HISTOGRAM_BINS));
    hist[channel][bin]++;
  }
}

export function histogramFromPlane(values, width, height) {
  const hist = emptyHistogram(width * height);
  for (let p = 0; p < values.length; p += 3) {
    addPixel(hist, ...[values[p], values[p + 1], values[p + 2]].map(v => Number.isFinite(v) ? Math.max(0, v) : 0));
  }
  return hist;
}

export function histogramFromDisplayImage(source) {
  const hist = emptyHistogram(source.data.length / 4);
  for (let p = 0; p < source.data.length; p += 4) {
    addPixel(hist, ...[source.data[p], source.data[p + 1], source.data[p + 2]].map(v => decodeTone(v / 255)));
  }
  return hist;
}

// Light smoothing is for the drawing only. Statistics use unsmoothed counts.
export function distribution(hist, channel) {
  const counts = hist[channel];
  return Array.from(counts, (n, i) => (
    counts[Math.max(0, i - 1)] + 2 * n + counts[Math.min(counts.length - 1, i + 1)]
  ) / (4 * Math.max(1, hist.total)));
}
