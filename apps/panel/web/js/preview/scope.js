/* Histogram, clipping percentages, and the zebra overlays.
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

function histogramFromPlane(values, width, height, rangeLinear) {
  const total = width * height;
  const histogram = emptyHistogram(total);
  const scale = 255 / Math.max(rangeLinear, 1e-6);
  for (let p = 0; p < values.length; p += 3) {
    const r = Math.max(0, Number.isFinite(values[p]) ? values[p] : 0);
    const g = Math.max(0, Number.isFinite(values[p + 1]) ? values[p + 1] : 0);
    const b = Math.max(0, Number.isFinite(values[p + 2]) ? values[p + 2] : 0);
    histogram.red[clampBin(r * scale)]++;
    histogram.green[clampBin(g * scale)]++;
    histogram.blue[clampBin(b * scale)]++;
    histogram.luma[clampBin((P3_LUMA[0] * r + P3_LUMA[1] * g + P3_LUMA[2] * b) * scale)]++;
  }
  return histogram;
}

function histogramFromDisplayImage(source, rangeLinear) {
  const data = source.data;
  const histogram = emptyHistogram(data.length / 4);
  const scale = 255 / Math.max(rangeLinear, 1e-6);
  for (let p = 0; p < data.length; p += 4) {
    const r = decodeDisplaySample(data[p]);
    const g = decodeDisplaySample(data[p + 1]);
    const b = decodeDisplaySample(data[p + 2]);
    histogram.red[clampBin(r * scale)]++;
    histogram.green[clampBin(g * scale)]++;
    histogram.blue[clampBin(b * scale)]++;
    histogram.luma[clampBin((P3_LUMA[0] * r + P3_LUMA[1] * g + P3_LUMA[2] * b) * scale)]++;
  }
  return histogram;
}

/* One pass over the source plus the native output planes: luma + per-channel
 * counts, clipping, zebra masks. The histogram is deliberately computed from
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

  const total = data.length / 4;
  let hot = 0;
  let cold = 0;

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
    if (isHot) hot++;
    if (isCold) cold++;
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
    clipping: { hot: hot / total, cold: cold / total },
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

function drawSeries(context, counts, style, blend, width, height, fill, maxCount = 0) {
  let max = maxCount;
  if (!(max > 0)) for (let i = 0; i < 256; i++) if (counts[i] > max) max = counts[i];
  max = Math.max(max, 1);
  context.beginPath();
  context.moveTo(0, height);
  for (let i = 0; i < 256; i++) {
    const x = (i / 255) * width;
    const value = Math.min(1, counts[i] / max);
    context.lineTo(x, height - Math.pow(value, 0.55) * (height - 2));
  }
  if (fill) {
    context.lineTo(width, height);
    context.closePath();
    context.fillStyle = style;
    if (blend) context.globalCompositeOperation = blend;
    context.fill();
    context.globalCompositeOperation = "source-over";
  } else {
    context.strokeStyle = style;
    context.lineWidth = 1.5;
    context.stroke();
  }
}

export function mountScope({ analysis }) {
  const canvas = role("histogram");
  const zebraHotCanvas = role("canvas-zebra-hot");
  const zebraColdCanvas = role("canvas-zebra-cold");
  const hotChip = role("clip-hot");
  const coldChip = role("clip-cold");
  const histMode = role("hist-mode");

  const modes = [["luma", "亮度"], ["rgb", "RGB"]];
  const modeButtons = modes.map(([id, label]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.textContent = label;
    button.addEventListener("click", () => store.set({ histMode: id }));
    histMode.append(button);
    return [id, button];
  });

  hotChip.addEventListener("click", () => store.set({ zebraHot: !store.get().zebraHot }));
  coldChip.addEventListener("click", () => store.set({ zebraCold: !store.get().zebraCold }));

  function draw() {
    const data = analysis.current;
    if (!data) return;
    const state = store.get();
    const context = canvas.getContext("2d");
    const { width, height } = canvas;
    const palette = readPalette();
    context.clearRect(0, 0, width, height);

    context.strokeStyle = palette.grid;
    context.lineWidth = 1;
    for (let g = 1; g < 4; g++) {
      const x = ((width * g) / 4) | 0;
      context.beginPath();
      context.moveTo(x + 0.5, 0);
      context.lineTo(x + 0.5, height);
      context.stroke();
    }

    const { histogram } = data;
    if (state.histMode === "rgb") {
      const sourceChannels = histogram;
      const outputChannels = data.renderedHistogram || histogram;
      const max = Math.max(
        ...[sourceChannels.red, sourceChannels.green, sourceChannels.blue,
          outputChannels.red, outputChannels.green, outputChannels.blue]
          .map((series) => Math.max(...series)));
      context.globalAlpha = 0.28;
      drawSeries(context, sourceChannels.red, palette.red, "lighter", width, height, true, max);
      drawSeries(context, sourceChannels.green, palette.green, "lighter", width, height, true, max);
      drawSeries(context, sourceChannels.blue, palette.blue, "lighter", width, height, true, max);
      context.globalAlpha = 1;
      if (data.renderedHistogram) {
        drawSeries(context, outputChannels.red, palette.red, null, width, height, false, max);
        drawSeries(context, outputChannels.green, palette.green, null, width, height, false, max);
        drawSeries(context, outputChannels.blue, palette.blue, null, width, height, false, max);
      }
    } else {
      const output = data.renderedHistogram?.luma || histogram.luma;
      const max = Math.max(Math.max(...histogram.luma), Math.max(...output));
      drawSeries(context, histogram.luma, palette.luma, null, width, height, true, max);
      if (data.renderedHistogram) {
        drawSeries(context, output, palette.output, null, width, height, false, max);
      }
    }

    if (!state.previewOptimized) {
      // Where the mathematical broad-highlight lift begins.
      const marker = (state.expansionStart / Math.max(data.rangeLinear, 1)) * width;
      context.strokeStyle = palette.marker;
      context.setLineDash([3, 3]);
      context.beginPath();
      context.moveTo(marker + 0.5, 0);
      context.lineTo(marker + 0.5, height);
      context.stroke();
      context.setLineDash([]);
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
  store.watchAny(["zebraHot", "zebraCold"], (state) => {
    setPressed(hotChip, state.zebraHot);
    setPressed(coldChip, state.zebraCold);
    paintZebra();
  }, { immediate: true });

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
      setText(role("clip-hot-value"), "0.0%");
      setText(role("clip-cold-value"), "0.0%");
      zebraHotCanvas.hidden = true;
      zebraColdCanvas.hidden = true;
      return;
    }
    setText(role("clip-hot-value"), `${(data.clipping.hot * 100).toFixed(1)}%`);
    setText(role("clip-cold-value"), `${(data.clipping.cold * 100).toFixed(1)}%`);
    draw();
    paintZebra();
  };
}
