import { role } from "../core/dom.js";

// Browser panels keep their own chrome. Only the Windows shell uses this header.
export function mountDesktop() {
  const controls = role("window-controls");
  if (!window.__HYPERDR_FRAMELESS__ || !window.__TAURI__?.window) return;
  const nativeWindow = window.__TAURI__.window.getCurrentWindow();
  const run = (action) => action.catch((error) => console.error("Window action failed", error));
  controls.hidden = false;
  role("window-minimize").addEventListener("click", () => run(nativeWindow.minimize()));
  role("window-maximize").addEventListener("click", () => run(nativeWindow.toggleMaximize()));
  role("window-close").addEventListener("click", () => run(nativeWindow.close()));
  controls.closest("header").addEventListener("mousedown", (event) => {
    if (event.button !== 0 || event.target.closest("button, a, input")) return;
    event.preventDefault();
    run(event.detail === 2 ? nativeWindow.toggleMaximize() : nativeWindow.startDragging());
  });
}
