/* Pure JavaScript port of modules/look/src/{curve,tone_curve}.cpp.
 *
 * Keep this module free of DOM and API imports: the browser uses it on every
 * preview frame, and the cross-language regression test imports it in Node to
 * compare all 257 samples with `HyperDR curve`.
 */

const HIGHEST_INVERTIBLE_SDR = 0.9995;
const TOE_END = 0.08;
const TOE_OUTPUT_RATIO = 2 / 3;
const EPSILON = 1e-6;

const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

const smoothstep = (low, high, value) => {
  const t = clamp((value - low) / (high - low), 0, 1);
  return t * t * (3 - 2 * t);
};

export function buildToneCurve(contrast, expansionStart) {
  const toeOutput = TOE_OUTPUT_RATIO * contrast * TOE_END;
  return {
    toeEnd: TOE_END,
    toeOutput,
    contrast,
    shoulderInput: TOE_END + (expansionStart - toeOutput) / contrast,
    shoulderOutput: expansionStart,
  };
}

export function renderToneCurve(sceneLuminance, peak, curve) {
  if (Number.isNaN(sceneLuminance) || sceneLuminance <= 0) return 0;
  if (!Number.isFinite(sceneLuminance)) return peak;
  if (sceneLuminance <= curve.toeEnd) {
    const end2 = curve.toeEnd * curve.toeEnd;
    const a = (3 * curve.toeOutput - curve.contrast * curve.toeEnd) / end2;
    const b = (curve.contrast * curve.toeEnd - 2 * curve.toeOutput)
      / (end2 * curve.toeEnd);
    return Math.max(0, a * sceneLuminance * sceneLuminance
      + b * sceneLuminance * sceneLuminance * sceneLuminance);
  }
  if (sceneLuminance <= curve.shoulderInput) {
    return curve.toeOutput + curve.contrast * (sceneLuminance - curve.toeEnd);
  }
  const exponent = -curve.contrast * (sceneLuminance - curve.shoulderInput)
    / (peak - curve.shoulderOutput);
  return peak - (peak - curve.shoulderOutput) * Math.exp(Math.max(exponent, -80));
}

function invertSdr(target, curve) {
  if (target <= 0) return 0;
  let low = 0;
  let high = 1;
  while (renderToneCurve(high, 1, curve) < target && high < 1e6) high *= 2;
  for (let iteration = 0; iteration < 64; iteration++) {
    const middle = 0.5 * (low + high);
    if (renderToneCurve(middle, 1, curve) < target) low = middle;
    else high = middle;
  }
  return 0.5 * (low + high);
}

/** Fill a uniform SDR-output LUT with the photographic gain curve.
 * The destination length is the C++ `samples` argument. */
export function fillPhotographicGainLut(destination, {
  contrast, hdrRange, expansionStart,
}) {
  if (!(destination instanceof Float32Array) || destination.length < 2) {
    throw new TypeError("gain LUT must be a Float32Array with at least two samples");
  }
  const curve = buildToneCurve(contrast, expansionStart);
  const headroomStops = Math.max(0, hdrRange);
  const headroomLinear = 2 ** headroomStops;
  const expandable = headroomLinear > curve.shoulderOutput + EPSILON
    && headroomLinear > 1;

  for (let i = 0; i < destination.length; i++) {
    const level = i / (destination.length - 1);
    const scene = invertSdr(Math.min(level, HIGHEST_INVERTIBLE_SDR), curve);
    if (!expandable || level <= 0) {
      destination[i] = 0;
      continue;
    }
    const hdr = renderToneCurve(scene, headroomLinear, curve);
    const base = Math.max(renderToneCurve(scene, 1, curve), EPSILON);
    destination[i] = Math.max(0, Math.log2(Math.max(hdr, base) / base));
  }
  return destination;
}

/** Browser-only estimate of the exporter's spatial highlight weighting.
 *
 * The exact renderer also uses neighbourhood contrast and noise statistics,
 * which a one-dimensional LUT cannot contain. This keeps area coverage out of
 * the global curve while giving the live preview the same diffuse-floor
 * semantics and a luminance proxy for isolated highlights.
 */
export function previewCoverageWeight(
  y, globalGainStops, strength, areaCoverage, expansionStart,
) {
  const diffuseFloor = clamp(areaCoverage + 0.20 * strength, 0, 1);
  const highlight = smoothstep(expansionStart, 1, y);
  const absolute = smoothstep(0.70, 1.50, y * (2 ** globalGainStops));
  return diffuseFloor + (1 - diffuseFloor) * highlight * absolute;
}
