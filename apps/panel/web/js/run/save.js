/* One save path for the editor, export history, and phone workbench.
 *
 * The service owns converted results. This module fetches those bytes once and
 * hands them to the best destination the current device can actually reach.
 */

import { api, ApiError } from "../core/api.js";
import { store } from "../core/store.js";
import { prefs } from "../ui/prefs-schema.js";
import { t } from "../i18n/index.js";

const DIRECTORY_DB = "hyperdr.save-target";
const DIRECTORY_STORE = "handles";

let browserDirectory = null;
let browserPermission = "";

function nativeFolderPickerAvailable() {
  return Boolean(store.get().capabilities?.nativePathOutput
    && typeof window.__TAURI__?.dialog?.open === "function");
}

function savePickerAvailable() {
  return Boolean(window.isSecureContext && typeof window.showSaveFilePicker === "function");
}

function directoryPickerAvailable() {
  return Boolean(window.isSecureContext && typeof window.showDirectoryPicker === "function");
}

export function availableSaveTargets() {
  if (nativeFolderPickerAvailable()) {
    return [["ask", "prefs.saveTarget.ask"], ["fixed", "prefs.saveTarget.fixed"],
      ["download", "prefs.saveTarget.download"]];
  }
  return [
    ...(savePickerAvailable() ? [["ask", "prefs.saveTarget.ask"]] : []),
    ...(directoryPickerAvailable() ? [["fixed", "prefs.saveTarget.fixed"]] : []),
    ["download", "prefs.saveTarget.download"],
  ];
}

function effectiveTarget() {
  const selected = prefs.get().saveTarget;
  return availableSaveTargets().some(([value]) => value === selected)
    ? selected : "download";
}

/** Whether a save would complete without asking anything: the fixed-folder
 *  target with a folder that is set and writable now. That is the one case in
 *  which an export can put its file where it belongs by itself -- choosing
 *  "fixed folder" is choosing not to be asked. A browser folder whose
 *  permission has lapsed needs a click to renew it, so it does not qualify. */
export function canSaveWithoutPrompt() {
  if (effectiveTarget() !== "fixed") return false;
  if (nativeFolderPickerAvailable()) return Boolean(store.get().capabilities?.exportFolderReady);
  return Boolean(browserDirectory && browserPermission === "granted");
}

/** Remember that an export reached the user's own storage, for the header's
 *  "saved" state and the export history. Keyed by export id, which is unique
 *  across photographs. */
function markSaved(exportId, name) {
  if (!exportId) return;
  store.set({ savedExports: { ...(store.get().savedExports || {}), [exportId]: name || true } });
}

/** `downloadKey` is the wording for the browser-download tier, which is the one
 *  tier whose name depends on the surface: the phone says "save to phone". */
export function saveButtonLabel(downloadKey = "out.download") {
  const target = effectiveTarget();
  if (target === "fixed" || (target === "ask" && nativeFolderPickerAvailable())) {
    return t("save.button.folder");
  }
  if (target === "ask" && savePickerAvailable()) return t("save.button.as");
  return t(downloadKey);
}

function openDirectoryDb() {
  if (!window.indexedDB) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const request = window.indexedDB.open(DIRECTORY_DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(DIRECTORY_STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("IndexedDB unavailable"));
  });
}

function directoryRequest(mode, handle) {
  return openDirectoryDb().then((db) => {
    if (!db) return null;
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(DIRECTORY_STORE, mode);
      const request = mode === "readonly"
        ? transaction.objectStore(DIRECTORY_STORE).get("fixed")
        : transaction.objectStore(DIRECTORY_STORE).put(handle, "fixed");
      request.onsuccess = () => resolve(mode === "readonly" ? request.result || null : handle);
      request.onerror = () => reject(request.error || new Error("IndexedDB unavailable"));
      transaction.oncomplete = () => db.close();
      transaction.onerror = () => reject(transaction.error || new Error("IndexedDB unavailable"));
    });
  });
}

