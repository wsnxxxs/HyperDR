/* The slider mask: while a control is hovered or focused, the photograph shows
 * which pixels that control is about to move.
 *
 * "扩展起点 25%" is a number; what it means is *these pixels, not those*. The
 * old panel made you learn that mapping by nudging the slider and watching the
 * histogram. The mask teaches it directly on the image, in the HDR amber the
 * tokens reserve for expansion.
 *
 * Masks are computed from the decoded preview the stage already holds, so they
 * cost one pixel walk per settings change while visible -- never during a drag
 * of an unrelated slider, because unrelated sliders clear `maskKey` first.
 */

import { role, readColor, clamp } from "../core/dom.js";
import { store } from "../core/store.js";
import { CONTROLS_BY_KEY } from "../settings/schema.js";

const P3_LUMA = [0.2289746, 0.6917385, 0.0792869];
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

const MAX_ALPHA = 150;

export function mountMask({ curve, stage }) {
  const canvas = role("canvas-mask");
  let queued = false;

  function paint() {
    queued = false;
    const state = store.get();
    const control = CONTROLS_BY_KEY.get(state.maskKey);
    const source = stage.getSource();
    if (!control?.mask || !source) { canvas.hidden = true; return; }

    if (canvas.width !== source.width) canvas.width = source.width;
    if (canvas.height !== source.height) canvas.height = source.height;

    curve.refreshTable(state);
    const tint = readColor("--mask-tint");
    const output = canvas.getContext("2d").createImageData(source.width, source.height);
    const from = source.data;
    const to = output.data;
    for (let p = 0; p < from.length; p += 4) {
      const y = P3_LUMA[0] * SRGB_TO_LINEAR[from[p]]
              + P3_LUMA[1] * SRGB_TO_LINEAR[from[p + 1]]
              + P3_LUMA[2] * SRGB_TO_LINEAR[from[p + 2]];
      const w = weightAt(y, control.mask, state, curve);
      if (w <= 0.01) continue;
      to[p] = tint.r;
      to[p + 1] = tint.g;
      to[p + 2] = tint.b;
      to[p + 3] = Math.round(w * MAX_ALPHA);
    }
    canvas.getContext("2d").putImageData(output, 0, 0);
    canvas.hidden = false;
  }

  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(paint);
  }

  /* Repaint on mask changes and on any setting that bends the weight field.
   * The canvas is hidden (and stays cheap) whenever no slider is touched. */
  store.watchAny(
    ["maskKey", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage",
     "encoding", "contrast", "file"],
    schedule,
    { immediate: true });
}
