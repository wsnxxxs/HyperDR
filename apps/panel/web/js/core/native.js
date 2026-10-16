/* What the front-end asks of the host shell, in one module.
 *
 * The panel runs in a browser or inside the Tauri shell. Everything that needs
 * the shell -- native file and folder dialogs, dropped file paths, window
 * controls -- goes through
 * here, so no other module reads `window.__TAURI__`, and a different host (a
 * mobile shell, a test) only replaces this file. Every capability is optional:
 * callers check it and fall back to the browser's own behaviour.
 *
 * Server work is not here: that is core/api.js.
 */

const tauri = () => globalThis.__TAURI__;

/* Native drag-and-drop. The shell cannot hand a WebView a File for a dropped
 * path, so it appends the paths to this queue and then fires the event. */
const DROP_QUEUE = "__HYPERDR_NATIVE_FILE_DROPS__";
const DROP_EVENT = "hyperdr:native-file-drop";

export const native = {
  /** The shell's file dialog (`open(options)` resolving to a path, a list of
   *  paths, or null when dismissed), or undefined in a browser. */
  get dialog() {
    const dialog = tauri()?.dialog;
    return typeof dialog?.open === "function" ? dialog : undefined;
  },

  get canPickFolder() { return Boolean(native.dialog); },

  /** A folder chosen in the shell's dialog; "" when it was dismissed. */
  async pickFolder() {
    const path = await native.dialog.open({ directory: true, multiple: false });
    return typeof path === "string" ? path : "";
  },

  /** Whether the shell has queued dropped paths (possibly before the page
   *  was listening). */
  get hasDroppedPaths() { return Array.isArray(globalThis[DROP_QUEUE]); },

  /** Every queued dropped path, emptying the queue. */
  takeDroppedPaths() {
    const queued = globalThis[DROP_QUEUE];
    globalThis[DROP_QUEUE] = [];
    return Array.isArray(queued) ? queued.filter((value) => typeof value === "string" && value) : [];
  },

  onFileDrop(listener) { globalThis.addEventListener?.(DROP_EVENT, listener); },

  /** The current window (minimize, toggleMaximize, close, startDragging,
   *  isFullscreen), or null outside a desktop shell. */
  currentWindow() {
    const window = tauri()?.window;
    return typeof window?.getCurrentWindow === "function" ? window.getCurrentWindow() : null;
  },
};
