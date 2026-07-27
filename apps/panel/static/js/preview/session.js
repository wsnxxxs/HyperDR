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

export function createUploader(store, { onProgress, onReady, onError }) {
  let inFlight = false;

  return async function upload(fileList) {
    const file = Array.from(fileList || [])[0];
    if (!file || inFlight) return;
    inFlight = true;
    store.set({ uploading: true, file: null, resultUrl: "" });
    onProgress("正在建立上传任务");

    try {
      const sessionId = store.value("sessionId") || (await api.newSession()).sessionId;
      await api.upload(sessionId, file, (fraction) => {
        onProgress(`上传中 · ${Math.round(fraction * 100)}%`);
      });
      store.set({ sessionId, file: { name: file.name, size: file.size } });
      onProgress("");
      await onReady();
    } catch (error) {
      // The session may still be usable -- the failure could be this one file --
      // but nothing is loaded, so the viewer must not keep showing the old image.
      store.set({ file: null });
      onProgress(error.message || "上传失败");
      onError(error.message || "上传失败。");
    } finally {
      inFlight = false;
      store.set({ uploading: false });
    }
  };
}
