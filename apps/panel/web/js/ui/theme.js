/* Light/dark, in two places that have to agree.
 *
 * `prefs.theme` is the real setting and has three states; the header button is
 * a shortcut that only ever picks light or dark, because a three-way cycle on
 * an icon button is a guessing game. Choosing "system" in preferences is how
 * you get back to following the OS -- which the old two-state toggle made
 * unreachable once it had been clicked.
 *
 * `localStorage["hyperdr.theme"]` stays the wire format: the pre-paint script
 * in index.html reads it before any module exists, so it cannot be folded into
 * the preferences snapshot. "system" is represented by the key's absence,
 * which is exactly what that script already treats as "follow the OS".
 */

import { role } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { prefs, THEME_KEY } from "./prefs-schema.js";

const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

export const resolvedTheme = () =>
  document.documentElement.dataset.theme || (systemDark.matches ? "dark" : "light");

/** Push `prefs.theme` onto the document and the key the pre-paint script reads. */
function applyTheme(choice) {
  if (choice === "system") {
    delete document.documentElement.dataset.theme;
    try { localStorage.removeItem(THEME_KEY); } catch (_) {}
  } else {
    document.documentElement.dataset.theme = choice;
    try { localStorage.setItem(THEME_KEY, choice); } catch (_) {}
  }
}

export function mountTheme() {
  const button = role("theme-toggle");

  function reflect() {
    const dark = resolvedTheme() === "dark";
    const label = dark ? t("app.theme.toLight") : t("app.theme.toDark");
    button.setAttribute("aria-pressed", String(dark));
    button.setAttribute("aria-label", label);
    button.title = label;
  }

  button.addEventListener("click", () => {
    // The shortcut leaves "system" behind deliberately: the click means "I want
    // it the other way now", which is a concrete choice, not a preference to
    // keep tracking the OS.
    prefs.set({ theme: resolvedTheme() === "dark" ? "light" : "dark" });
  });

  prefs.watch("theme", (choice) => { applyTheme(choice); reflect(); });

  systemDark.addEventListener?.("change", () => {
    if (!document.documentElement.dataset.theme) reflect();
  });

  onLocaleChange(reflect);

  applyTheme(prefs.get().theme);
  reflect();
}
