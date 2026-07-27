/* The exporter's own tone curve, fetched rather than reimplemented.
 *
 * `HyperDR curve --json` samples the global curve the encoder will use, so the
 * canvas and WGSL renderers interpolate one table instead of each carrying a
 * hand-written approximation -- which is how a preview quietly stops matching
 * the file that gets written. The local, spatial part of the highlight weight
 * cannot be expressed in one dimension and is deliberately absent; the run
 * report's `rendered_peak` stays authoritative.
 */

import { api } from "../core/api.js";
import { clamp } from "../core/dom.js";
import { toOptions } from "../settings/schema.js";

export const LUT_SIZE = 257;

const smoothstep = (a, b, x) => {
  const t = clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};

/** Used until the first curve arrives, and whenever the converter is offline. */
function approximate(y, rangeStops, expansionStart, areaCoverage) {
  if (y <= expansionStart) return 0;
  const t = smoothstep(expansionStart, 1, y);
  return rangeStops * Math.pow(t, 1.3 - 0.75 * areaCoverage);
}

/** Only the settings that change the curve's shape belong in its cache key.
 *  `look` is not one: the panel always renders `photographic`. */
const keyOf = (state) => [
  state.encoding, state.contrast,
  state.hdrRange, state.expansionStart, state.areaCoverage,
].join("\0");

export function createCurve({ onChange } = {}) {
  const table = new Float32Array(LUT_SIZE);
  let fetched = null;
  let fetchedKey = "";
  let pendingKey = "";
  let timer = 0;
  let tableKey = "";

  /** Rebuild the table for the current settings; called once per render.
   *
   * A drag fires `input` far faster than the curve's shape actually changes:
   * moving --gain-strength leaves every one of the key's inputs untouched, yet
   * the old code still walked 257 entries through `Math.pow` on each frame.
   * The stamp records both the settings and which source filled the table, so
   * a refetch landing under an unchanged key still invalidates. */
  function refreshTable(state) {
    const key = keyOf(state);
    const usable = fetchedKey === key ? fetched : null;
    const stamp = usable ? `f\0${key}` : `a\0${key}`;
    if (stamp === tableKey) return table;
    tableKey = stamp;
    for (let i = 0; i < LUT_SIZE; i++) {
      const y = i / (LUT_SIZE - 1);
      table[i] = usable
        ? usable[i]
        : approximate(y, state.hdrRange, state.expansionStart, state.areaCoverage);
    }
    return table;
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

  /* Highlight saturation retention: keep sunset and lamp colour vivid instead
   * of letting expansion wash it toward white. Anchored to the curve's own
   * shoulder so it cannot drift from where expansion actually begins. */
  const saturation = (y, strength, expansionStart) =>
    1 + 0.12 * strength * smoothstep(expansionStart, 1, y);

  async function fetchCurve(state) {
    const key = keyOf(state);
    if (key === fetchedKey || key === pendingKey) return;
    pendingKey = key;
    try {
      const body = await api.curve(toOptions(state), LUT_SIZE);
      if (!Array.isArray(body.gain_stops) || body.gain_stops.length !== LUT_SIZE) {
        throw new Error("unexpected curve length");
      }
      fetched = Float32Array.from(body.gain_stops);
      fetchedKey = key;
      tableKey = "";        // force the next render to adopt the fetched curve
      onChange?.();
    } catch (_) {
      // Offline or an older binary: the approximation keeps the panel usable
      // and the exported file is unaffected either way.
    } finally {
      if (pendingKey === key) pendingKey = "";
    }
  }

  function schedule(state) {
    clearTimeout(timer);
    timer = setTimeout(() => fetchCurve(state), 150);
  }

  return { table, refreshTable, gainStops, saturation, schedule, LUT_SIZE };
}
