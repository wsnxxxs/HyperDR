/* The exporter's own tone curve, rebuilt synchronously in the browser.
 *
 * curve-math.js is a direct port of the C++ implementation. Rebuilding 257
 * samples locally keeps range/start drags on one exact curve instead of showing
 * an approximation and replacing it with a fetched curve after the gesture.
 * `/api/curve` remains a startup drift check, never a visible render source.
 */

import { api } from "../core/api.js";
import { clamp } from "../core/dom.js";
import { toOptions } from "../settings/schema.js";
import {
  fillPhotographicGainLut,
  previewCoverageWeight,
} from "./curve-math.js";

export const LUT_SIZE = 257;

const smoothstep = (a, b, x) => {
  const t = clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};

/** Only the settings that change the curve's shape belong in its cache key.
 * `areaCoverage` is spatial and must not invalidate the global curve. */
const keyOf = (state) => [
  state.contrast, state.hdrRange, state.expansionStart,
].join("\0");

export function createCurve() {
  const table = new Float32Array(LUT_SIZE);
  let tableKey = "";
  let validationStarted = false;

  /** Rebuild once for each coalesced render frame whose curve inputs changed. */
  function refreshTable(state) {
    const key = keyOf(state);
    if (key === tableKey) return table;
    tableKey = key;
    return fillPhotographicGainLut(table, state);
  }

  function sample(y) {
    const x = clamp(y, 0, 1) * (LUT_SIZE - 1);
    const low = Math.floor(x);
    const high = Math.min(low + 1, LUT_SIZE - 1);
    return table[low] + (table[high] - table[low]) * (x - low);
  }

  /* --gain-strength attenuates the expansion the curve describes, exactly as it
   * does in the exporter, so the strength knob stays meaningful over a LUT. */
  const gainStops = (y, strength) => (strength <= 0 ? 0 : sample(y) * strength);

  const previewGainStops = (y, state) => {
    const global = gainStops(y, state.hdrStrength);
    return global * previewCoverageWeight(
      y, global, state.hdrStrength, state.areaCoverage, state.expansionStart);
  };

  /* Highlight saturation retention: keep sunset and lamp colour vivid instead
   * of letting expansion wash it toward white. Anchored to the curve's own
   * shoulder so it cannot drift from where expansion actually begins. */
  const saturation = (y, strength, expansionStart) =>
    1 + 0.12 * strength * smoothstep(expansionStart, 1, y);

  /** Compare the JS port with one C++ sampling at startup. A mismatch is
   * diagnostic only: an asynchronous response never replaces the visible LUT. */
  async function validateOnce(state) {
    if (validationStarted) return;
    validationStarted = true;
    try {
      const body = await api.curve(toOptions(state), LUT_SIZE);
      if (!Array.isArray(body.gain_stops) || body.gain_stops.length !== LUT_SIZE) {
        throw new Error("unexpected curve length");
      }
      const reference = new Float32Array(LUT_SIZE);
      fillPhotographicGainLut(reference, state);
      let maximumError = 0;
      for (let i = 0; i < LUT_SIZE; i++) {
        maximumError = Math.max(maximumError, Math.abs(reference[i] - body.gain_stops[i]));
      }
      if (maximumError > 2e-5) {
        console.warn(`HyperDR curve port drifted from C++ (max error ${maximumError})`);
      }
    } catch (_) {
      // Offline and older binaries do not block the fully local live preview.
    }
  }

  return {
    table, refreshTable, gainStops, previewGainStops, saturation, validateOnce, LUT_SIZE,
  };
}
