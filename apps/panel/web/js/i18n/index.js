/* String catalogue and the two ways text reaches the page.
 *
 * There is no build step, so the catalogues are static imports rather than
 * fetched JSON: no async gap before first paint, nothing to configure in the
 * CSP, and the tree still opens from disk. Two locales are small enough that
 * splitting them per language would cost a round trip to save nothing. If a
 * fourth locale ever lands, that is the moment to switch to dynamic import.
 *
 * Markup carries `data-i18n` / `data-i18n-attr` and is refreshed wholesale by
 * `applyStatic()`. Strings built in JavaScript call `t()` and re-run through an
 * `onLocaleChange` subscription, because every view here mounts once and then
 * mutates its own nodes -- there is no render pass to re-enter.
 */

import zhCN from "./zh-CN.js";
import en from "./en.js";

const CATALOGUES = { "zh-CN": zhCN, en };

export const DEFAULT_LOCALE = "zh-CN";
export const LOCALES = Object.keys(CATALOGUES);

let active = DEFAULT_LOCALE;
const listeners = new Set();

/** `{name}` placeholders, filled from `params`. A placeholder with no matching
 *  parameter is left as written: a visible `{gamut}` is a bug report, an empty
 *  string is a mystery. */
function interpolate(template, params) {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name) =>
    (name in params ? String(params[name]) : whole));
}

/** Look a key up in the active catalogue, then in the default one, then give
 *  back the key. A missing translation therefore degrades to Chinese rather
 *  than to a blank label; scripts/check_panel_i18n.py is what keeps that from
 *  happening silently in the first place. */
export function t(key, params) {
  const template = CATALOGUES[active]?.[key] ?? CATALOGUES[DEFAULT_LOCALE]?.[key] ?? key;
  return interpolate(template, params);
}

export const currentLocale = () => active;

export const isLocale = (value) => Object.hasOwn(CATALOGUES, value);

/** Fill every `data-i18n` (textContent) and `data-i18n-attr` (attributes) node
 *  under `root`. Safe to call repeatedly; that is how a locale switch reaches
 *  the markup. */
export function applyStatic(root = document) {
  for (const node of root.querySelectorAll("[data-i18n]")) {
    node.textContent = t(node.dataset.i18n);
  }
  // "aria-label:prefs.close;title:prefs.close" -- one node, several attributes.
  for (const node of root.querySelectorAll("[data-i18n-attr]")) {
    for (const pair of node.dataset.i18nAttr.split(";")) {
      const [attribute, key] = pair.split(":");
      if (attribute && key) node.setAttribute(attribute.trim(), t(key.trim()));
    }
  }
}

/** @returns {() => void} unsubscribe */
export function onLocaleChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function setLocale(next) {
  if (!isLocale(next) || next === active) return;
  active = next;
  document.documentElement.lang = next;
  applyStatic();
  // Snapshot: a subscriber may unsubscribe while the notification runs.
  for (const listener of [...listeners]) listener(active);
}
