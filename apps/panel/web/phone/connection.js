const STATE_TIMEOUT_MS = 8000;

export function createPhoneConnection({ state, request, EventSource, setTimeout, clearTimeout,
  isHidden, applySnapshot, connectionState, notice, onCapabilities, onRetry, onPause }) {
  function receive(next) { state.snapshot = next; applySnapshot(next); }
  function subscribe() {
    // Never two subscriptions at once: an EventSource that is still open or
    // reconnecting keeps its place.
    if (isHidden() || state.retryPaused || (state.events && state.events.readyState !== EventSource.CLOSED)) return;
    state.events?.close();
    const stream = state.events = new EventSource("/api/phone/events");
    stream.onmessage = (event) => { if (state.events === stream && !isHidden()) receive(JSON.parse(event.data)); };
    stream.onerror = () => {
      if (state.events !== stream || isHidden()) return;
      connectionState(false);
      if (stream.readyState === EventSource.CLOSED) scheduleRetry();
    };
  }
  function scheduleRetry() {
    if (state.retryPaused || isHidden() || state.retryTimer) return;
    state.retryTimer = setTimeout(() => { state.retryTimer = 0; initialize(); }, state.retryDelay);
    state.retryDelay = Math.min(state.retryDelay * 2, 8000);
  }
  async function runInitialize(signal) {
    const current = () => !signal.aborted && !isHidden();
    let capabilitiesOk = Boolean(state.capabilities), stateOk = false, authFailure = false;
    if (!state.capabilities) {
      try {
        const next = await request("/api/state", undefined, { timeout: STATE_TIMEOUT_MS, signal });
        if (!current()) return;
        state.capabilities = next;
        onCapabilities(state.capabilities);
        capabilitiesOk = true;
      } catch (error) {
        if (!current()) return;
        authFailure = authFailure || error.status === 401 || error.status === 403;
        connectionState(false);
      }
    }
    try {
      const next = await request("/api/phone/state", undefined, { timeout: STATE_TIMEOUT_MS, signal });
      if (!current()) return;
      state.snapshot = next; applySnapshot(next);
      stateOk = true;
    } catch (error) {
      if (!current()) return;
      authFailure = authFailure || error.status === 401 || error.status === 403;
      connectionState(false);
    }
    state.retryPaused = authFailure || (stateOk && !state.snapshot.enabled);
    if (stateOk && !state.retryPaused) subscribe();
    if (capabilitiesOk && stateOk && !state.retryPaused) {
      notice(""); onRetry(false);
      state.retryPaused = false; state.retryDelay = 1000; clearTimeout(state.retryTimer); state.retryTimer = 0;
      return;
    }
    // 401/403 means the connection code is gone: retrying cannot bring it back.
    if (state.retryPaused) { state.events?.close(); state.events = null; }
    notice(state.retryPaused
      ? "连接口令已失效。请在电脑上重新开启手机连接，并扫描新的二维码。"
      : "连接暂时不可用，正在自动重试……也可以点击“重试连接”。");
    onRetry(true);
    connectionState(false);
    scheduleRetry();
  }
  function initialize(manual = false) {
    if (manual) {
      state.retryPaused = false; state.retryDelay = 1000;
      clearTimeout(state.retryTimer); state.retryTimer = 0;
    }
    if (isHidden() || state.retryPaused) return;
    if (!state.initializing) {
      const control = state.initControl = new AbortController();
      state.initializing = runInitialize(control.signal).finally(() => {
        if (state.initControl === control) { state.initializing = null; state.initControl = null; }
      });
    }
    return state.initializing;
  }
  function pauseConnection() {
    state.initControl?.abort(); state.initControl = null; state.initializing = null;
    onPause(); state.events?.close(); state.events = null;
    clearTimeout(state.retryTimer); state.retryTimer = 0;
  }
  return { initialize, pause: pauseConnection };
}
