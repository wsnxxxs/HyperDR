import { role } from "../core/dom.js";
import { native } from "../core/native.js";
import { platform } from "../core/platform.js";

/* Browser panels keep the browser's chrome. A desktop shell that drew no title
 * bar hands that job to the header: with a "custom" title bar (Windows) the
 * panel also draws the caption buttons; with an "overlay" title bar (macOS)
 * the system keeps its traffic lights and the header only has to drag. */
export function mountDesktop() {
  const controls = role("window-controls");
  if (platform.titleBar === "native") return;
  const nativeWindow = native.currentWindow();
  if (!nativeWindow) return;
  const run = (action) => action.catch((error) => console.error("Window action failed", error));
  if (platform.titleBar === "custom") {
    controls.hidden = false;
    role("window-minimize").addEventListener("click", () => run(nativeWindow.minimize()));
    role("window-maximize").addEventListener("click", () => run(nativeWindow.toggleMaximize()));
    role("window-close").addEventListener("click", () => run(nativeWindow.close()));
  }
  controls.closest("header").addEventListener("mousedown", (event) => {
    if (event.button !== 0 || event.target.closest("button, a, input, select")) return;
    event.preventDefault();
    run(event.detail === 2 ? nativeWindow.toggleMaximize() : nativeWindow.startDragging());
  });
  // The traffic lights leave with full screen, and so does the space kept for
  // them. A shell without the is-fullscreen permission keeps the space.
  if (platform.titleBar === "overlay" && typeof nativeWindow.isFullscreen === "function") {
    const sync = () => nativeWindow.isFullscreen()
      .then((full) => document.documentElement.toggleAttribute("data-fullscreen", full))
      .catch(() => {});
    window.addEventListener("resize", sync);
    sync();
  }
}
