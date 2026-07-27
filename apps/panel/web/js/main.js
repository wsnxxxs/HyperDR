/* Entry point: boot the panel, then hand each region to its screen.
 *
 * Nothing but wiring belongs here. A screen is mounted with the element it owns
 * and reads everything else from the store, so this file stays a list of what
 * exists rather than a place logic accumulates.
 */
import { api, ApiError } from "./core/api.js";
import { store } from "./core/store.js";

const banner = document.getElementById("banner");

function showBanner(message, tone = "info") {
  banner.textContent = message;
  banner.dataset.tone = tone;
  banner.hidden = !message;
}

/** Read capabilities once. Everything downstream branches on the store, not on
 *  its own probe of the server. */
async function boot() {
  try {
    const capabilities = await api.state();
    store.set({ capabilities, phase: "ready", error: null });
    if (!capabilities.ready) {
      showBanner("未找到 HyperDR 可执行文件，转换不可用。", "error");
    }
  } catch (error) {
    const message = error instanceof ApiError ? error.message : "面板启动失败。";
    store.set({ phase: "unavailable", error: message });
    showBanner(message, "error");
  }
}

/* Screens land here one at a time, each replacing a placeholder in index.html:
 *
 *   mountStage(document.getElementById("stage"));
 *   mountSettings(document.getElementById("settings"));
 *   mountRun(document.getElementById("run"));
 *
 * The old panel is still served at / throughout, so a region that is not built
 * yet costs nothing -- compare against it rather than rushing a stub. */

boot();
