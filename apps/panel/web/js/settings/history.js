/* Photo-scoped undo. Slider input bursts become one edit, while changes to
 * different settings and explicit commits remain separate steps. */
export function createHistory(store, keys, { delay = 400, limit = 60 } = {}) {
  const snapshot = () => Object.fromEntries(keys.map((key) => [key, store.get()[key]]));
  const same = (a, b) => keys.every((key) => Object.is(a[key], b[key]));
  let entries = [snapshot()];
  let cursor = 0;
  let pending = null;
  let timer;
  let pendingKeys = "";
  let applying = false;
  const listeners = new Set();
  const status = () => ({ canUndo: cursor > 0 || Boolean(pending),
    canRedo: !pending && cursor < entries.length - 1 });
  const notify = () => listeners.forEach((listener) => listener(status()));

  function flush() {
    clearTimeout(timer);
    if (!pending) return;
    entries = entries.slice(0, cursor + 1);
    entries.push(pending);
    if (entries.length > limit) entries.shift();
    cursor = entries.length - 1;
    pending = null;
    notify();
  }

  function reset() {
    clearTimeout(timer);
    entries = [snapshot()]; cursor = 0; pending = null;
    notify();
  }

  const unsubscribe = store.subscribe((state, previous, changed) => {
    if (applying) return;
    if (changed.includes("file") || changed.includes("uploading")
        || changed.includes("restoring") || state.uploading || state.restoring) {
      reset(); return;
    }
    if (!state.file || !changed.some((key) => keys.includes(key))) return;
    const next = snapshot();
    if (pending && same(next, pending)) return;
    const moved = changed.filter((key) => keys.includes(key)).sort().join(",");
    if (pending && pendingKeys !== moved) flush();
    pendingKeys = moved;
    clearTimeout(timer);
    pending = same(next, entries[cursor]) ? null : next;
    timer = setTimeout(flush, delay);
    notify();
  });

  function move(direction) {
    flush();
    const next = cursor + direction;
    if (next < 0 || next >= entries.length) return false;
    applying = true;
    cursor = next;
    try { store.set(entries[cursor]); } finally { applying = false; }
    notify();
    return true;
  }

  return { flush, reset, undo: () => move(-1), redo: () => move(1), status,
    subscribe(listener) { listeners.add(listener); listener(status());
      return () => listeners.delete(listener); },
    dispose() { clearTimeout(timer); unsubscribe(); listeners.clear(); },
  };
}
