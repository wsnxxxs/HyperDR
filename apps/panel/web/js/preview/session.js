/* Uploading one photograph into a server-side session.
 *
 * The panel converts a single image at a time, so picking another replaces the
 * current one rather than adding to a batch -- on the server too, where the
 * previous input is removed only once the new one has arrived intact. A session
 * is reused across replacements; a new one is created only on the first upload,
 * which keeps the converter's decode bookkeeping valid for the session.
 *
 * The browser never sends a filesystem path. It receives an opaque session id
 * and the server owns every directory beneath it.
 */

import { api } from "../core/api.js";
import { store } from "../core/store.js";

export function createUploader({ onProgress, onReady, onError }) {
  let inFlight = false;
  let currentRequest = null;
  let aborted = false;

  async function start(fileList) {
    const file = Array.from(fileList || [])[0];
    const previous = store.get();
    if (!file || inFlight || previous.uploading || previous.jobId) return;
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
      onError(aborted ? "已取消上传。" : error.message || "上传失败。", {
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
    /* Wired to the cancel button: the old panel had no way to stop a 300 MB
     * upload once the user had picked the wrong file. */
    abort() {
      if (!currentRequest) return;
      aborted = true;
      currentRequest.abort();
    },
  };
}
