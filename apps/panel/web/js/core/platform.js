/* Which operating system and host shell the panel is running in.
 *
 * One answer for the whole front-end. `applyPlatform()` writes it onto <html>
 * as `data-os`, `data-shell` and `data-titlebar`, so css/adaptive.css can adapt
 * without script; the few modules that must branch in code import `platform`.
 *
 * A host shell may announce itself with an initialization script that runs
 * before the page:
 *
 *   window.__HYPERDR_SHELL__ = { os: "macos", titleBar: "overlay" };
 *
 * `os` is windows | macos | linux | ios | android. `titleBar` is
 *   custom   decorations are off and the panel draws caption buttons (Windows)
 *   overlay  the system draws its buttons over the header (macOS traffic lights)
 *   native   the window manager or browser owns the title bar (default)
 * The Windows shell's older `__HYPERDR_FRAMELESS__ = true` means
 * `{ os: "windows", titleBar: "custom" }`. Without an announcement the user
 * agent decides the OS, and the title bar is never the panel's job.
 *
 * core/keys.js keeps its own one-line Mac check on purpose: it is loaded in
 * isolation by tests/js/panel_interaction_test.mjs.
 */

const OS_NAMES = new Set(["windows", "macos", "linux", "ios", "android"]);
const TITLE_BARS = new Set(["custom", "overlay", "native"]);

function osFromAgent(navigator = {}) {
  const agent = navigator.userAgent || "";
  const hint = navigator.userAgentData?.platform || navigator.platform || "";
  if (/Android/i.test(agent)) return "android";
  if (/iPhone|iPad|iPod/i.test(agent + hint)) return "ios";
  // iPadOS requests desktop sites and reports a Mac; only it has touch points.
  if (/Mac/i.test(hint || agent)) return navigator.maxTouchPoints > 1 ? "ios" : "macos";
  if (/Win/i.test(hint || agent)) return "windows";
  if (/Linux|CrOS|Chrome OS/i.test(hint || agent)) return "linux";
  return "unknown";
}

/** @returns {{os: string, shell: "tauri"|"browser", titleBar: string, mobile: boolean}} */
export function detectPlatform(scope = globalThis) {
  const announced = scope.__HYPERDR_SHELL__
    || (scope.__HYPERDR_FRAMELESS__ ? { os: "windows", titleBar: "custom" } : {});
  const shell = scope.__TAURI__ || scope.__TAURI_INTERNALS__ ? "tauri" : "browser";
  const os = OS_NAMES.has(announced.os) ? announced.os : osFromAgent(scope.navigator);
  // Only a native shell can hand the title bar to the page.
  const titleBar = shell === "tauri" && TITLE_BARS.has(announced.titleBar) ? announced.titleBar : "native";
  return { os, shell, titleBar, mobile: os === "ios" || os === "android" };
}

export const platform = detectPlatform();

export function applyPlatform(root = document.documentElement, current = platform) {
  root.dataset.os = current.os;
  root.dataset.shell = current.shell;
  root.dataset.titlebar = current.titleBar;
}
