/* The slider mask: while a control is hovered or focused, the photograph shows
 * the global luminance region that control is expected to move.
 *
 * "扩展起点 25%" is a number; what it means is *these pixels, not those*. The
 * old panel made you learn that mapping by nudging the slider and watching the
 * histogram. The mask teaches it directly on the image, in the HDR amber the
 * tokens reserve for expansion.
 *
 * The exporter also applies local contrast and noise analysis, so this remains
 * a preview estimate rather than a promise about each output pixel. Masks are
 * computed from the decoded preview the stage already holds and cache its
 * linear luminance, keeping visible-slider updates to one lightweight walk.
 */

import { role, readColor, clamp } from "../core/dom.js";
import { store } from "../core/store.js";
import { CONTROLS_BY_KEY } from "../settings/schema.js";

const SRGB_LUMA = [0.2126, 0.7152, 0.0722];
const SRGB_TO_LINEAR = new Float32Array(256);
for (let i = 0; i < 256; i++) {
  const c = i / 255;
  SRGB_TO_LINEAR[i] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

const smoothstep = (a, b, x) => {
  const t = clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};

/* How strongly each pixel participates in expansion, 0..1, for each mask kind.
 * `gain`/`gainFull` sample the exporter's own curve so the overlay agrees with
 * the render underneath it; the two participation variants mirror the shape of
 * the approximation in curve.js. */
function weightAt(y, kind, state, curve) {
  const start = state.expansionStart;
  switch (kind) {
    case "participation":
      return smoothstep(start, 1, y);
    case "coverage": {
      const t = smoothstep(start, 1, y);
      return Math.pow(t, 1.3 - 0.75 * state.areaCoverage);
    }
    case "gain":
      return state.hdrRange > 0
        ? clamp(curve.gainStops(y, state.hdrStrength) / state.hdrRange, 0, 1)
        : 0;
    case "gainFull":
      return state.hdrRange > 0
        ? clamp(curve.gainStops(y, 1) / state.hdrRange, 0, 1)
        : 0;
    default:
      return 0;
  }
}

const MAX_ALPHA = 120;

export function mountMask({ curve, stage }) {
  const canvas = role("canvas-mask");
  const context = canvas.getContext("2d");
  let queued = false;
  let cachedSource = null;
  let sourceLuma = null;
  let output = null;

  function syncPresentation(state = store.get()) {
    const control = CONTROLS_BY_KEY.get(state.maskKey);
    const visible = Boolean(control?.mask && stage.getSource()
      && state.viewMode !== "original" && !state.comparing);
    if (!visible) {
      canvas.hidden = true;
      return false;
    }
    canvas.style.clipPath = state.viewMode === "split"
      ? `inset(0 0 0 ${(state.splitRatio * 100).toFixed(2)}%)`
      : "";
    return true;
  }

  /* Decode transfer and luminance once per thumbnail. Slider motion then only
   * walks a compact float buffer and reuses the same ImageData, avoiding three
   * table lookups plus a large allocation on every input frame. */
  function prepareSource(source, sceneScale) {
    if (source === cachedSource && sourceLuma && output) return;
    cachedSource = source;
    if (!source) {
      sourceLuma = null;
      output = null;
      return;
    }
    if (canvas.width !== source.width) canvas.width = source.width;
    if (canvas.height !== source.height) canvas.height = source.height;
    sourceLuma = new Float32Array(source.width * source.height);
    const from = source.data;
    // The transport scale and the RAW automatic exposure are folded in here
    // rather than at paint time because they belong to the decoded thumbnail,
    // not to the sliders: the mask has to read the same scene luminance the
    // renderers do, or it marks the wrong pixels on an HDR/RAW input.
    // The cache is keyed on the source buffer, which is replaced whenever the
    // scale can change.
    for (let p = 0, pixel = 0; p < from.length; p += 4, pixel++) {
      sourceLuma[pixel] = (SRGB_LUMA[0] * SRGB_TO_LINEAR[from[p]]
        + SRGB_LUMA[1] * SRGB_TO_LINEAR[from[p + 1]]
        + SRGB_LUMA[2] * SRGB_TO_LINEAR[from[p + 2]]) * sceneScale;
    }
    output = context.createImageData(source.width, source.height);
  }

  function paint() {
    queued = false;
    const state = store.get();
    const control = CONTROLS_BY_KEY.get(state.maskKey);
    const source = stage.getSource();
    if (!control?.mask || !source) {
      canvas.hidden = true;
      return;
    }
    if (!syncPresentation(state)) return;

    prepareSource(source, stage.getSourceSceneScale?.()
      ?? stage.getSourceScale?.() ?? 1);
    curve.refreshTable(state);
    const exposure = Math.pow(2, state.brightness);
    const tint = readColor("--mask-tint");
    const to = output.data;
    for (let pixel = 0, p = 0; pixel < sourceLuma.length; pixel++, p += 4) {
      const y = sourceLuma[pixel] * exposure;
      const w = weightAt(y, control.mask, state, curve);
      to[p] = tint.r;
      to[p + 1] = tint.g;
      to[p + 2] = tint.b;
      to[p + 3] = w <= 0.01 ? 0 : Math.round(w * MAX_ALPHA);
    }
    context.putImageData(output, 0, 0);
    canvas.hidden = false;
  }

  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(paint);
  }

  /* Repaint on mask changes and on any setting that bends the weight field.
   * The canvas is hidden (and stays cheap) whenever no slider is touched. */
  stage.onSourceChange(() => {
    cachedSource = null;
    schedule();
  });
  store.watchAny(
    ["maskKey", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage",
     "brightness", "encoding", "contrast", "file"],
    schedule,
    { immediate: true });
  store.watchAny(
    ["viewMode", "comparing", "splitRatio"],
    syncPresentation,
    { immediate: true });
}
