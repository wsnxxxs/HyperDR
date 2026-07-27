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
import { createCurve } from "./preview/curve.js";
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

const curve = createCurve({ onChange: () => stage.redraw() });
const stage = mountStage({ curve, toast });

mountControls();
mountMask({ curve, stage });
mountRunner({ toast });

const banner = document.getElementById("banner");

function showBanner(message, tone = "info") {
  banner.textContent = message;
  banner.dataset.tone = tone;
  banner.hidden = !message;
}

/** Read capabilities once. Everything downstream branches on the store, not on
 *  its own probe of the server. */
async function boot() {
  const dot = role("service-dot");
  const text = role("service-text");
  try {
    const capabilities = await api.state();
    store.set({ capabilities, phase: "ready", error: null });
    dot.classList.add(capabilities.ready ? "is-ok" : "is-bad");
    setText(text, capabilities.ready ? "本地处理服务已就绪" : "未找到 HyperDR");
    if (!capabilities.ready) {
      showBanner("未找到 HyperDR 可执行文件，转换不可用。", "error");
    }
  } catch (error) {
    const message = error instanceof ApiError ? error.message : "面板启动失败。";
    store.set({ phase: "unavailable", error: message });
    dot.classList.add("is-warn");
    setText(text, "后端未响应（离线预览）");
    showBanner(message, "error");
  }
}

boot();
