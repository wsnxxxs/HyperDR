/* Composition root.
 *
 * Every module is a `mount*` function wired to the store and whatever
 * collaborators it needs; this file is the single place that knows the shape
 * of the panel. Nothing reaches for a global.
 */
import { api, ApiError } from "./core/api.js";
import { store } from "./core/store.js";
import { role, setText } from "./core/dom.js";
import { defaultSettings } from "./settings/schema.js";
import { mountControls } from "./settings/controls.js";
import { mountStage } from "./preview/stage.js";
import { mountMask } from "./preview/mask.js";
import { mountRunner } from "./run/runner.js";
import { createToast } from "./ui/toast.js";
import { mountTheme } from "./ui/theme.js";

// The schema's defaults become store keys here, so core/store.js never has to
// know a control's name -- the dependency points settings -> core, not back.
store.set(defaultSettings());

const toast = createToast();
mountTheme();

const stage = mountStage({ toast });

mountControls();
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
    showService("is-warn", "后端未响应（离线预览）", message);
  }
}

boot();
