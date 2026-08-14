/* One observable object for the panel's state.
 *
 * The old front-end kept state in DOM attributes and module-level `let`s, so
 * "what is the panel doing right now" had no single answer and two views could
 * disagree. Everything the UI renders from lives here; views subscribe and are
 * otherwise stateless.
 *
 * Deliberately ~50 lines. If this file starts growing a scheduler, batching, or
 * a dependency graph, that is the signal to adopt a real library rather than to
 * keep extending it.
 */

/** @template T */
export function createStore(initial) {
  let state = Object.freeze({ ...initial });
  const listeners = new Set();

  /** Shallow-merges a patch and notifies subscribers if anything changed. */
  function set(patch) {
    const next = { ...state, ...patch };
    const changed = Object.keys(patch).filter((key) => !Object.is(state[key], next[key]));
    if (changed.length === 0) return;
    const previous = state;
    state = Object.freeze(next);
    // Snapshot first: a listener may subscribe or unsubscribe while running.
    for (const listener of [...listeners]) listener(state, previous, changed);
  }

  /** @returns {() => void} unsubscribe */
  function subscribe(listener, { immediate = false } = {}) {
    listeners.add(listener);
    if (immediate) listener(state, state, Object.keys(state));
    return () => listeners.delete(listener);
  }

  /** Subscribe to one key. Fires only when that key actually changes. */
  function watch(key, listener, options) {
    return subscribe((next, previous, changed) => {
      if (changed.includes(key)) listener(next[key], previous[key]);
    }, options && { immediate: options.immediate });
  }

  /** Subscribe to several keys; the listener gets the state and the subset of
   *  `keys` that moved. Most views care about more than one key, and writing
   *  this filter out each time is how a key quietly gets missed. */
  function watchAny(keys, listener, options) {
    const wanted = new Set(keys);
    return subscribe((next, previous, changed) => {
      const moved = changed.filter((key) => wanted.has(key));
      if (moved.length) listener(next, previous, moved);
    }, options && { immediate: options.immediate });
  }

  return { get: () => state, set, subscribe, watch, watchAny };
}

/** The panel's state, in one place. Extend as screens land.
 *
 * The settings keys (encoding, hdrStrength, …) are not listed here: they are
 * declared once in settings/schema.js and merged in by main.js at boot, so the
 * store never has to be edited when a control is. */
export const store = createStore({
  /** @type {"booting"|"ready"|"unavailable"} */
  phase: "booting",
  /** `/api/state` payload, or null before boot completes. */
  capabilities: null,
  /** Current upload/convert session id, or null. */
  sessionId: null,
  /** Running job id, or null when idle. */
  jobId: null,
  /** Last error surfaced to the user, or null. */
  error: null,

  /* -- session ------------------------------------------------------- */
  /** @type {{name: string, size: number} | null} */
  file: null,
  uploading: false,
  /** Upload progress, 0..1. */
  uploadProgress: 0,
  /** The settings snapshot a successful run used, for the stale badge. */
  result: null,
  outputSelectionId: "",
  outputDirectory: "",

  /* -- viewer ---------------------------------------------------------- */
  /** @type {"effect"|"original"|"split"} */
  viewMode: "effect",
  /** Wipe position in split mode, 0..1 of the image's displayed width. */
  splitRatio: 0.5,
  /** @type {"fit"|"100"|"200"|"400"} */
  zoomLevel: "fit",
  /** Pan offset in CSS pixels from the centered image position. */
  panX: 0,
  panY: 0,
  /** Transient press-and-hold compare; never persisted. */
  comparing: false,
  zebraHot: false,
  zebraCold: false,
  /** @type {"luma"|"rgb"} */
  histMode: "luma",
  /** Settings key whose mask is on the photograph, or null. */
  maskKey: null,
  /** Whether the preview/export is currently using the model gain. */
  previewOptimized: false,
  /** Whether the current image already has a reusable model gain in memory. */
  modelGainReady: false,
  optimizing: false,
});
