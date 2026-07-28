/* SDR fallback renderer.
 *
 * Shown when the display reports no HDR headroom, or when WebGPU is out of
 * reach (plain-HTTP LAN access, older Safari). It applies the same curve as the
 * GPU path and then folds the result back into the display range, so the panel
 * still shows *where* HDR adds pop even though it cannot show how bright.
 */

import { clamp } from "../core/dom.js";

const SRGB_LUMA = [0.2126, 0.7152, 0.0722]; // linear sRGB D65

// sRGB transfer, also valid for Display P3, which shares the curve.
const SRGB_TO_LINEAR = new Float32Array(256);
for (let i = 0; i < 256; i++) {
  const c = i / 255;
  SRGB_TO_LINEAR[i] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function linearToSrgb8(value) {
  const v = clamp(value, 0, 1);
  const encoded = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
  return Math.round(encoded * 255);
}

function smoothstep(a, b, value) {
  const t = clamp((value - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
}

/** Soft shoulder folding an expanded value (which may exceed 1) back into SDR. */
function shoulder(value) {
  const knee = 0.8;
  if (value <= knee) return value;
  return knee + (1 - knee) * (1 - Math.exp(-(value - knee) / (1 - knee)));
}

/* This canvas is only ever written to -- the pixel walk reads `source`, an
 * ImageData the stage already holds. Asking for `willReadFrequently` therefore
 * bought nothing and cost the accelerated backing store: the browser keeps the
 * surface in system memory and composites it in software on every frame. The
 * scratch canvas in stage.js, which does call getImageData, keeps the hint.
 *
 * Context attributes are honoured only on the first getContext for an element,
 * so the handle is cached rather than re-requested per frame. */
const contexts = new WeakMap();

function contextFor(canvas) {
  let context = contexts.get(canvas);
  if (!context) {
    context = canvas.getContext("2d");
    contexts.set(canvas, context);
  }
  return context;
}

export function renderSdr(canvas, { source, output, curve, settings, original }) {
  const context = contextFor(canvas);
  if (original) { context.putImageData(source, 0, 0); return; }

  const from = source.data;
  const to = output.data;
  const { hdrStrength: strength, expansionStart, brightness, vibrance } = settings;
  const exposure = Math.pow(2, brightness);

  for (let i = 0; i < from.length; i += 4) {
    const r = SRGB_TO_LINEAR[from[i]] * exposure;
    const g = SRGB_TO_LINEAR[from[i + 1]] * exposure;
    const b = SRGB_TO_LINEAR[from[i + 2]] * exposure;
    const y = SRGB_LUMA[0] * r + SRGB_LUMA[1] * g + SRGB_LUMA[2] * b;
    let R = r, G = g, B = b;
    const sourceSaturation = Math.max(Math.abs(r - y), Math.abs(g - y), Math.abs(b - y))
      / Math.max(y, 1e-6);
    const vibranceAmount = vibrance * (1 - smoothstep(0.15, 1, sourceSaturation));
    R = Math.max(0, y + (R - y) * (1 + vibranceAmount));
    G = Math.max(0, y + (G - y) * (1 + vibranceAmount));
    B = Math.max(0, y + (B - y) * (1 + vibranceAmount));
    const adjustedY = SRGB_LUMA[0] * R + SRGB_LUMA[1] * G + SRGB_LUMA[2] * B;
    const gain = Math.pow(2, curve.gainStops(adjustedY, strength));
    R *= gain;
    G *= gain;
    B *= gain;
    const ye = SRGB_LUMA[0] * R + SRGB_LUMA[1] * G + SRGB_LUMA[2] * B;
    const sat = curve.saturation(adjustedY, strength, expansionStart);
    R = ye + (R - ye) * sat;
    G = ye + (G - ye) * sat;
    B = ye + (B - ye) * sat;

    to[i] = linearToSrgb8(shoulder(R));
    to[i + 1] = linearToSrgb8(shoulder(G));
    to[i + 2] = linearToSrgb8(shoulder(B));
    to[i + 3] = from[i + 3];
  }
  context.putImageData(output, 0, 0);
}

/* The pieces the histogram's simulated-output series needs, exported so the
 * scope walks 256 bins through the exact maths the pixels walk through --
 * a second, diverging implementation is how the graph starts lying. */
export const __math = { SRGB_TO_LINEAR, linearToSrgb8, shoulder, SRGB_LUMA };