const browserDirectoryReady = directoryRequest("readonly").then(async (handle) => {
  browserDirectory = handle;
  if (handle?.queryPermission) {
    try {
      const permission = await handle.queryPermission({ mode: "readwrite" });
      if (!browserPermission) browserPermission = permission;
    } catch {
      if (!browserPermission) browserPermission = "prompt";
    }
  }
  return handle;
}).catch(() => null);

export async function browserDirectoryName() {
  await browserDirectoryReady;
  return browserDirectory?.name || "";
}

function updateServerFolder(label) {
  const capabilities = store.get().capabilities || {};
  store.set({ capabilities: {
    ...capabilities, exportFolderLabel: label || "", exportFolderReady: Boolean(label),
  } });
}

/** The desktop shell's own folder dialog. Returns "" when it was dismissed. */
async function pickNativeFolder() {
  const path = await window.__TAURI__.dialog.open({ directory: true, multiple: false });
  return typeof path === "string" ? path : "";
}

/** Select and remember a save directory, without returning a server path to the
 * preferences UI. The desktop path is kept on the server; browser handles live
 * in this origin's IndexedDB. */
export async function chooseSaveFolder() {
  if (nativeFolderPickerAvailable()) {
    const path = await pickNativeFolder();
    if (!path) return "";
    const result = await api.setExportFolder(path);
    updateServerFolder(result.label);
    return result.label || "";
  }
  if (!directoryPickerAvailable()) throw new Error(t("save.folderPickerUnavailable"));

  // This call stays inside the click handler so the browser's user-activation
  // requirement is satisfied.
  const handle = await window.showDirectoryPicker({ mode: "readwrite" });
  browserDirectory = handle;
  browserPermission = "granted";
  try { await directoryRequest("readwrite", handle); }
  catch (_) { /* The handle remains usable for this page even if IDB is full. */ }
  return handle.name || "";
}

export async function saveExport({ sessionId, exportId, name }) {
  if (!sessionId || !exportId) throw new ApiError(t("save.expired"), 404);
  const target = effectiveTarget();
  const native = nativeFolderPickerAvailable();

  if (native && target !== "download") {
    // "Ask every time" means exactly that: the folder chosen for one save is
    // used once and is not written over the remembered one, which belongs to
    // the "fixed folder" preference alone.
    let once = "";
    if (target === "ask") {
      once = await pickNativeFolder();
      if (!once) return { cancelled: true };
    } else if (!store.get().capabilities?.exportFolderReady) {
      throw new Error(t("save.folderNotSet"));
    }
    const result = await api.saveTo(sessionId, exportId, once);
    // Keep only an opaque handle in the page so this save's button can open its
    // destination without receiving the absolute path.
    return { name: result.name || name, method: "native", canOpenFolder: true,
      openToken: result.openToken };
  }

  if (target === "ask" && savePickerAvailable()) {
    // Open the native picker before the fetch so it is called directly from the
    // user's click, while transient user activation is still available.
    const handle = await window.showSaveFilePicker({ suggestedName: name || "HyperDR-result" });
    const blob = await api.resultBlob(sessionId, exportId);
    const writer = await handle.createWritable();
    await writer.write(blob);
    await writer.close();
    return { name: handle.name || name, method: "filesystem", canOpenFolder: false };
  }

  if (target === "fixed" && directoryPickerAvailable()) {
    if (!browserDirectory) await browserDirectoryReady;
    if (!browserDirectory) throw new Error(t("save.folderNotSet"));
    const permission = browserPermission === "granted"
      ? Promise.resolve("granted")
      : browserDirectory.requestPermission({ mode: "readwrite" });
    browserPermission = await permission;
    if (browserPermission !== "granted") throw new Error(t("save.folderPermission"));

    const blob = await api.resultBlob(sessionId, exportId);
    const filename = await unusedFilename(browserDirectory, name || "HyperDR-result");
    const handle = await browserDirectory.getFileHandle(filename, { create: true });
    const writer = await handle.createWritable();
    await writer.write(blob);
    await writer.close();
    return { name: filename, method: "filesystem", canOpenFolder: false };
  }

  const blob = await api.resultBlob(sessionId, exportId);
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name || "HyperDR-result";
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
  return { name: name || "HyperDR-result", method: "download", canOpenFolder: false };
}

