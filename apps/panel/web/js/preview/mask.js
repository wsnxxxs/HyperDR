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

const P3_LUMA = [0.2289746, 0.6917385, 0.0792869];

function weightAt(gainStops, state) {
  return state.hdrRange > 0 ? clamp(gainStops / state.hdrRange, 0, 1) : 0;
}

const MAX_ALPHA = 120;

export function mountMask({ stage }) {
  const canvas = role("canvas-mask");
  const context = canvas.getContext("2d");
  let queued = false;
  let cachedSource = null;
  let nativeGain = null;
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
  function prepareSource(source, frame) {
    if (source === cachedSource && nativeGain && output) return;
    cachedSource = source;
    if (!source) {
      nativeGain = null;
      output = null;
      return;
    }
    if (canvas.width !== source.width) canvas.width = source.width;
    if (canvas.height !== source.height) canvas.height = source.height;
    nativeGain = new Float32Array(source.width * source.height);
    for (let p = 0, pixel = 0; p < frame.base.length; p += 3, pixel++) {
      const base = P3_LUMA[0]*frame.base[p] + P3_LUMA[1]*frame.base[p+1] + P3_LUMA[2]*frame.base[p+2];
      const hdr = P3_LUMA[0]*frame.hdr[p] + P3_LUMA[1]*frame.hdr[p+1] + P3_LUMA[2]*frame.hdr[p+2];
      nativeGain[pixel] = Math.max(0, Math.log2(Math.max(hdr, 1e-6) / Math.max(base, 1e-6)));
    }
    output = context.createImageData(source.width, source.height);
  }

  function paint() {
    queued = false;
    const state = store.get();
    const control = CONTROLS_BY_KEY.get(state.maskKey);
    const source = stage.getSource();
    const frame = stage.getFrame();
    if (!control?.mask || !source || !frame) {
      canvas.hidden = true;
      return;
    }
    if (!syncPresentation(state)) return;

    prepareSource(source, frame);
    const tint = readColor("--mask-tint");
    const to = output.data;
    for (let pixel = 0, p = 0; pixel < nativeGain.length; pixel++, p += 4) {
      const w = weightAt(nativeGain[pixel], state);
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
