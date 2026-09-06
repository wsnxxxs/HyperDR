/* Composition root.
 *
 * Every module is a `mount*` function wired to the store and whatever
 * collaborators it needs; this file is the single place that knows the shape
 * of the panel. Nothing reaches for a global.
 */
import { api, ApiError } from "./core/api.js";
import { store } from "./core/store.js";
import { role, setText, debounce } from "./core/dom.js";
import {
  CONTROLS, PERSISTED_OPTION_KEYS, defaultSettings, validatedSettings,
} from "./settings/schema.js";
import { mountWorkspace } from "./core/workspace.js";
import { mountHistory } from "./settings/history-controls.js";
import { mountControls } from "./settings/controls.js";
import { mountStage } from "./preview/stage.js";
import { mountMask } from "./preview/mask.js";
import { mountRunner } from "./run/runner.js";
import { createToast } from "./ui/toast.js";
import { mountTheme } from "./ui/theme.js";
import { mountPrefs } from "./ui/prefs.js";
import { prefs } from "./ui/prefs-schema.js";
import { t, setLocale, applyStatic, onLocaleChange } from "./i18n/index.js";

// The schema's defaults become store keys here, so core/store.js never has to
// know a control's name -- the dependency points settings -> core, not back.
store.set(defaultSettings());

/* ── device preferences ────────────────────────────────────────────────
 * Applied before anything mounts, so no view ever paints in the wrong
 * language or with a transition the user asked not to see. */

document.documentElement.lang = prefs.get().locale;
setLocale(prefs.get().locale);
applyStatic();
prefs.watch("locale", setLocale);

/** The system's own reduce-motion setting is honoured by tokens.css; this is
 *  the override for people whose OS says one thing and who want the other. */
function applyMotion(choice) {
  if (choice === "reduced") document.documentElement.dataset.motion = "reduced";
  else delete document.documentElement.dataset.motion;
}
applyMotion(prefs.get().motion);
prefs.watch("motion", applyMotion);

/* ── settings persistence ──────────────────────────────────────────────
 *
 * Output format is a workflow choice and may survive a page refresh. Image
 * adjustment controls are not persisted by default: every new photo starts
 * from the schema defaults, so the last photo's grade cannot follow this one
 * unnoticed. `rememberAdjustments` makes that opt-out rather than absolute,
 * which is why the persisted key set is computed instead of constant.
 *
 * The persisted value is still validated against the schema, so a stale or
 * hand-edited snapshot cannot inject nonsense. */
const SETTINGS_KEY = "hyperdr.settings.v2";
const LEGACY_SETTINGS_KEY = "hyperdr.settings";

/* `pinned` controls are excluded on purpose: they have no widget, and
 * command.py's PANEL_DEFAULTS holds the same values, so persisting them could
 * only ever make an export drift from the defaults it is meant to match. */
const ADJUSTMENT_KEYS = CONTROLS
  .filter((control) => control.group !== "pinned")
  .map((control) => control.key);

function persistedKeys(preferences = prefs.get()) {
  return [
    ...(preferences.rememberOutput ? PERSISTED_OPTION_KEYS : []),
    ...(preferences.rememberAdjustments ? ADJUSTMENT_KEYS : []),
  ];
}

function settingsSnapshot(state, keys = persistedKeys()) {
  const snapshot = {};
  for (const key of keys) snapshot[key] = state[key];
  return snapshot;
}

function writeSnapshot() {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settingsSnapshot(store.get())));
  } catch (_) { /* persistence is optional */ }
}

function restoreSettings() {
  const keys = persistedKeys();
  let saved;
  let legacy = false;
  try {
    const current = localStorage.getItem(SETTINGS_KEY);
    legacy = !current;
    saved = JSON.parse(current || localStorage.getItem(LEGACY_SETTINGS_KEY) || "null");
  }
  catch (_) { return; }
  if (!saved || typeof saved !== "object") return;
  const selected = Object.fromEntries(keys.filter((key) => saved[key] !== undefined)
    .map((key) => [key, saved[key]]));
  store.set(validatedSettings(selected, store.get()));
  // Rewrite both legacy and current snapshots with only the keys that are
  // persisted now, so a grade stored under an older preference cannot be
  // resurrected by turning the preference back on later.
  writeSnapshot();
  try { if (legacy) localStorage.removeItem(LEGACY_SETTINGS_KEY); } catch (_) {}
}

const persistSettings = debounce(writeSnapshot, 400);

restoreSettings();

/* The watched key set changes with the preferences, so the subscription is
 * rebuilt rather than filtered -- and the snapshot is rewritten immediately, so
 * turning a preference off drops what it was keeping right away instead of at
 * the next unrelated change. */
let unwatchSettings = store.watchAny(persistedKeys(), persistSettings);
prefs.watchAny(["rememberOutput", "rememberAdjustments"], () => {
  unwatchSettings();
  unwatchSettings = store.watchAny(persistedKeys(), persistSettings);
  persistSettings.cancel();
  writeSnapshot();
});

const toast = createToast();
mountTheme();

const stage = mountStage({ toast });

mountControls({ toast });
mountMask({ stage });
const runner = mountRunner({ toast });
const workspace = mountWorkspace({ stage, runner, toast });
mountHistory();
mountPrefs({ toast });

/* Viewer defaults are per photograph, not per session: they are what each new
 * image should open with, which is what the preferences promise. */
store.watch("file", (file) => {
  if (!file) return;
  const preferences = prefs.get();
  store.set({
    viewMode: preferences.defaultViewMode,
    histMode: preferences.histMode,
    zebraHot: preferences.zebraHot,
    zebraCold: preferences.zebraCold,
  });
});
store.set({
  viewMode: prefs.get().defaultViewMode,
  histMode: prefs.get().histMode,
  zebraHot: prefs.get().zebraHot,
  zebraCold: prefs.get().zebraCold,
});

const settings = document.getElementById("settings");

store.watchAny(["file", "previewReady"], (state) => {
  const disabled = !state.file || !state.previewReady;
  settings.classList.toggle("is-disabled", disabled);
  settings.inert = disabled;
  settings.setAttribute("aria-disabled", String(disabled));
}, { immediate: true });

/** The header pill is the whole report: a dot for tone, a short label, and the
 *  full sentence on the pill's `title` for the failure cases where the label
 *  alone does not say what went wrong. */
let service = null;
function showService(tone, labelKey, detailKey = "") {
  service = { tone, labelKey, detailKey };
  const pill = role("service-state");
  role("service-dot").classList.add(tone);
  setText(role("service-text"), t(labelKey));
  pill.dataset.tone = tone;
  // A server-supplied message is already a sentence, not a key; `t` returns an
  // unknown key unchanged, which is what makes both cases work here.
  const detail = detailKey ? t(detailKey) : "";
  if (detail) pill.title = detail; else pill.removeAttribute("title");
}
onLocaleChange(() => {
  if (service) showService(service.tone, service.labelKey, service.detailKey);
});

/** Read capabilities once. Everything downstream branches on the store, not on
 *  its own probe of the server. */
async function boot() {
  try {
    const capabilities = await api.state();
    store.set({ capabilities, phase: "ready", error: null });
    if (capabilities.ready) showService("is-ok", "app.service.ready");
    else showService("is-bad", "app.service.missing", "app.service.missingDetail");
    await workspace.restore();
  } catch (error) {
    const message = error instanceof ApiError ? error.message : t("app.service.bootFailed");
    store.set({ phase: "unavailable", error: message });
    showService("is-warn", "app.service.unavailable", message);
    store.set({ restoring: false });
  }
}

boot();