/** The requested name, or the first " (n)" form the folder does not hold.
 *  Bounded: a folder that answers "taken" to everything is a broken folder,
 *  not a reason to keep asking it forever from the click handler. */
async function unusedFilename(directory, requestedName) {
  const dot = requestedName.lastIndexOf(".");
  const stem = dot > 0 ? requestedName.slice(0, dot) : requestedName;
  const extension = dot > 0 ? requestedName.slice(dot) : "";
  for (let index = 1; index <= 999; index++) {
    const candidate = index === 1 ? requestedName : `${stem} (${index})${extension}`;
    try {
      await directory.getFileHandle(candidate);
    } catch (error) {
      if (error?.name === "NotFoundError") return candidate;
      throw error;
    }
  }
  throw new Error(t("save.folderFull"));
}

/** Attach the shared save state machine to a button/status pair.
 *
 *  `openFolderButton` is only useful where a folder can be opened at all, and
 *  `downloadKey` lets a surface name the browser-download tier in its own
 *  words. @returns {() => void} a re-render, for a locale or capability change. */
export function bindSaveAction(button, status, getExport,
                               { openFolderButton = null, downloadKey } = {}) {
  let busy = false;
  // The line describes one export. When the card moves on to another one --
  // a new export finished, an older version was selected -- the previous
  // file's "saved" must not be read as this one's.
  let statusState = null;

  function shownStatus() {
    const current = getExport();
    if (statusState && statusState.exportId === current?.exportId) return statusState;
    const saved = current?.exportId && store.get().savedExports?.[current.exportId];
    return saved
      ? { key: "save.saved", params: { name: typeof saved === "string" ? saved : current.name } }
      : null;
  }

  function render() {
    const shown = shownStatus();
    button.textContent = busy ? t("save.busy") : saveButtonLabel(downloadKey);
    button.disabled = busy;
    status.hidden = !shown;
    status.dataset.error = String(Boolean(shown?.error));
    status.textContent = shown ? t(shown.key, shown.params) : "";
    if (openFolderButton) {
      openFolderButton.hidden = !shown?.canOpenFolder;
      openFolderButton.disabled = Boolean(shown?.openingFolder);
    }
  }

  button.addEventListener("click", async () => {
    if (busy) return;
    busy = true;
    const target = getExport();
    const exportId = target?.exportId;
    statusState = { key: "save.busy", exportId };
    render();
    try {
      const result = await saveExport(target);
      if (!result.cancelled) markSaved(exportId, result.name);
      statusState = result.cancelled
        ? { key: "save.cancelled", exportId }
        : { key: result.method === "download" ? "save.downloadStarted" : "save.saved",
          params: { name: result.name }, canOpenFolder: result.canOpenFolder,
          openToken: result.openToken, exportId };
    } catch (error) {
      const expired = [401, 404].includes(error?.status);
      statusState = error?.name === "AbortError"
        ? { key: "save.cancelled", exportId }
        : expired
          ? { key: "save.expired", error: true, exportId }
          : { key: "save.failedDetail", params: { detail: error?.message || t("save.failed") },
            error: true, exportId };
    } finally {
      busy = false;
      render();
    }
  });

  openFolderButton?.addEventListener("click", async () => {
    if (openFolderButton.disabled) return;
    const openToken = statusState?.openToken || "";
    const exportId = statusState?.exportId;
    if (statusState) statusState.openingFolder = true;
    render();
    try {
      await api.openExportFolder(openToken);
      statusState = { key: "save.folderOpened", canOpenFolder: true, openToken, exportId };
    } catch (error) {
      statusState = { key: "save.failedDetail", params: { detail: error?.message || t("save.folderFailed") },
        error: true, canOpenFolder: true, openToken, exportId };
    } finally {
      render();
    }
  });

  render();
  return render;
}
