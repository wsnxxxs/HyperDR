import { store } from "../core/store.js";
import { role, el, setText, setPressed } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { encodingById, OPTION_KEYS, toOptions } from "../settings/schema.js";
import { planeToImageData } from "../preview/cpu.js";

export function mountEditor({ stage }) {
  const open = role("open-photo");
  const exportOpen = role("export-open");
  const dialog = role("export-dialog");
  const close = role("export-close");
  const filename = role("editor-filename");
  const documentState = role("document-state");
  const metadata = role("photo-meta");
  const viewerHint = role("viewer-hint");
  role("shortcuts-open").addEventListener("click", () => role("shortcuts-dialog").showModal());
  const exportFilename = role("export-filename");
  const summary = role("export-summary");
  const thumbnail = role("export-thumbnail");
  const modes = role("viewer-modes");
  const fit = role("zoom-fit");
  const zoomOut = role("zoom-out");
  const zoomIn = role("zoom-in");
  const zoomValue = role("zoom-value");
  const modeButtons = [
    ["original", "editor.original"], ["effect", "editor.effect"], ["split", "editor.compare"],
  ].map(([value, label]) => {
    const button = el("button", { type: "button", "aria-pressed": "false" });
    button.addEventListener("click", () => store.set({ viewMode: value }));
    modes.append(button);
    return { value, label, button };
  });

  function paintThumbnail() {
    const frame = stage.getFrame();
    if (!frame) return;
    const source = document.createElement("canvas");
    source.width = frame.width; source.height = frame.height;
    source.getContext("2d", { colorSpace: "display-p3" }).putImageData(
      planeToImageData(frame.hdr, frame.width, frame.height, true), 0, 0);
    thumbnail.width = 390;
    thumbnail.height = Math.round(390 * frame.height / frame.width);
    thumbnail.getContext("2d", { colorSpace: "display-p3" }).drawImage(source, 0, 0, thumbnail.width, thumbnail.height);
  }
  function sync() {
    const state = store.get();
    const sdr = state.encoding === "sdr-jpeg";
    open.closest(".app").dataset.workspace = state.file ? "editing" : state.uploading || state.restoring ? "loading" : "empty";
    const ready = Boolean(state.file && state.previewReady);
    open.disabled = state.restoring || state.uploading || state.starting || state.optimizing || Boolean(state.jobId);
    exportOpen.disabled = !state.file || state.uploading || state.restoring;
    setText(exportOpen.querySelector("span"), state.jobId || state.starting ? t("editor.exporting") : sdr ? t("workflow.saveJpeg") : t("editor.export"));
    setText(filename, state.file?.name || t("editor.noPhoto"));
    filename.title = state.file?.name || "";
    const currentKey = JSON.stringify({ ...toOptions(state), useModel: Boolean(state.previewOptimized) });
    const exported = state.result?.optionsKey === currentKey;
    documentState.dataset.state = !state.file ? "empty" : exported ? "saved" : "edited";
    setText(documentState, !state.file ? t("workspace.waiting") : exported ? t("workspace.exported") : t("workspace.dirty"));
    const frame = stage.getFrame();
    const size = state.file?.size > 0 ? `${(state.file.size / 1048576).toFixed(1)} MB` : "";
    setText(metadata, frame ? [t("workspace.previewSize", { width: frame.width, height: frame.height }), size].filter(Boolean).join(" · ") : "");
    setText(viewerHint, !ready ? "" : state.viewerZoom > 1 ? t("workspace.panHint") : state.viewMode === "split" ? t("workspace.compareHint") : t("workspace.photoHint"));
    setText(exportFilename, state.file?.name || "");
    setText(summary, sdr ? t("workflow.jpegSummary") : `${state.previewOptimized ? t("adjust.ai") : t("adjust.manual")} · ${encodingById(state.encoding).label}`);
    for (const { value, label, button } of modeButtons) {
      setText(button, sdr && value === "effect" ? t("workflow.colorEffect") : t(label)); setPressed(button, state.viewMode === value); button.disabled = !ready;
    }
    fit.disabled = zoomOut.disabled = zoomIn.disabled = !ready;
    setText(zoomValue, `${Math.round(state.viewerZoom * 100)}%`);
    setPressed(fit, state.viewerZoom === 1);
  }
  function showExport() {
    if (exportOpen.disabled || dialog.open) return;
    paintThumbnail();
    dialog.showModal();
  }
  open.addEventListener("click", stage.openPicker);
  exportOpen.addEventListener("click", showExport);
  close.addEventListener("click", () => dialog.close());
  fit.addEventListener("click", () => store.set({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0 }));
  zoomIn.addEventListener("click", () => store.set({ viewerZoom: Math.min(4, store.get().viewerZoom + .25) }));
  zoomOut.addEventListener("click", () => store.set({ viewerZoom: Math.max(1, store.get().viewerZoom - .25) }));
  store.watchAny(["file", "previewReady", "uploading", "restoring", "starting", "optimizing", "jobId", "encoding", "previewOptimized", "viewMode", "viewerZoom", "result", ...OPTION_KEYS], sync, { immediate: true });
  stage.onSourceChange(() => { sync(); if (dialog.open) paintThumbnail(); });
  onLocaleChange(sync);
  document.addEventListener("keydown", (event) => {
    if (event.target.closest('dialog[open], .prefs:not([hidden]), input, textarea, select, [contenteditable]')) return;
    const key = event.key.toLowerCase();
    if ((event.ctrlKey || event.metaKey) && (key === "o" || key === "e")) {
      event.preventDefault();
      if (key === "o") open.click(); else exportOpen.click();
    } else if (!event.ctrlKey && !event.metaKey && !event.altKey && store.get().previewReady) {
      if (key === "c") { event.preventDefault(); store.set({ viewMode: store.get().viewMode === "split" ? "effect" : "split" }); }
      if (key === "f") { event.preventDefault(); fit.click(); }
    }
  });
}
