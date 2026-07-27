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

  return { get: () => state, set, subscribe, watch };
}

/** The panel's state, in one place. Extend as screens land. */
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
});
