import { store } from "../core/store.js";
import { role, el, setText, setPressed } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { isSdrEncoding, OPTION_KEYS, outputDescription } from "../settings/schema.js";
import { modelLabel } from "../settings/model-select.js";
import { planeToImageData } from "../preview/cpu.js";
import { currentResult } from "../run/options.js";

/* Zoom is relative to fit-to-window. Buttons and keys move along a 25% grid,
 * so a zoom reached with the wheel snaps back onto it at the next step. */
export const MIN_ZOOM = 1;
export const MAX_ZOOM = 4;
const ZOOM_STEP = 0.25;
export const zoomStep = (zoom, direction) => {
  const grid = direction > 0
    ? (Math.floor(zoom / ZOOM_STEP + 1e-6) + 1) * ZOOM_STEP
    : (Math.ceil(zoom / ZOOM_STEP - 1e-6) - 1) * ZOOM_STEP;
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, grid));
};

/** Where the edit on screen stands, for the header: the key of its label and
 *  the dot's state. "Exported" and "saved" are different facts -- an export
 *  sits in the workspace until it is saved to the user's own storage. */
export function documentStatus(state) {
  if (!state.file) return { state: "empty", key: "workspace.waiting" };
  const result = currentResult(state);
  if (!result) {
    return { state: "edited", key: (state.exports || []).length ? "workspace.dirty" : "workspace.notExported" };
  }
  return state.savedExports?.[result.exportId]
    ? { state: "saved", key: "workspace.saved" }
    : { state: "exported", key: "workspace.exported" };
}

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

  /** The settings the next export will be made from, one row each. */
  function summaryRows(state) {
    const sdr = isSdrEncoding(state.encoding);
    const mode = sdr ? t("workflow.color")
      : state.previewOptimized ? `${t("adjust.ai")} · ${modelLabel(state.modelId, state)}`
        : t("inspector.manual");
    return [
      ["export.mode", mode],
      ["export.format", outputDescription(state.encoding, state.outputGamut)],
      sdr || !state.clampSrgb ? null : ["export.gamut", t("out.clampSrgb")],
      state.encoding === "sdr-tiff" ? null : ["export.quality", String(state.quality)],
      ["adaptive", "pq", "hlg"].includes(state.encoding)
        ? ["export.speed", state.hevcPreset === "medium" ? t("out.hevcFast") : t("out.hevcStandard")]
        : null,
      state.lutId ? ["export.lut", String(state.lutName || "").replace(/\.cube$/i, "")] : null,
    ].filter(Boolean);
  }

  function sync() {
    const state = store.get();
    open.closest(".app").dataset.workspace = state.file ? "editing" : state.uploading || state.restoring ? "loading" : "empty";
    const ready = Boolean(state.file && state.previewReady);
    open.disabled = state.restoring || state.uploading || state.starting || state.optimizing || Boolean(state.jobId);
    exportOpen.disabled = !state.file || state.uploading || state.restoring;
    setText(exportOpen.querySelector("span"), state.jobId || state.starting ? t("editor.exporting") : state.encoding === "sdr-jpeg" ? t("workflow.saveJpeg") : t("editor.export"));
    setText(filename, state.file?.name || t("editor.noPhoto"));
    filename.title = state.file?.name || "";

    const status = documentStatus(state);
    documentState.dataset.state = status.state;
    setText(documentState, t(status.key));
    documentState.disabled = !state.file;
    documentState.title = state.file ? t("workspace.statusOpen") : "";

    // The file's own facts. The preview size changes with the window and is
    // only interesting when diagnosing the preview, so it is the tooltip.
    const frame = stage.getFrame();
    const extension = /\.([a-z0-9]+)$/i.exec(state.file?.name || "")?.[1]?.toUpperCase() || "";
    const size = state.file?.size > 0 ? `${(state.file.size / 1048576).toFixed(1)} MB` : "";
    const source = state.sourceColor;
    const sourceNames = { icc: "input.source.icc", cicp: "input.source.cicp",
      assumed: "input.source.assumed", raw: "input.source.raw", "png-srgb": "input.source.png-srgb",
      "png-chrm-gamma": "input.source.png-chrm-gamma", ultrahdr: "input.source.ultrahdr" };
    const sourceLabel = source?.source && sourceNames[source.source] ? t(sourceNames[source.source]) : "";
    const inputColor = source?.name ? `${source.name}${sourceLabel ? ` (${sourceLabel})` : ""}` : "";
    setText(metadata, state.file ? [extension, size, inputColor].filter(Boolean).join(" · ") : "");
    metadata.title = frame ? t("workspace.previewSize", { width: frame.width, height: frame.height }) : "";

    setText(viewerHint, !ready ? "" : state.viewerZoom > 1 ? t("workspace.panHint") : state.viewMode === "split" ? t("workspace.compareHint") : t("workspace.photoHint"));
    setText(exportFilename, state.file?.name || "");
    summary.replaceChildren(...summaryRows(state).flatMap(([key, value]) => [el("dt", {}, t(key)), el("dd", {}, value)]));
    for (const { value, label, button } of modeButtons) {
      setText(button, t(label)); setPressed(button, state.viewMode === value); button.disabled = !ready;
    }
    fit.disabled = !ready;
    zoomOut.disabled = !ready || state.viewerZoom <= MIN_ZOOM;
    zoomIn.disabled = !ready || state.viewerZoom >= MAX_ZOOM;
    setText(zoomValue, `${Math.round(state.viewerZoom * 100)}%`);
    setPressed(fit, state.viewerZoom === 1);
  }
  function showExport() {
    if (exportOpen.disabled || dialog.open) return;
    paintThumbnail();
    dialog.showModal();
  }
  const zoomBy = (direction) => {
    const state = store.get();
    const next = zoomStep(state.viewerZoom, direction);
    store.set(next === MIN_ZOOM ? { viewerZoom: next, viewerPanX: 0, viewerPanY: 0 } : { viewerZoom: next });
  };
  open.addEventListener("click", stage.openPicker);
  exportOpen.addEventListener("click", showExport);
  documentState.addEventListener("click", showExport);
  close.addEventListener("click", () => dialog.close());
  fit.addEventListener("click", () => store.set({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0 }));
  zoomIn.addEventListener("click", () => zoomBy(1));
  zoomOut.addEventListener("click", () => zoomBy(-1));
  store.watchAny(["file", "previewReady", "uploading", "restoring", "starting", "optimizing", "jobId", "encoding", "previewOptimized", "viewMode", "viewerZoom", "result", "exports", "savedExports", "sourceDomain", ...OPTION_KEYS], sync, { immediate: true });
  stage.onSourceChange(() => { sync(); if (dialog.open) paintThumbnail(); });
  onLocaleChange(sync);
  document.addEventListener("keydown", (event) => {
    if (event.target.closest('dialog[open], input, textarea, select, [contenteditable]')) return;
    const key = event.key.toLowerCase();
    if ((event.ctrlKey || event.metaKey) && (key === "o" || key === "e")) {
      event.preventDefault();
      if (key === "o") open.click(); else exportOpen.click();
    } else if (!event.ctrlKey && !event.metaKey && !event.altKey && store.get().previewReady) {
      if (key === "c") { event.preventDefault(); store.set({ viewMode: store.get().viewMode === "split" ? "effect" : "split" }); }
      if (key === "f") { event.preventDefault(); fit.click(); }
      if (key === "+" || key === "=") { event.preventDefault(); zoomBy(1); }
      if (key === "-" || key === "_") { event.preventDefault(); zoomBy(-1); }
    }
  });
}
