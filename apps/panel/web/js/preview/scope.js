/* Histogram and the zebra overlays.
 *
 * The old graph showed only the source distribution, so a slider move was
 * answered by nothing but the pixels -- and on an SDR screen, by nothing at
 * all once the shoulder had folded the highlights back. This one draws the
 * simulated output distribution over the source: the graph answers "what is
 * this doing to the tones" even where the display cannot.
 *
 * The zebra pair is split into two independent overlays, hot and cold. They
 * used to be one switch behind three buttons, all doing the same thing.
 */

import { role, setPressed, setText, readColor } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { store } from "../core/store.js";

const P3_LUMA = [0.2289746, 0.6917385, 0.0792869];
const HISTOGRAM_BINS = 256;

function clampBin(value) {
  return Math.max(0, Math.min(HISTOGRAM_BINS - 1, Math.round(value)));
}

function decodeDisplaySample(value) {
  const v = value / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

function emptyHistogram(total = 0) {
  return {
    luma: new Uint32Array(HISTOGRAM_BINS),
    red: new Uint32Array(HISTOGRAM_BINS),
    green: new Uint32Array(HISTOGRAM_BINS),
    blue: new Uint32Array(HISTOGRAM_BINS),
    total,
  };
}

/**
 * Maps a linear scene light value (0 .. rangeLinear) to normalized chart position (0 .. 1)
 * using a hybrid perceptual sRGB (SDR) and logarithmic (HDR headroom) scale.
 */
function toneToNorm(value, rangeLinear = 1) {
  const v = Math.max(0, Number.isFinite(value) ? value : 0);
  const maxRange = Math.max(1, Number.isFinite(rangeLinear) ? rangeLinear : 1);
  const stops = Math.log2(maxRange);

  if (stops <= 1e-4) {
    // Standard SDR: perceptual sRGB gamma tone curve
    return v <= 0.0031308
      ? 12.92 * v
      : Math.min(1, 1.055 * Math.pow(v, 1 / 2.4) - 0.055);
  }

  // Dynamic allocation: SDR (0..1) occupies ~60% of horizontal space,
  // remaining space is evenly distributed per EV stop of HDR headroom.
  const wSdr = Math.max(0.48, Math.min(0.72, 1 / (1 + 0.35 * stops)));

  if (v <= 1.0) {
    const srgb = v <= 0.0031308
      ? 12.92 * v
      : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
    return Math.min(wSdr, Math.max(0, srgb * wSdr));
  } else {
    const stopOffset = Math.log2(v) / stops;
    return Math.min(1, wSdr + (1 - wSdr) * Math.max(0, stopOffset));
  }
}

function histogramFromPlane(values, width, height, rangeLinear) {
  const total = width * height;
  const histogram = emptyHistogram(total);
  const maxLinear = Math.max(rangeLinear, 1);
  for (let p = 0; p < values.length; p += 3) {
    const r = Math.max(0, Number.isFinite(values[p]) ? values[p] : 0);
    const g = Math.max(0, Number.isFinite(values[p + 1]) ? values[p + 1] : 0);
    const b = Math.max(0, Number.isFinite(values[p + 2]) ? values[p + 2] : 0);
    const luma = P3_LUMA[0] * r + P3_LUMA[1] * g + P3_LUMA[2] * b;
    histogram.red[clampBin(toneToNorm(r, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.green[clampBin(toneToNorm(g, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.blue[clampBin(toneToNorm(b, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.luma[clampBin(toneToNorm(luma, maxLinear) * (HISTOGRAM_BINS - 1))]++;
  }
  return histogram;
}

function histogramFromDisplayImage(source, rangeLinear) {
  const data = source.data;
  const histogram = emptyHistogram(data.length / 4);
  const maxLinear = Math.max(rangeLinear, 1);
  for (let p = 0; p < data.length; p += 4) {
    const r = decodeDisplaySample(data[p]);
    const g = decodeDisplaySample(data[p + 1]);
    const b = decodeDisplaySample(data[p + 2]);
    const luma = P3_LUMA[0] * r + P3_LUMA[1] * g + P3_LUMA[2] * b;
    histogram.red[clampBin(toneToNorm(r, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.green[clampBin(toneToNorm(g, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.blue[clampBin(toneToNorm(b, maxLinear) * (HISTOGRAM_BINS - 1))]++;
    histogram.luma[clampBin(toneToNorm(luma, maxLinear) * (HISTOGRAM_BINS - 1))]++;
  }
  return histogram;
}

/* One pass over the source plus the native output planes: luma + per-channel
 * counts and zebra masks. The histogram is deliberately computed from
 * the linear Float32 contract, never from the browser's folded 8-bit display
 * copy. The masks are painted with token colours read at call time, so a theme
 * flip between images cannot leave yesterday's red on today's photo. */
export function analyse(source, rendered = null) {
  // Keep the original two-argument export shape for small integrations while
  // accepting the native frame and its linear display range as optional
  // trailing arguments from the stage.
  const frame = arguments[2] || null;
  const rangeLinear = Number.isFinite(arguments[3]) ? arguments[3] : 1;
  const data = source.data;
  const { width } = source;
  const height = source.height;
  const zebraHot = new ImageData(width, source.height);
  const zebraCold = new ImageData(width, source.height);
  const hotColor = readColor("--zebra-hot");
  const coldColor = readColor("--zebra-cold");

  for (let p = 0, i = 0; p < data.length; p += 4, i++) {
    const r = data[p], g = data[p + 1], b = data[p + 2];
    const output = frame?.hdr;
    const outputPeak = output
      ? Math.max(output[i * 3], output[i * 3 + 1], output[i * 3 + 2])
      : Math.max(r, g, b) / 255;
    const outputLuma = output
      ? P3_LUMA[0] * output[i * 3]
        + P3_LUMA[1] * output[i * 3 + 1]
        + P3_LUMA[2] * output[i * 3 + 2]
      : (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    const isHot = outputPeak >= Math.max(1, rangeLinear) * 0.999;
    const isCold = outputLuma <= 1e-6;
    if (!isHot && !isCold) continue;

    // Diagonal stripes, so the overlay reads as a marking rather than a fill.
    const x = i % width;
    const row = (i / width) | 0;
    if ((x + row) % 8 >= 3) continue;
    const o = i * 4;
    const target = isHot ? zebraHot.data : zebraCold.data;
    const color = isHot ? hotColor : coldColor;
    target[o] = color.r;
    target[o + 1] = color.g;
    target[o + 2] = color.b;
    target[o + 3] = 235;
  }

  const histogram = frame?.base
    ? histogramFromPlane(frame.base, frame.width, frame.height, rangeLinear)
    : histogramFromDisplayImage(source, rangeLinear);
  const renderedHistogram = frame?.hdr
    ? histogramFromPlane(frame.hdr, frame.width, frame.height, rangeLinear)
    : rendered ? histogramFromDisplayImage(rendered, rangeLinear) : null;
  return {
    source,
    histogram,
    zebraHot,
    zebraCold,
    renderedHistogram,
    rangeLinear: Math.max(rangeLinear, 1),
  };
}

const PALETTE_KEYS = ["grid", "luma", "red", "green", "blue", "marker", "output"];

function readPalette() {
  const palette = {};
  for (const key of PALETTE_KEYS) palette[key] = readColor(`--hist-${key}`).css;
  return palette;
}

/**
 * Applies a 5-tap Gaussian/binomial smoothing filter to eliminate single-bin
 * discrete jitter while preserving tone distribution peaks.
 */
function smoothCounts(counts) {
  if (!counts) return null;
  const n = counts.length;
  const smoothed = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const c0 = counts[Math.max(0, i - 2)];
    const c1 = counts[Math.max(0, i - 1)];
    const c2 = counts[i];
    const c3 = counts[Math.min(n - 1, i + 1)];
    const c4 = counts[Math.min(n - 1, i + 2)];
    smoothed[i] = (c0 + 4 * c1 + 6 * c2 + 4 * c3 + c4) / 16;
  }
  return smoothed;
}

function getSeriesPeak(seriesList) {
  let max = 0;
  for (const series of seriesList) {
    if (!series) continue;
    for (let i = 0; i < series.length; i++) {
      if (series[i] > max) max = series[i];
    }
  }
  return Math.max(max, 1);
}

function computePoints(counts, max, width, height) {
  const pts = [];
  const len = counts.length;
  for (let i = 0; i < len; i++) {
    const x = (i / (len - 1)) * width;
    const v = Math.min(1, counts[i] / max);
    // Smooth root scaling so peaks remain well-proportioned
    const h = v > 0 ? Math.pow(v, 0.62) * (height - 3) : 0;
    pts.push({ x, y: height - h });
  }
  return pts;
}

function drawSmoothPath(context, pts, closeToBottom = false, height = 0) {
  if (!pts || pts.length === 0) return;
  context.beginPath();
  if (closeToBottom) {
    context.moveTo(pts[0].x, height);
    context.lineTo(pts[0].x, pts[0].y);
  } else {
    context.moveTo(pts[0].x, pts[0].y);
  }
  for (let i = 0; i < pts.length - 1; i++) {
    const xc = (pts[i].x + pts[i + 1].x) / 2;
    const yc = (pts[i].y + pts[i + 1].y) / 2;
    context.quadraticCurveTo(pts[i].x, pts[i].y, xc, yc);
  }
  context.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
  if (closeToBottom) {
    context.lineTo(pts[pts.length - 1].x, height);
    context.closePath();
  }
}

export function mountScope({ analysis }) {
  const canvas = role("histogram");
  const zebraHotCanvas = role("canvas-zebra-hot");
  const zebraColdCanvas = role("canvas-zebra-cold");
  const histMode = role("hist-mode");

  const modes = [["luma", "scope.luma"], ["rgb", "scope.rgb"]];
  const modeButtons = modes.map(([id, labelKey]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.textContent = t(labelKey);
    button.addEventListener("click", () => store.set({ histMode: id }));
    histMode.append(button);
    return [id, button];
  });
  // Built once and mutated thereafter, so a language change has to be pushed
  // in rather than re-rendered.
  onLocaleChange(() => {
    for (const [index, [, button]] of modeButtons.entries()) {
      setText(button, t(modes[index][1]));
    }
  });


  function draw() {
    const data = analysis.current;
    if (!data) return;
    const state = store.get();
    const context = canvas.getContext("2d");
    const { width, height } = canvas;
    const palette = readPalette();
    context.clearRect(0, 0, width, height);

    const rangeLinear = data.rangeLinear || 1;
    const stops = Math.log2(rangeLinear);

    // --- Dynamic Photographic & EV Grid ---
    context.lineWidth = 1;
    if (stops > 0.05) {
      // 1. SDR boundary (0 EV / 1.0 scene light)
      const xSdr = toneToNorm(1.0, rangeLinear) * width;
      context.strokeStyle = palette.grid;
      context.beginPath();
      context.moveTo(xSdr + 0.5, 0);
      context.lineTo(xSdr + 0.5, height);
      context.stroke();

      // Label SDR boundary
      context.font = "9px -apple-system, BlinkMacSystemFont, sans-serif";
      context.fillStyle = palette.luma;
      context.globalAlpha = 0.6;
      context.fillText("SDR", Math.max(4, xSdr - 22), 10);
      context.globalAlpha = 1;

      // 2. HDR EV Stop landmarks (+1 EV, +2 EV, ...)
      const maxStop = Math.floor(stops);
      for (let k = 1; k <= maxStop; k++) {
        const xStop = toneToNorm(2 ** k, rangeLinear) * width;
        context.strokeStyle = palette.grid;
        context.setLineDash([2, 3]);
        context.beginPath();
        context.moveTo(xStop + 0.5, 0);
        context.lineTo(xStop + 0.5, height);
        context.stroke();
        context.setLineDash([]);

        context.font = "9px -apple-system, BlinkMacSystemFont, sans-serif";
        context.fillStyle = palette.output;
        context.globalAlpha = 0.75;
        context.fillText(`+${k}EV`, xStop + 2, 10);
        context.globalAlpha = 1;
      }

      // 3. Middle gray landmark (18% in SDR zone)
      const xMid = toneToNorm(0.18, rangeLinear) * width;
      context.strokeStyle = palette.grid;
      context.setLineDash([1, 4]);
      context.beginPath();
      context.moveTo(xMid + 0.5, 0);
      context.lineTo(xMid + 0.5, height);
      context.stroke();
      context.setLineDash([]);
    } else {
      // Standard SDR Quarter grid
      context.strokeStyle = palette.grid;
      for (let g = 1; g < 4; g++) {
        const x = ((width * g) / 4) | 0;
        context.beginPath();
        context.moveTo(x + 0.5, 0);
        context.lineTo(x + 0.5, height);
        context.stroke();
      }
    }

    const { histogram } = data;
    if (state.histMode === "rgb") {
      const srcR = smoothCounts(histogram.red);
      const srcG = smoothCounts(histogram.green);
      const srcB = smoothCounts(histogram.blue);

      const outR = smoothCounts(data.renderedHistogram?.red || histogram.red);
      const outG = smoothCounts(data.renderedHistogram?.green || histogram.green);
      const outB = smoothCounts(data.renderedHistogram?.blue || histogram.blue);

      const max = getSeriesPeak([srcR, srcG, srcB, outR, outG, outB]);

      const ptsSrcR = computePoints(srcR, max, width, height);
      const ptsSrcG = computePoints(srcG, max, width, height);
      const ptsSrcB = computePoints(srcB, max, width, height);

      const ptsOutR = computePoints(outR, max, width, height);
      const ptsOutG = computePoints(outG, max, width, height);
      const ptsOutB = computePoints(outB, max, width, height);

      // Translucent channel area fills
      context.globalCompositeOperation = "screen";
      context.globalAlpha = 0.22;

      context.fillStyle = palette.red;
      drawSmoothPath(context, ptsOutR, true, height);
      context.fill();

      context.fillStyle = palette.green;
      drawSmoothPath(context, ptsOutG, true, height);
      context.fill();

      context.fillStyle = palette.blue;
      drawSmoothPath(context, ptsOutB, true, height);
      context.fill();

      context.globalCompositeOperation = "source-over";

      // If rendered differs from source, draw source outline subtly
      if (data.renderedHistogram) {
        context.globalAlpha = 0.75;
        context.lineWidth = 1.3;
        context.setLineDash([4, 3]);

        context.strokeStyle = palette.red;
        drawSmoothPath(context, ptsSrcR, false, height);
        context.stroke();

        context.strokeStyle = palette.green;
        drawSmoothPath(context, ptsSrcG, false, height);
        context.stroke();

        context.strokeStyle = palette.blue;
        drawSmoothPath(context, ptsSrcB, false, height);
        context.stroke();

        context.setLineDash([]);
      }

      // Crisp output channel strokes
      context.globalAlpha = 0.95;
      context.lineWidth = 1.6;

      context.strokeStyle = palette.red;
      drawSmoothPath(context, ptsOutR, false, height);
      context.stroke();

      context.strokeStyle = palette.green;
      drawSmoothPath(context, ptsOutG, false, height);
      context.stroke();

      context.strokeStyle = palette.blue;
      drawSmoothPath(context, ptsOutB, false, height);
      context.stroke();

      context.globalAlpha = 1;
    } else {
      const srcLuma = smoothCounts(histogram.luma);
      const outLuma = smoothCounts(data.renderedHistogram?.luma || histogram.luma);
      const max = getSeriesPeak([srcLuma, outLuma]);

      const ptsSrc = computePoints(srcLuma, max, width, height);
      const ptsOut = computePoints(outLuma, max, width, height);

      // 1. Source distribution base fill (slate cool tone)
      context.fillStyle = palette.luma;
      context.globalAlpha = 0.30;
      drawSmoothPath(context, ptsSrc, true, height);
      context.fill();

      // 2. Source distribution outline
      context.strokeStyle = palette.luma;
      context.globalAlpha = 0.9;
      context.lineWidth = 1.4;
      context.setLineDash([4, 3]);
      drawSmoothPath(context, ptsSrc, false, height);
      context.stroke();
      context.setLineDash([]);

      // 3. HDR Output distribution (Warm Amber highlight expansion)
      if (data.renderedHistogram) {
        // Output fill with warm gradient
        const grad = context.createLinearGradient(0, 0, 0, height);
        grad.addColorStop(0, "rgba(245, 158, 11, 0.28)");
        grad.addColorStop(1, "rgba(245, 158, 11, 0.04)");
        context.fillStyle = grad;
        context.globalAlpha = 0.85;
        drawSmoothPath(context, ptsOut, true, height);
        context.fill();

        // Output crisp amber stroke
        context.strokeStyle = palette.output || "#f59e0b";
        context.globalAlpha = 1;
        context.lineWidth = 1.8;
        drawSmoothPath(context, ptsOut, false, height);
        context.stroke();
      } else {
        context.globalAlpha = 1;
      }
    }

    // Expansion Start Marker (lift point)
    if (!state.previewOptimized) {
      const marker = toneToNorm(state.expansionStart, rangeLinear) * width;
      context.strokeStyle = palette.marker;
      context.lineWidth = 1.2;
      context.setLineDash([3, 3]);
      context.beginPath();
      context.moveTo(marker + 0.5, 0);
      context.lineTo(marker + 0.5, height);
      context.stroke();
      context.setLineDash([]);

      // Small top notch indicator for expansion start
      context.fillStyle = palette.marker;
      context.beginPath();
      context.arc(marker + 0.5, 3, 2.5, 0, Math.PI * 2);
      context.fill();
    }
  }

  let drawQueued = false;
  function scheduleDraw() {
    if (drawQueued) return;
    drawQueued = true;
    requestAnimationFrame(() => { drawQueued = false; draw(); });
  }

  /* The scope is allowed to absorb spare rail height on wide screens. Keep
   * the canvas backing store matched to that rendered size so the graph gains
   * detail instead of stretching a fixed 720 × 56 bitmap. */
  new ResizeObserver(() => {
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.round(canvas.clientWidth * scale));
    const height = Math.max(1, Math.round(canvas.clientHeight * scale));
    if (canvas.width === width && canvas.height === height) return;
    canvas.width = width;
    canvas.height = height;
    scheduleDraw();
  }).observe(canvas);

  function paintZebra() {
    const data = analysis.current;
    const state = store.get();
    for (const [mask, node, on] of [
      [data?.zebraHot, zebraHotCanvas, state.zebraHot],
      [data?.zebraCold, zebraColdCanvas, state.zebraCold],
    ]) {
      if (!on || !mask) { node.hidden = true; continue; }
      if (node.width !== mask.width) node.width = mask.width;
      if (node.height !== mask.height) node.height = mask.height;
      node.getContext("2d").putImageData(mask, 0, 0);
      node.hidden = false;
    }
  }

  store.watchAny(
    ["histMode", "expansionStart", "hdrStrength", "hdrRange", "areaCoverage",
     "brightness", "encoding", "contrast", "previewOptimized", "modelGainReady",
     "modelStrength"],
    scheduleDraw);
  store.watch("histMode", (mode) => {
    for (const [id, button] of modeButtons) setPressed(button, id === mode);
  }, { immediate: true });
  store.watchAny(["zebraHot", "zebraCold"], paintZebra, { immediate: true });

  /* Canvas pixels are not restyled by a theme flip the way the DOM is, so the
   * graph is repainted whenever the resolved theme could have changed: the
   * toggle writes `data-theme`, and with no stored choice the system does. */
  new MutationObserver(scheduleDraw)
    .observe(document.documentElement, { attributeFilter: ["data-theme"] });
  window.matchMedia("(prefers-color-scheme: dark)")
    .addEventListener?.("change", () => {
      if (!document.documentElement.dataset.theme) scheduleDraw();
    });

  /** Called by the stage after each new image (or with a null analysis when
   *  cleared). */
  return function update() {
    const data = analysis.current;
    if (!data) {
      canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
      zebraHotCanvas.hidden = true;
      zebraColdCanvas.hidden = true;
      return;
    }
    draw();
    paintZebra();
  };
}
