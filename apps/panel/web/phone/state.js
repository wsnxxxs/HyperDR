// Each phone page owns its state; desktop sessions never share these objects.
export function createPhoneState() {
  return {
    connection: { snapshot: null, capabilities: null, online: false, events: null,
      initializing: null, initControl: null, retryTimer: 0, retryDelay: 1000, retryPaused: false },
    photo: { transfer: null, frame: null, original: null, photoId: "", displayedVersion: 0,
      frameRequest: null, rendering: false },
    view: { renderer: null, comparing: false, zoom: 1, panX: 0, panY: 0,
      pointers: new Map(), gesture: null, rendererRefreshPending: false },
    diagnostics: { diagnosticRun: null, lastDiagnostic: null },
  };
}
