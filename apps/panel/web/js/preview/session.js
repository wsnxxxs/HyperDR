/* Uploading one photograph into a server-side session.
 *
 * The panel converts a single image at a time, so picking another replaces the
 * current one rather than adding to a batch -- on the server too, where the
 * previous input is removed only once the new one has arrived intact. A session
 * is reused across replacements; a new one is created only on the first upload,
 * which keeps the converter's decode bookkeeping valid for the session.
 *
 * Web browsers never send a filesystem path. The Windows Tauri bridge has a
 * separate native-path entry point that is only enabled by the desktop server.
 */

import { t } from "../i18n/index.js";
import { api } from "../core/api.js";
import { store } from "../core/store.js";

/* What the server would reject anyway, refused before the bytes go over the
 * wire. Sending 300 MB and then being told the extension is wrong is the same
 * answer arriving several minutes later, and on a phone it is several minutes
 * of the user's data. The server still validates -- this only saves the trip,
 * and it deliberately checks nothing the server does not also check. */
function preflight(file) {
  const capabilities = store.get().capabilities;
  const extensions = capabilities?.inputExtensions;
  if (Array.isArray(extensions) && extensions.length) {
    const dot = file.name.lastIndexOf(".");
    const suffix = dot > 0 ? file.name.slice(dot).toLowerCase() : "";
    if (!extensions.includes(suffix)) {
      return t("err.unsupported");
    }
  }
  const limit = Number(capabilities?.maxUploadMB);
  if (Number.isFinite(limit) && limit > 0 && file.size > limit * 1024 * 1024) {
    return t("err.tooLarge", { limit });
  }
  if (file.size === 0) return t("err.emptyFile");
  return null;
}

export function createUploader({ onProgress, onReady, onError }) {
  let inFlight = false;
  let currentRequest = null;
  let aborted = false;

  async function start(fileList) {
    const file = Array.from(fileList || [])[0];
    const previous = store.get();
    if (!file || inFlight || previous.uploading || previous.jobId) return;
    const refusal = preflight(file);
    if (refusal) {
      onError(refusal, { preserveCurrent: Boolean(previous.file) });
      return;
    }
    inFlight = true;
    aborted = false;
    // Keep the current image/result until the replacement is accepted.
    store.set({ uploading: true, uploadProgress: 0 });
    onProgress(0);

    try {
      const sessionId = store.get().sessionId || (await api.newSession()).sessionId;
      const request = api.upload(sessionId, file, (fraction) => {
        store.set({ uploadProgress: fraction });
        onProgress(fraction);
      });
      currentRequest = request;
      await request.promise;
      store.set({
        sessionId,
        file: { name: file.name, size: file.size },
        result: null,
      });
      await onReady();
    } catch (error) {
      // The session may still be usable -- the failure could be this one file.
      // Keep any previously published image visible and current in the store.
      // A user-aborted upload is not an error and must not clear the stage.
      onError(aborted ? t("err.uploadCancelledBy") : error.message || t("err.uploadFailed"), {
        preserveCurrent: Boolean(previous.file),
        cancelled: aborted,
      });
    } finally {
      inFlight = false;
      currentRequest = null;
      store.set({ uploading: false });
    }
  }

  async function startNativePath(path) {
    const previous = store.get();
    if (!path || inFlight || previous.uploading || previous.jobId
        || !previous.capabilities?.nativePathInput) return;
    inFlight = true;
    aborted = false;
    store.set({ uploading: true, uploadProgress: 0 });
    onProgress(0);

    try {
      const sessionId = store.get().sessionId || (await api.newSession()).sessionId;
      const selected = await api.openNativePath(sessionId, path);
      const size = Number(selected.bytes);
      store.set({
        sessionId,
        file: {
          name: selected.name || String(path).split(/[\\/]/).pop() || "image",
          size: Number.isFinite(size) ? size : 0,
        },
        result: null,
      });
      onProgress(1);
      await onReady();
    } catch (error) {
      onError(aborted ? t("err.loadCancelled") : error.message || t("err.nativeInput"), {
        preserveCurrent: Boolean(previous.file),
        cancelled: aborted,
      });
    } finally {
      inFlight = false;
      currentRequest = null;
      store.set({ uploading: false });
    }
  }

  return {
    start,
    startNativePath,
    /* Wired to the cancel button: the old panel had no way to stop a 300 MB
     * upload once the user had picked the wrong file. */
    abort() {
      if (!currentRequest) return;
      aborted = true;
      currentRequest.abort();
    },
  };
}
