/* Keyboard shortcut labels for the platform the panel is running on.
 *
 * The markup names a shortcut once (`<kbd data-keys="mod+shift+z">`) and this
 * module writes what that means here: "Ctrl+Shift+Z" in the Windows shell,
 * "⇧⌘Z" on a Mac. Writing "Ctrl / ⌘" everywhere made every label twice as
 * long for a choice the reader could not make anyway.
 */

import { t } from "../i18n/index.js";

const platform = globalThis.navigator?.userAgentData?.platform
  || globalThis.navigator?.platform || "";
export const isMac = /Mac|iPhone|iPad|iPod/i.test(platform);

const MODIFIERS = isMac
  ? { mod: "⌘", shift: "⇧", alt: "⌥" }
  : { mod: "Ctrl", shift: "Shift", alt: "Alt" };
// Named keys that are words rather than glyphs, so they follow the locale.
const WORDS = { space: "keys.space", wheel: "keys.wheel" };
const GLYPHS = { "-": "−" };

/** "mod+shift+z" -> "Ctrl+Shift+Z" or "⇧⌘Z"; "+ / -" -> "+ / −". */
export function keyLabel(spec) {
  const text = String(spec || "").trim();
  if (text.includes(" / ")) return text.split(" / ").map(keyLabel).join(" / ");
  if (text === "+" || text === "-") return GLYPHS[text] || text;
  const parts = text.split("+").filter(Boolean);
  const key = parts.pop() || "";
  const shown = WORDS[key] ? t(WORDS[key]) : GLYPHS[key] || key.toUpperCase();
  // macOS lists modifiers in the order ⌃⌥⇧⌘ and joins nothing; Windows joins
  // with "+" and puts Ctrl first.
  const order = isMac ? ["alt", "shift", "mod"] : ["mod", "shift", "alt"];
  const modifiers = order.filter((name) => parts.includes(name)).map((name) => MODIFIERS[name]);
  return isMac ? [...modifiers, shown].join("") : [...modifiers, shown].join("+");
}

/** Rewrite every `kbd[data-keys]` under `root`. Safe to call again after a
 *  language change, since the spec stays in the attribute. */
export function applyKeyLabels(root = document) {
  for (const node of root.querySelectorAll("kbd[data-keys]")) {
    node.textContent = keyLabel(node.dataset.keys);
  }
}
