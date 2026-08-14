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
  CONTROLS, PERSISTED_OPTION_KEYS, defaultSettings, encodingById,
} from "./settings/schema.js";
import { mountControls } from "./settings/controls.js";
import { mountStage } from "./preview/stage.js";
import { mountMask } from "./preview/mask.js";
import { mountRunner } from "./run/runner.js";
import { createToast } from "./ui/toast.js";
import { mountTheme } from "./ui/theme.js";

// The schema's defaults become store keys here, so core/store.js never has to
// know a control's name -- the dependency points settings -> core, not back.
store.set(defaultSettings());

/* Output format is a workflow choice and may survive a page refresh. Image
 * adjustment controls are intentionally not persisted: every new photo starts
 * from the schema defaults. The persisted value is still validated against the
 * schema so a stale or hand-edited snapshot cannot inject nonsense. */
const SETTINGS_KEY = "hyperdr.settings.v2";
const LEGACY_SETTINGS_KEY = "hyperdr.settings";

function settingsSnapshot(state) {
  const snapshot = {};
  for (const key of PERSISTED_OPTION_KEYS) snapshot[key] = state[key];
  return snapshot;
}

function restoreSettings() {
  let saved;
  let legacy = false;
  try {
    const current = localStorage.getItem(SETTINGS_KEY);
    legacy = !current;
    saved = JSON.parse(current || localStorage.getItem(LEGACY_SETTINGS_KEY) || "null");
  }
  catch (_) { return; }
  if (!saved || typeof saved !== "object") return;
  const patch = {};
  for (const control of CONTROLS) {
    if (!PERSISTED_OPTION_KEYS.includes(control.key)) continue;
    const value = saved[control.key];
    if (value === undefined) continue;
    if (control.kind === "segmented") {
      if (control.choices.some(([id]) => id === value)) patch[control.key] = value;
    } else if (Number.isFinite(value)) {
      patch[control.key] = Math.min(control.max, Math.max(control.min, value));
    }
  }
  patch.encoding = encodingById(saved.encoding).id;
  // The fresh default range must respect the restored encoding's ceiling.
  patch.hdrRange = Math.min(
    Number.isFinite(patch.hdrRange) ? patch.hdrRange : store.get().hdrRange,
    encodingById(patch.encoding).maxRange);
  store.set(patch);
  // Rewrite both legacy and current snapshots without image-scoped adjustment
  // keys, so an old grade cannot be resurrected later.
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settingsSnapshot(store.get())));
    if (legacy) localStorage.removeItem(LEGACY_SETTINGS_KEY);
  } catch (_) { /* persistence is optional */ }
}

const persistSettings = debounce(() => {
  const state = store.get();
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settingsSnapshot(state)));
  } catch (_) {}
}, 400);

restoreSettings();
store.watchAny(PERSISTED_OPTION_KEYS, persistSettings);

const toast = createToast();
mountTheme();

const stage = mountStage({ toast });

mountControls({ toast });
mountMask({ stage });
mountRunner({ toast });

const settings = document.getElementById("settings");

store.watch("file", (file) => {
  const disabled = !file;
  settings.classList.toggle("is-disabled", disabled);
  settings.inert = disabled;
  settings.setAttribute("aria-disabled", String(disabled));
}, { immediate: true });

/** The header pill is the whole report: a dot for tone, a short label, and the
 *  full sentence on the pill's `title` for the failure cases where the label
 *  alone does not say what went wrong. */
function showService(tone, label, detail = "") {
  const pill = role("service-state");
  role("service-dot").classList.add(tone);
  setText(role("service-text"), label);
  pill.dataset.tone = tone;
  if (detail) pill.title = detail; else pill.removeAttribute("title");
}

/** Read capabilities once. Everything downstream branches on the store, not on
 *  its own probe of the server. */
async function boot() {
  try {
    const capabilities = await api.state();
    store.set({ capabilities, phase: "ready", error: null });
    if (capabilities.ready) showService("is-ok", "本地处理服务已就绪");
    else showService("is-bad", "未找到 HyperDR", "未找到 HyperDR 可执行文件，转换不可用。");
  } catch (error) {
    const message = error instanceof ApiError ? error.message : "面板启动失败。";
    store.set({ phase: "unavailable", error: message });
    showService("is-warn", "服务未响应 · 无法转换", message);
  }
}

boot();
