import { store } from "../core/store.js";
import { role, el } from "../core/dom.js";
import { api } from "../core/api.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { availableModelIds, restoredModelId } from "../settings/model-ids.js";
import { modelLabel, fallbackFields } from "../settings/model-select.js";
import { encodingById, validatedSettings } from "../settings/schema.js";

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
    title.textContent = t("workspace.versions");
    note.textContent = t("workspace.versionNote");
    open.querySelector("span").textContent = `${t("workspace.versions")}${entries.length ? ` · ${entries.length}` : ""}`;
    close.setAttribute("aria-label", t("editor.closeVersions"));
    list.replaceChildren();
    if (!entries.length) list.append(el("p", { class: "versions-empty" }, t("editor.noVersions")));
    for (const [index, entry] of entries.entries()) {
      const restore = el("button", { type: "button", class: "button" }, t("workspace.restoreSettings"));
      restore.disabled = state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
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
      const download = el("a", { class: "button", href: api.resultUrl(state.sessionId, { download: true, exportId: entry.id }), download: "" }, t("out.download"));
      const time = new Date(entry.createdAt * 1000).toLocaleString(document.documentElement.lang);
      const result = entry.report?.files?.find((file) => file.success);
      const modelName = entry.options.useModel
        ? modelLabel(result?.model_requested_id || restoredModelId(entry.options), state)
        : t("adjust.manual");
      const fallback = result?.model_inference_mode === "pixel_only_fallback"
        ? t("adjust.modelFallback", { model: modelLabel(result.model_id, state),
          fields: fallbackFields(result.model_fallback_reason) }) : "";
      list.append(el("article", { class: "version-card", "data-selected": String(state.result?.exportId === entry.id) },
        el("div", { class: "version-heading" }, el("span", { class: "version-index" }, String(entries.length - index).padStart(2, "0")),
          el("h3", {}, entry.name), state.result?.exportId === entry.id ? el("span", { class: "version-selected" }, t("workspace.selectedVersion")) : null),
        el("p", {}, `${time} · ${encodingById(entry.options.encoding).label} · ${modelName}`),
        fallback ? el("p", {}, fallback) : null,
        el("div", { class: "version-actions" }, restore, download)));
    }
  }
  store.watchAny(["exports", "uploading", "restoring", "optimizing", "starting", "jobId", "result"], sync, { immediate: true });
  onLocaleChange(() => sync());
}
