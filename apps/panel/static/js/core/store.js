/* A single observable store, replacing the panel's scattered globals.
 *
 * The previous front-end kept two mutable objects (`state`, `preview`) that any
 * function could write, and every writer had to remember to call `sync()` --
 * a function that then re-read twenty DOM nodes to rebuild the whole interface.
 * Here the data is the source of truth and views subscribe to the slices they
 * care about, so adding a control cannot silently forget to refresh something.
 */

export function createStore(initial) {
  let state = { ...initial };
  const listeners = new Set();
  let queued = false;
  let changed = new Set();

  function flush() {
    queued = false;
    const keys = changed;
    changed = new Set();
    for (const listener of Array.from(listeners)) listener(state, keys);
  }

  return {
    get: () => state,

    /** Read one key. */
    value: (key) => state[key],

    /** Merge a patch. Unchanged values do not notify. */
    set(patch) {
      let dirty = false;
      for (const [key, value] of Object.entries(patch)) {
        if (Object.is(state[key], value)) continue;
        state = { ...state, [key]: value };
        changed.add(key);
        dirty = true;
      }
      if (!dirty) return;
      // Coalesced to a microtask so a burst of writes renders once.
      if (!queued) { queued = true; queueMicrotask(flush); }
    },

    /** Subscribe to every change. `keys` is the set of names that moved. */
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    /** Subscribe to a subset; fires immediately with the current state. */
    watch(keys, listener) {
      const wanted = new Set(keys);
      const stop = this.subscribe((next, moved) => {
        for (const key of moved) if (wanted.has(key)) return listener(next, moved);
      });
      listener(state, new Set(keys));
      return stop;
    },
  };
}
