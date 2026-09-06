/* Application preferences, declared as data.
 *
 * These are *not* the conversion settings. `settings/schema.js` describes what
 * the converter is told to do with one photograph; this file describes how this
 * browser behaves, and nothing here reaches /api/run. The two vocabularies were
 * worth keeping apart even though the UI word for both would be "设置": the rail
 * is 调整, this is 偏好设置, and the code prefix is `prefs` throughout.
 *
 * Preferences are per-device on purpose. The panel is also a LAN server that a
 * phone connects to, so a server-side preference would silently retune someone
 * else's session; anything genuinely server-wide stays an environment variable
 * and is *reported* in the diagnostics group rather than edited there.
 *
 * One declaration per preference drives the widget, the stored snapshot, its
 * validation on the way back in, and the label keys. Adding a preference means
 * editing this file and the two catalogues, and nothing else.
 */

import { createStore } from "../core/store.js";

/** `kind: "toggle"` renders a chip; `kind: "segmented"` renders a button group.
 *  `choices` are [value, labelKey] pairs -- a label key of null means the label
 *  is the value itself (language names are not translated). */
export const PREFS = [
  /* -- appearance ---------------------------------------------------- */
  {
    key: "theme", group: "appearance", kind: "segmented", default: "system",
    choices: [["system", "prefs.theme.system"], ["light", "prefs.theme.light"],
              ["dark", "prefs.theme.dark"]],
  },
  {
    key: "locale", group: "appearance", kind: "segmented", default: "zh-CN",
    choices: [["zh-CN", null], ["en", null]],
    labels: { "zh-CN": "简体中文", en: "English" },
  },
  {
    key: "motion", group: "appearance", kind: "segmented", default: "system",
    choices: [["system", "prefs.motion.system"], ["reduced", "prefs.motion.reduced"]],
  },

  /* -- preview ------------------------------------------------------- */
  /* Stored as a string so "auto" and a pixel count share one segmented
   * control; stage.js turns it back into a number. */
  {
    key: "previewCeiling", group: "preview", kind: "segmented", default: "auto",
    choices: [["auto", "prefs.previewCeiling.auto"], ["960", null],
              ["1280", null], ["2048", null]],
    labels: { 960: "960 px", 1280: "1280 px", 2048: "2048 px" },
  },
  { key: "hdrPreview", group: "preview", kind: "toggle", default: true },
  {
    key: "histMode", group: "preview", kind: "segmented", default: "luma",
    choices: [["luma", "scope.luma"], ["rgb", "scope.rgb"]],
  },
  { key: "zebraHot", group: "preview", kind: "toggle", default: false },
  { key: "zebraCold", group: "preview", kind: "toggle", default: false },
  {
    key: "defaultViewMode", group: "preview", kind: "segmented", default: "effect",
    choices: [["effect", "prefs.defaultViewMode.effect"],
              ["original", "prefs.defaultViewMode.original"]],
  },

  /* -- output -------------------------------------------------------- */
  { key: "rememberOutput", group: "output", kind: "toggle", default: true },

  /* -- adjustments --------------------------------------------------- */
  /* Off by default, and deliberately so: settings/schema.js resets every image
   * control per photograph precisely so a grade cannot follow the next photo
   * unnoticed. This makes that behaviour opt-out instead of removing it. */
  { key: "rememberAdjustments", group: "adjust", kind: "toggle", default: false },
];

export const PREFS_BY_KEY = new Map(PREFS.map((pref) => [pref.key, pref]));

/** Render order of the groups; "about" has no preferences, only readouts. */
export const PREF_GROUPS = ["appearance", "preview", "output", "adjust", "about"];

const STORAGE_KEY = "hyperdr.prefs.v1";

/** The theme is also read by the pre-paint script in index.html, which runs
 *  before any module and therefore before this file exists. That script owns
 *  this key; ui/theme.js keeps writing it so the two stay agreed. */
export const THEME_KEY = "hyperdr.theme";

export function defaultPrefs() {
  const values = {};
  for (const pref of PREFS) values[pref.key] = pref.default;
  return values;
}

/** Validate one value against its declaration. Returns undefined when the
 *  stored value cannot be trusted, so the caller keeps the default. */
function validate(pref, value) {
  if (pref.kind === "toggle") return typeof value === "boolean" ? value : undefined;
  return pref.choices.some(([choice]) => choice === value) ? value : undefined;
}

/** Read the snapshot, discarding anything that no longer type-checks. A stale
 *  or hand-edited snapshot can drop a preference but cannot inject one. */
function restore() {
  const values = defaultPrefs();
  let saved;
  try { saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null"); }
  catch (_) { return values; }
  if (!saved || typeof saved !== "object") return values;
  for (const pref of PREFS) {
    const value = validate(pref, saved[pref.key]);
    if (value !== undefined) values[pref.key] = value;
  }
  return values;
}

/** Same shape as the panel's main store, so views subscribe to it the same
 *  way. Kept separate from `store` because its lifetime is the device's, not
 *  the session's. */
export const prefs = createStore(restore());

export function persistPrefs() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs.get())); }
  catch (_) { /* persistence is optional */ }
}

export function resetPrefs() {
  prefs.set(defaultPrefs());
  try { localStorage.removeItem(STORAGE_KEY); } catch (_) {}
}

/** The client-side preview ceiling in pixels, or Infinity for "auto". The
 *  server's own ceiling is applied separately in stage.js -- this one only ever
 *  narrows it further. */
export function previewCeilingPx(value = prefs.get().previewCeiling) {
  const pixels = Number(value);
  return Number.isFinite(pixels) ? pixels : Infinity;
}
