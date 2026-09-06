/* Keep one render running and coalesce pointer movement into its latest state. */
export function createPreviewScheduler(render, delay = 80) {
  let timer = null, running = false, pending = null;
  async function flush() {
    timer = null;
    if (running || !pending) return;
    const request = pending;
    pending = null;
    running = true;
    try { await render(request); }
    finally {
      running = false;
      if (pending) timer = setTimeout(flush, 0);
    }
  }
  return {
    request(draft, requestedAt = performance.now()) {
      pending = { draft, requestedAt };
      // Do not reset the timer on every input: continuous motion must render.
      if (!running && timer === null) timer = setTimeout(flush, draft ? delay : 0);
      if (!draft && timer !== null) { clearTimeout(timer); timer = setTimeout(flush, 0); }
    },
    cancel() {
      clearTimeout(timer); timer = null; pending = null;
    },
  };
}
