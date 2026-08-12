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
import { __math, sampleModelGain } from "./cpu.js";

/* One pass over the source: luma + per-channel counts, clipping, zebra masks.
 * The masks are painted with the token colours read at call time, so a theme
 * flip between images cannot leave yesterday's red on today's photo. */
export function analyse(source, scene = source, sceneScale = 1) {
  const data = source.data;
  const sceneData = scene.data;
  const { width } = source;
  const luma = new Uint32Array(256);
  // A second luma histogram over the *unscaled* preview codes. `source` is the
  // SDR rendition -- clipped at white, which is what the drawn input series and
  // the zebras want -- but the simulated output series has to start from the
  // scene, or an HDR input's highlights would be modelled as already blown and
  // the graph would show no expansion where the picture plainly has some.
  const sceneLuma = new Uint32Array(256);
  const red = new Uint32Array(256);
  const green = new Uint32Array(256);
  const blue = new Uint32Array(256);
  const zebraHot = new ImageData(width, source.height);
  const zebraCold = new ImageData(width, source.height);
  const hotColor = readColor("--zebra-hot");
  const coldColor = readColor("--zebra-cold");

  const total = data.length / 4;
  let hot = 0;
  let cold = 0;

  for (let p = 0, i = 0; p < data.length; p += 4, i++) {
    const r = data[p], g = data[p + 1], b = data[p + 2];
    red[r]++; green[g]++; blue[b]++;
    const y = Math.round(0.2126 * r + 0.7152 * g + 0.0722 * b);
    luma[y < 0 ? 0 : y > 255 ? 255 : y]++;
    const sy = Math.round(0.2126 * sceneData[p] + 0.7152 * sceneData[p + 1]
      + 0.0722 * sceneData[p + 2]);
    sceneLuma[sy < 0 ? 0 : sy > 255 ? 255 : sy]++;

    const peak = Math.max(r, g, b);
    const isHot = peak >= 250;
    const isCold = peak <= 4;
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

  return {
    source,
    scene,
    sceneScale,
    sceneLuma,
    histogram: { luma, red, green, blue, total },
    clipping: { hot: hot / total, cold: cold / total },
    zebraHot,
    zebraCold,
  };
}

/* Fold the source luma histogram through the same luminance maths the SDR
 * renderer applies: exposure, the exporter's curve at the current strength,
 * then the display shoulder. Vibrance is deliberately absent: it moves chroma
 * around the same luma axis, and a one-dimensional luma histogram has no hue or
 * saturation data from which to model the rare gamut-clamp correction. 256 bins
 * instead of a pixel walk keeps this cheap enough to redraw during a drag. */
function simulateOutput(luma, state, curve, sceneScale = 1) {
  const { SRGB_TO_LINEAR, linearToSrgb8, shoulder } = __math;
  const out = new Float32Array(256);
  const exposure = Math.pow(2, state.brightness) * sceneScale;
  for (let i = 0; i < 256; i++) {
    const count = luma[i];
    if (!count) continue;
    const y = SRGB_TO_LINEAR[i] * exposure;
    const gained = y * Math.pow(2, curve.previewGainStops(y, state));
    out[linearToSrgb8(shoulder(gained))] += count;
  }
  return out;
}

/* A model gain is spatial, so it cannot be folded through the 256 source bins
 * like the mathematical curve. Sample the actual pixels and the same bilinear
 * gain grid as the renderers. A bounded stride keeps slider motion responsive
 * for 2K previews while preserving the distribution's shape. */
function simulateModelOutput(source, modelGain, strength, sceneScale = 1) {
  const { SRGB_TO_LINEAR, linearToSrgb8, shoulder, SRGB_LUMA } = __math;
  const output = {
    luma: new Float32Array(256),
    red: new Float32Array(256),
    green: new Float32Array(256),
    blue: new Float32Array(256),
  };
  const pixelCount = source.width * source.height;
  const stride = Math.max(1, Math.ceil(pixelCount / 250_000));
  for (let pixel = 0; pixel < pixelCount; pixel += stride) {
    const offset = pixel * 4;
    const x = pixel % source.width;
    const y = Math.floor(pixel / source.width);
    const gain = Math.pow(
      2,
      sampleModelGain(modelGain, x, y, source.width, source.height) * strength,
    );
    const scaled = gain * sceneScale;
    const r = linearToSrgb8(shoulder(SRGB_TO_LINEAR[source.data[offset]] * scaled));
    const g = linearToSrgb8(shoulder(SRGB_TO_LINEAR[source.data[offset + 1]] * scaled));
    const b = linearToSrgb8(shoulder(SRGB_TO_LINEAR[source.data[offset + 2]] * scaled));
    const luma = Math.round(SRGB_LUMA[0] * r + SRGB_LUMA[1] * g + SRGB_LUMA[2] * b);
    output.red[r]++;
    output.green[g]++;
    output.blue[b]++;
    output.luma[Math.min(255, Math.max(0, luma))]++;
  }
  return output;
}

const PALETTE_KEYS = ["grid", "luma", "red", "green", "blue", "marker", "output"];

function readPalette() {
  const palette = {};
  for (const key of PALETTE_KEYS) palette[key] = readColor(`--hist-${key}`).css;
  return palette;
}

function drawSeries(context, counts, style, blend, width, height, fill) {
  let max = 0;
  for (let i = 1; i < 255; i++) if (counts[i] > max) max = counts[i]; // ignore 0/255 spikes
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

export function mountScope({ curve, analysis }) {
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
    curve.refreshTable(state);
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
    const modelOutput = state.previewOptimized && analysis.modelGain
      ? simulateModelOutput(data.scene, analysis.modelGain, state.modelStrength,
                            data.sceneScale)
      : null;
    if (state.histMode === "rgb") {
      // Once model mode is active, RGB describes the current model rendition
      // rather than continuing to show the unchanged source channels.
      const channels = modelOutput || histogram;
      drawSeries(context, channels.red, palette.red, "lighter", width, height, true);
      drawSeries(context, channels.green, palette.green, "lighter", width, height, true);
      drawSeries(context, channels.blue, palette.blue, "lighter", width, height, true);
    } else {
      drawSeries(context, histogram.luma, palette.luma, null, width, height, true);
      const output = modelOutput
        ? modelOutput.luma
        : simulateOutput(data.sceneLuma, state, curve, data.sceneScale);
      drawSeries(context, output,
                 palette.output, null, width, height, false);
    }

    if (!state.previewOptimized) {
      // Where the mathematical broad-highlight lift begins.
      const marker = (state.expansionStart * width) | 0;
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
