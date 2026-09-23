import { store } from "../core/store.js";
import { role, el } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { availableModelIds, restoredModelId } from "../settings/model-ids.js";
import { modelLabel, fallbackFields } from "../settings/model-select.js";
import { encodingById, validatedSettings } from "../settings/schema.js";
import { bindSaveAction } from "./save.js";
import { entryKeyFor, exportKeyFor } from "./options.js";

export function mountExportHistory({ selectResult }) {
  const open = role("versions-open");
  const dialog = el("dialog", { class: "versions-dialog", "aria-labelledby": "versions-title" });
  const title = el("h2", { id: "versions-title" });
  const close = el("button", { type: "button", class: "icon-button" }, el("i", { class: "ph ph-x", "aria-hidden": "true" }));
  const note = el("p");
  const list = el("div", { class: "version-list" });
  dialog.append(el("header", { class: "export-head" }, el("div", {}, title, note), close), list);
  document.body.append(dialog);
  open.addEventListener("click", () => dialog.showModal());
  close.addEventListener("click", () => dialog.close());
  function sync(state = store.get()) {
    const entries = state.exports || [];
    const currentKey = exportKeyFor(state);
    const busy = state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    title.textContent = t("workspace.versions");
    note.textContent = t("workspace.versionNote");
    open.querySelector("span").textContent = `${t("workspace.versions")}${entries.length ? ` · ${entries.length}` : ""}`;
    close.setAttribute("aria-label", t("editor.closeVersions"));
    close.title = t("editor.closeVersions");
    list.replaceChildren();
    if (!entries.length) list.append(el("p", { class: "versions-empty" }, t("editor.noVersions")));
    for (const [index, entry] of entries.entries()) {
      // Two facts a version card can state and the user can act on: whether
      // it is exactly the edit on screen, and whether it has left the
      // workspace. "Current version" said neither.
      const matches = entryKeyFor(entry, state) === currentKey;
      const saved = Boolean(state.savedExports?.[entry.id]);
      const restore = el("button", { type: "button", class: "button" }, t("workspace.restoreSettings"));
      restore.disabled = busy || matches;
      if (matches) restore.title = t("workspace.alreadyCurrent");
      restore.addEventListener("click", () => {
        selectResult(entry);
        store.set({
          ...validatedSettings(entry.options),
          previewOptimized: Boolean(entry.options.useModel),
          // An export written before the selector existed produced its bytes with
          // the incumbent, so that is the model restoring it recovers.
          modelId: restoredModelId(entry.options, availableModelIds(store.get())),
        });
        dialog.close();
      });
      const save = el("button", { class: "button", type: "button" }, t("out.download"));
      const saveState = el("p", { class: "save-state version-save-state", role: "status",
        "aria-live": "polite", hidden: true });
      const openFolder = el("button", { class: "button", type: "button" }, t("save.openFolder"));
      bindSaveAction(save, saveState, () => ({
        sessionId: entry.sessionId || state.sessionId,
        exportId: entry.id,
        name: entry.name,
      }), { openFolderButton: openFolder });
      const time = new Date(entry.createdAt * 1000).toLocaleString(document.documentElement.lang);
      const result = entry.report?.files?.find((file) => file.success);
      const modelName = entry.options.useModel
        ? modelLabel(result?.model_requested_id || restoredModelId(entry.options), state)
        : t("adjust.manual");
      const fallback = result?.model_inference_mode === "pixel_only_fallback"
        ? t("adjust.modelFallback", { model: modelLabel(result.model_id, state),
          fields: fallbackFields(result.model_fallback_reason) }) : "";
      const size = result?.width && result?.height ? `${result.width}×${result.height}` : "";
      const speed = ["adaptive", "pq", "hlg"].includes(entry.options.encoding) &&
        entry.options.hevcPreset === "medium" ? t("out.hevcFast") : "";
      list.append(el("article", { class: "version-card", "data-selected": String(matches) },
        el("div", { class: "version-heading" }, el("span", { class: "version-index" }, String(entries.length - index).padStart(2, "0")),
          el("h3", {}, entry.name),
          matches ? el("span", { class: "version-selected" }, t("workspace.matchesCurrent")) : null,
          saved ? el("span", { class: "version-saved" }, t("workspace.savedBadge")) : null),
        el("p", {}, [time, encodingById(entry.options.encoding).label, speed, modelName, size].filter(Boolean).join(" · ")),
        fallback ? el("p", {}, fallback) : null,
        el("div", { class: "version-actions" }, restore, save, openFolder), saveState));
    }
  }
  store.watchAny(["exports", "uploading", "restoring", "optimizing", "starting", "jobId", "result"], sync, { immediate: true });
  // Reopening shows the current comparison and saved state; the cards are not
  // rebuilt underneath a save that is still reporting its result.
  open.addEventListener("click", () => sync());
  onLocaleChange(() => sync());
}
