/* A tab remembers its photo, not pixel buffers or browser download URLs.
 * The server resolves the saved session and completed exports after reload. */
import { api } from "./api.js";
import { store } from "./store.js";
import { toOptions, validatedSettings } from "../settings/schema.js";
import { t } from "../i18n/index.js";

const KEY = "hyperdr.workspace.v1";

export function mountWorkspace({ stage, runner, toast }) {
  let saved = null;
  try { saved = JSON.parse(sessionStorage.getItem(KEY) || "null"); } catch {}
  if (saved?.sessionId) store.set({ restoring: true });
  let enabled = !saved?.sessionId;

  function save() {
    const state = store.get();
    if (!enabled || state.uploading || state.restoring || !state.file) return;
    try {
      sessionStorage.setItem(KEY, JSON.stringify({
        sessionId: state.sessionId, settings: toOptions(state),
        previewOptimized: state.previewOptimized,
        viewMode: state.viewMode, splitRatio: state.splitRatio,
        selectedExport: state.result?.exportId,
      }));
    } catch { /* Private browsing can disable storage; editing still works. */ }
  }
  store.subscribe(save);
  window.addEventListener("pagehide", save);

  return {
    async restore() {
      if (!saved?.sessionId) return;
      try {
        const workspace = await api.workspace(saved.sessionId);
        store.set({
          sessionId: workspace.sessionId, file: workspace.file,
          exports: workspace.exports, ...validatedSettings(saved.settings),
          previewOptimized: Boolean(saved.previewOptimized),
        });
        // Viewer defaults run on the file event; restore the chosen view after it.
        store.set({
          viewMode: ["effect", "original", "split"].includes(saved.viewMode)
            ? saved.viewMode : "effect",
          splitRatio: Number.isFinite(saved.splitRatio)
            ? Math.max(0, Math.min(1, saved.splitRatio)) : 0.5,
        });
        runner.restore(workspace, saved.selectedExport);
        await stage.reload({ resetOriginal: true });
        toast(t("workspace.restored"));
      } catch (error) {
        if (error.status === 404) {
          try { sessionStorage.removeItem(KEY); } catch {}
          toast(t("workspace.expired"));
        } else {
          // Keep the saved photo through an offline launch for the next reload.
          toast(error.message, true);
        }
      } finally {
        enabled = true;
        store.set({ restoring: false });
      }
    },
  };
}
