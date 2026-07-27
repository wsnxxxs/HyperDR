/* Every call to the panel's HTTP API, in one module.
 *
 * The old front-end spelled out `fetch(...)`, the JSON headers, and the same
 * "check response.ok, then check body.error, then throw" dance at eleven call
 * sites, each with a slightly different fallback message. One of them forgot
 * the `response.ok` half entirely and reported a 500 as success. Endpoints are
 * declared once here; callers get a promise of the payload or an `ApiError`.
 */

export class ApiError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

const JSON_HEADERS = { "Content-Type": "application/json" };

async function unwrap(response, fallback) {
  let body = null;
  try { body = await response.json(); } catch (_) { /* not JSON */ }
  if (!response.ok || (body && body.error)) {
    throw new ApiError((body && body.error) || fallback, response.status);
  }
  return body ?? {};
}

async function get(path, params, fallback) {
  const query = params ? "?" + new URLSearchParams(params) : "";
  let response;
  try { response = await fetch(path + query); }
  catch (_) { throw new ApiError("无法连接本地服务。", 0); }
  return unwrap(response, fallback);
}

async function post(path, body, fallback) {
  let response;
  try {
    response = await fetch(path, {
      method: "POST", headers: JSON_HEADERS, body: JSON.stringify(body ?? {}),
    });
  } catch (_) { throw new ApiError("无法连接本地服务。", 0); }
  return unwrap(response, fallback);
}

export const api = {
  state: () => get("/api/state", null, "无法读取服务状态。"),

  newSession: () => post("/api/session", {}, "无法创建上传任务。"),

  curve: (options, samples) => post("/api/curve", { options, samples }, "无法获取色调曲线。"),

  run: (sessionId, options, preview = false) =>
    post("/api/run", { sessionId, options, preview }, "无法启动转换。"),

  cancel: (jobId) => post("/api/cancel", { jobId }, "无法取消任务。"),

  log: (jobId, offset) => get("/api/log", { id: jobId, offset }, "无法读取任务日志。"),

  selectOutput: () => post("/api/select-output", {}, "无法选择导出文件夹。"),

  export: (sessionId, selectionId) =>
    post("/api/export", { sessionId, selectionId, kind: "output" }, "无法导出结果。"),

  /** The preview is image bytes, not JSON, so it bypasses `unwrap`.
   *
   *  `highlightRecovery` is part of the request because it is part of the RAW
   *  decode: the same file at two modes is two different previews. */
  async previewBlob(sessionId, highlightRecovery, maxEdge) {
    let response;
    const query = new URLSearchParams({ id: sessionId });
    if (highlightRecovery) query.set("hr", highlightRecovery);
    if (maxEdge) query.set("edge", String(maxEdge));
    try { response = await fetch("/api/preview?" + query); }
    catch (_) { throw new ApiError("无法连接本地服务。", 0); }
    if (!response.ok) {
      let message = "无法载入预览。";
      try { const body = await response.json(); if (body.error) message = body.error; } catch (_) {}
      throw new ApiError(message, response.status);
    }
    return response.blob();
  },

  /* Uploads use XMLHttpRequest because `fetch` still cannot report request
   * progress, and a 300 MB RAW with no progress bar looks like a hung panel. */
  upload(sessionId, file, onProgress) {
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      request.open("POST", "/api/upload?" + new URLSearchParams({ id: sessionId, name: file.name }));
      request.setRequestHeader("Content-Type", "application/octet-stream");
      request.upload.onprogress = (event) => {
        if (event.lengthComputable) onProgress?.(event.loaded / event.total);
      };
      request.onload = () => {
        let body = {};
        try { body = JSON.parse(request.responseText || "{}"); } catch (_) {}
        if (request.status >= 200 && request.status < 300) resolve(body);
        else reject(new ApiError(body.error || "上传失败。", request.status));
      };
      request.onerror = () => reject(new ApiError("上传连接中断。", 0));
      request.onabort = () => reject(new ApiError("上传已取消。", 0));
      request.send(file);
    });
  },
};
