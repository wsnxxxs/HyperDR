/* Light/dark toggle. The stored choice overrides the system preference; with no
 * stored choice the page follows the system and the toggle only reports it. */

import { role } from "../core/dom.js";

const STORAGE_KEY = "hyperdr.theme";
const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

export const resolvedTheme = () =>
  document.documentElement.dataset.theme || (systemDark.matches ? "dark" : "light");

export function mountTheme() {
  const button = role("theme-toggle");

  function reflect() {
    const dark = resolvedTheme() === "dark";
    const label = dark ? "切换到浅色模式" : "切换到深色模式";
    button.setAttribute("aria-pressed", String(dark));
    button.setAttribute("aria-label", label);
    button.title = label;
  }

  button.addEventListener("click", () => {
    const next = resolvedTheme() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem(STORAGE_KEY, next); } catch (_) {}
    reflect();
  });

  systemDark.addEventListener?.("change", () => {
    if (!document.documentElement.dataset.theme) reflect();
  });

  reflect();
}
