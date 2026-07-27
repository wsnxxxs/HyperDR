/* Every call to the panel's HTTP API, in one module.
 *
 * The endpoint list is the contract in docs/panel-api-contract.md, which is
 * frozen for the duration of the rewrite: this file is allowed to change how
 * the front-end talks, never what the server answers. If a screen here needs a
 * shape the server does not send, the contract gets amended first, on `main`,
 * with the old panel still passing -- otherwise the rewrite quietly turns into
 * a rewrite of the backend too, and neither half can be released alone.
 */

export class ApiError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/** Every failure the panel can show reaches the UI as one of these. */
const OFFLINE = () => new ApiError("无法连接本地服务。", 0);

const JSON_HEADERS = { "Content-Type": "application/json" };

async function unwrap(response, fallback) {
  let body = null;
  try { body = await response.json(); } catch { /* not JSON: keep fallback */ }
  // A 200 carrying `{error: ...}` is still a failure, and an `ok` response with
  // no body is still a success. Both halves are checked on purpose.
  if (!response.ok || body?.error) {
    throw new ApiError(body?.error || fallback, response.status);
  }
  return body ?? {};
}

async function get(path, params, fallback) {
  const query = params ? "?" + new URLSearchParams(params) : "";
  let response;
  try { response = await fetch(path + query); } catch { throw OFFLINE(); }
  return unwrap(response, fallback);
}

async function post(path, body, fallback) {
  let response;
  try {
    response = await fetch(path, {
      method: "POST", headers: JSON_HEADERS, body: JSON.stringify(body ?? {}),
    });
  } catch { throw OFFLINE(); }
  return unwrap(response, fallback);
}

export const api = {
  /* -- session ------------------------------------------------------- */

  /** @returns {Promise<{sessionId: string}>} */
  newSession: () => post("/api/session", {}, "无法创建上传任务。"),

  /* -- capabilities -------------------------------------------------- */

  /** Feature flags and limits. Read once at boot; nothing here changes while
   *  the process lives. */
  state: () => get("/api/state", null, "无法读取服务状态。"),

  /* -- settings ------------------------------------------------------ */

  /** The exact command line a run would use, rendered by the same builder the
   *  runner uses -- which is the only reason the displayed command is true. */
  command: (options) => post("/api/command", { options }, "无法生成命令行。"),

  /** Tone curve samples for the current look. */
  curve: (options, samples = 257) =>
    post("/api/curve", { options, samples }, "无法获取色调曲线。"),

  /* -- run ----------------------------------------------------------- */

  run: (sessionId, options) =>
    post("/api/run", { sessionId, options }, "无法启动转换。"),

  cancel: (jobId) => post("/api/cancel", { jobId }, "无法取消任务。"),

  /** Incremental: pass the offset the last call returned, not 0. */
  log: (jobId, offset = 0) =>
    get("/api/log", { id: jobId, offset }, "无法读取任务日志。"),

  /* -- output -------------------------------------------------------- */

  /** Opens the native folder dialog on the machine running the service.
   *  Resolves `{cancelled: true}` when the user dismisses it. */
  selectOutput: () => post("/api/select-output", {}, "无法选择导出文件夹。"),

  export: (sessionId, selectionId) =>
    post("/api/export", { sessionId, selectionId }, "无法导出结果。"),

  /** The converted image. `download` matters on a phone, where the native
   *  picker is not reachable and saving is the browser's job. */
  resultUrl: (sessionId, { download = false } = {}) =>
    "/api/result?" + new URLSearchParams({
      id: sessionId, download: download ? "1" : "0",
    }),

  /* -- preview ------------------------------------------------------- */

  /** The small image the live preview is built from.
   *
   *  `highlightRecovery` is part of the request because it changes the RAW
   *  decode: the same file at two modes is two different previews. The decoded
   *  size comes back in headers and is returned with the blob -- the old panel
   *  dropped it and re-measured off the bitmap, which cost a decode per frame.
   *
   *  @returns {Promise<{blob: Blob, width: number, height: number}>}
   */
  async preview(sessionId, { highlightRecovery, maxEdge } = {}) {
    const query = new URLSearchParams({ id: sessionId });
    if (highlightRecovery) query.set("hr", highlightRecovery);
    if (maxEdge) query.set("edge", String(maxEdge));

    let response;
    try { response = await fetch("/api/preview?" + query); } catch { throw OFFLINE(); }
    if (!response.ok) {
      let message = "无法载入预览。";
      try { const body = await response.json(); if (body.error) message = body.error; } catch {}
      throw new ApiError(message, response.status);
    }
    return {
      blob: await response.blob(),
      width: Number(response.headers.get("X-Preview-Width")) || 0,
      height: Number(response.headers.get("X-Preview-Height")) || 0,
    };
  },

  /* -- upload -------------------------------------------------------- */

  /** XMLHttpRequest rather than fetch: fetch still cannot report request
   *  progress, and a 300 MB RAW with no progress bar looks like a hung panel.
   *
   *  @param {(fraction: number) => void} [onProgress]
   *  @returns {{promise: Promise<object>, abort: () => void}}
   */
  upload(sessionId, file, onProgress) {
    const request = new XMLHttpRequest();
    const promise = new Promise((resolve, reject) => {
      request.open("POST", "/api/upload?" + new URLSearchParams({
        id: sessionId, name: file.name,
      }));
      request.setRequestHeader("Content-Type", "application/octet-stream");
      request.upload.onprogress = (event) => {
        if (event.lengthComputable) onProgress?.(event.loaded / event.total);
      };
      request.onload = () => {
        let body = {};
        try { body = JSON.parse(request.responseText || "{}"); } catch {}
        if (request.status >= 200 && request.status < 300) resolve(body);
        else reject(new ApiError(body.error || "上传失败。", request.status));
      };
      request.onerror = () => reject(new ApiError("上传连接中断。", 0));
      request.onabort = () => reject(new ApiError("上传已取消。", 0));
      request.send(file);
    });
    // Returned rather than hidden: the old panel had no way to stop a 300 MB
    // upload once the user had picked the wrong file.
    return { promise, abort: () => request.abort() };
  },
};
