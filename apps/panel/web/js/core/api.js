/* Every call to the panel's HTTP API, in one module. Keep this module and the
 * server implementation in apps/panel/hyperdr_panel/ in sync when the API
 * changes.
 */

import { decodePreview } from "../preview/packet.js";

import { t } from "../i18n/index.js";
let previousPreview = null;

export class ApiError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/** Every failure the panel can show reaches the UI as one of these. */
const OFFLINE = () => new ApiError(t("err.offline"), 0);

const JSON_HEADERS = { "Content-Type": "application/json" };

/** The server sends a stable `code` beside its own prose. A code this build
 *  knows is rendered in the reader's language; anything else falls through to
 *  the server's own message, so the long tail keeps working untranslated. */
function serverMessage(body, fallback) {
  if (body?.code) {
    const key = `err.server.${body.code}`;
    const translated = t(key);
    if (translated !== key) return translated;
  }
  return body?.error || fallback;
}

async function unwrap(response, fallback) {
  let body = null;
  try { body = await response.json(); } catch { /* not JSON: keep fallback */ }
  // A 200 carrying `{error: ...}` is still a failure, and an `ok` response with
  // no body is still a success. Both halves are checked on purpose.
  if (!response.ok || body?.error) {
    throw new ApiError(serverMessage(body, fallback), response.status);
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
  newSession: () => post("/api/session", {}, t("err.session")),

  workspace: (sessionId) => get("/api/workspace", { id: sessionId }, t("err.session")),

  /* -- capabilities -------------------------------------------------- */

  /** Feature flags and limits. Read once at boot; nothing here changes while
   *  the process lives. */
  state: () => get("/api/state", null, t("err.state")),

  rawProfiles: (sessionId) => get("/api/raw-profiles", { id: sessionId }, "DCP"),
  async uploadRawProfile(sessionId, file) {
    const response = await fetch("/api/raw-profile-upload?" + new URLSearchParams({ id: sessionId, name: file.name }),
      { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: file });
    return unwrap(response, "DCP");
  },

  async uploadLut(sessionId, file) {
    let response;
    try {
      response = await fetch("/api/lut-upload?" + new URLSearchParams({ id: sessionId, name: file.name, library: "1" }),
        { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: file });
    } catch { throw OFFLINE(); }
    return unwrap(response, t("lut.failed"));
  },

  lutLibrary: () => get("/api/lut-library", null, t("lut.libraryFailed")),
  applyLibraryLut: (sessionId, lutId) => post("/api/lut-library", { action: "apply", sessionId, lutId }, t("lut.failed")),
  updateLibraryLut: (lutId, spaces) => post("/api/lut-library", { action: "update", lutId, ...spaces }, t("lut.libraryFailed")),
  removeLibraryLut: (lutId) => post("/api/lut-library", { action: "remove", lutId }, t("lut.libraryFailed")),

  /* -- settings ------------------------------------------------------ */

  /** The exact command line a run would use, rendered by the same builder the
   *  runner uses -- which is the only reason the displayed command is true. */
  command: (options) => post("/api/command", { options }, t("err.command")),

  /* -- run ----------------------------------------------------------- */

  run: (sessionId, options) =>
    post("/api/run", { sessionId, options }, t("err.run")),

  cancel: (jobId) => post("/api/cancel", { jobId }, t("err.cancel")),

  /** Incremental: pass the offset the last call returned, not 0. */
  log: (jobId, offset = 0) =>
    get("/api/log", { id: jobId, offset }, t("err.log")),

  /* -- output -------------------------------------------------------- */

  /** The converted image. `download` matters on a phone, where the native
   *  picker is not reachable and saving is the browser's job. */
  resultUrl: (sessionId, { download = false, exportId = "" } = {}) =>
    "/api/result?" + new URLSearchParams({
      id: sessionId, download: download ? "1" : "0", export: exportId,
    }),

  async resultBlob(sessionId, exportId) {
    let response;
    try { response = await fetch(api.resultUrl(sessionId, { exportId })); }
    catch { throw OFFLINE(); }
    if (!response.ok) {
      let body = null;
      try { body = await response.json(); } catch {}
      throw new ApiError(serverMessage(body, t("err.result")), response.status);
    }
    return response.blob();
  },

  setExportFolder: (path) => post("/api/export-folder", { path }, t("save.folderFailed")),
  /** `path` writes this one result somewhere other than the remembered folder,
   *  and does not become the remembered folder. Desktop-only, like the rest. */
  saveTo: (sessionId, exportId, path = "") =>
    post("/api/save-to", { sessionId, exportId, path }, t("save.failed")),
  openExportFolder: (openToken = "") =>
    post("/api/open-export-folder", { openToken }, t("save.folderFailed")),

  /* -- preview ------------------------------------------------------- */

  /** Native float32 linear-Display-P3 SDR base and reconstructed HDR planes.
   *
   *  `highlightRecovery` is part of the request because it changes the RAW
   *  decode: the same file at two modes is two different previews. The decoded
   *  size comes back in headers and is returned with the blob -- the old panel
   *  dropped it and re-measured off the bitmap, which cost a decode per frame.
   *
   *  @returns {Promise<{width: number, height: number, metadata: object,
   *                    base: Float32Array, hdr: Float32Array}>}
   */
  async preview(sessionId, { options = {}, highlightRecovery, maxEdge } = {}) {
    const query = new URLSearchParams({ id: sessionId });
    const previous = previousPreview?.sessionId === sessionId ? previousPreview.frame : null;
    if (previous?.metadata.baseId) query.set("base", previous.metadata.baseId);
    query.set("options", JSON.stringify(options));
    if (highlightRecovery) query.set("hr", highlightRecovery);
    if (maxEdge) query.set("edge", String(maxEdge));

    let response;
    try { response = await fetch("/api/preview?" + query); } catch { throw OFFLINE(); }
    if (!response.ok) {
      let message = t("err.preview");
      try { const body = await response.json(); if (body.error) message = body.error; } catch {}
      throw new ApiError(message, response.status);
    }
    const buffer = await response.arrayBuffer();
    const frame = decodePreview(buffer, previous);
    previousPreview = { sessionId, frame };
    return frame;
  },

  /** A 1:1 region from the full decoder, independent of the fit preview cache. */
  async detailPreview(sessionId, { options = {}, highlightRecovery, x = 0, y = 0,
    width, height, center = false } = {}) {
    const query = new URLSearchParams({ id: sessionId, options: JSON.stringify(options),
      x: String(x), y: String(y), w: String(width), h: String(height),
      center: center ? "1" : "0" });
    if (highlightRecovery) query.set("hr", highlightRecovery);
    let response;
    try { response = await fetch("/api/detail-preview?" + query); }
    catch { throw OFFLINE(); }
    if (!response.ok) {
      let message = t("err.preview");
      try { const body = await response.json(); if (body.error) message = body.error; } catch {}
      throw new ApiError(message, response.status);
    }
    return decodePreview(await response.arrayBuffer());
  },

  /** Run the selected model and return its raw little-endian float32 gain grid.
   *
   *  The identity of what actually ran comes back beside the geometry. It matters
   *  because a model that needs capture settings can answer with another model's
   *  prediction, and a caller that assumed its own request had been honoured
   *  would label that result with the wrong model's name. */
  async modelPreview(sessionId, highlightRecovery, modelId, { colorGamut, clampSrgb, rawProfile, rawLook, lensCorrection } = {}) {
    let response;
    try {
      response = await fetch("/api/model-preview", {
        method: "POST",
        headers: JSON_HEADERS,
        body: JSON.stringify({ sessionId, highlightRecovery, modelId, colorGamut, clampSrgb, rawProfile, rawLook, lensCorrection }),
      });
    } catch { throw OFFLINE(); }
    if (!response.ok) {
      let message = t("err.modelPreview");
      try { const body = await response.json(); if (body.error) message = body.error; } catch {}
      throw new ApiError(message, response.status);
    }
    const width = Number(response.headers.get("X-Gain-Width"));
    const height = Number(response.headers.get("X-Gain-Height"));
    const maxStops = Number(response.headers.get("X-Gain-Max-Stops"));
    const values = new Float32Array(await response.arrayBuffer());
    if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0
        || values.length !== width * height || !Number.isFinite(maxStops)) {
      throw new ApiError(t("err.modelGain"), 500);
    }
    return {
      values, width, height, maxStops,
      identity: {
        requestedModelId: response.headers.get("X-Model-Requested") || modelId || "",
        effectiveModelId: response.headers.get("X-Model-Effective") || modelId || "",
        modelVersion: response.headers.get("X-Model-Version") || "",
        inferenceMode: response.headers.get("X-Inference-Mode") || "",
        fallbackReason: response.headers.get("X-Model-Fallback") || "",
      },
    };
  },

  /* -- upload -------------------------------------------------------- */

  /** Desktop-only native path handoff. The server validates the path and keeps
   *  it as the session source instead of receiving a byte stream. */
  openNativePath: (sessionId, path) =>
    post("/api/native-input", { sessionId, path }, t("err.nativeInput")),

  /** XMLHttpRequest rather than fetch: fetch still cannot report request
   *  progress, and a 300 MB RAW with no progress bar looks like a hung panel.
   *
   *  @param {(fraction: number) => void} [onProgress]
   *  @returns {{promise: Promise<object>, abort: () => void}}
   */
  upload(sessionId, file, onProgress, {
    XMLHttpRequest: Request = globalThis.XMLHttpRequest, readBody = true,
    error = (message, status) => new ApiError(message, status),
    failed = t("err.uploadFailed"), interrupted = t("err.uploadAborted"), cancelled = t("err.uploadCancelled"),
  } = {}) {
    const request = new Request();
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
        if (readBody || request.status < 200 || request.status >= 300) {
          try { body = JSON.parse(request.responseText || "{}"); } catch {}
        }
        if (request.status >= 200 && request.status < 300) resolve(readBody ? body : undefined);
        else reject(error(body.error || failed, request.status));
      };
      request.onerror = () => reject(error(interrupted, 0));
      request.onabort = () => reject(error(cancelled, 0));
      request.send(file);
    });
    // Returned rather than hidden: the old panel had no way to stop a 300 MB
    // upload once the user had picked the wrong file.
    return { promise, abort: () => request.abort() };
  },
};

/** Mobile transport keeps its original JSON/error contract. Dependencies are
 * explicit so recovery can run without a browser or real deadlines. */
export function createPhoneApi({ fetch, setTimeout, clearTimeout, XMLHttpRequest }) {
  async function read(path, options, consume, { timeout = 0, signal, timeoutError } = {}) {
    const control = timeout || signal ? new AbortController() : null;
    const cancel = () => control.abort();
    if (signal?.aborted) cancel();
    else signal?.addEventListener("abort", cancel, { once: true });
    const timer = timeout && setTimeout(cancel, timeout);
    try {
      const response = await fetch(path, { ...options, ...(control ? { signal: control.signal } : {}) });
      return await consume(response);
    } catch (error) {
      if (error.name === "AbortError" && !signal?.aborted) {
        throw Object.assign(new Error(timeoutError || t("phone.mobile.requestTimeout")), { status: 0, timeout: true });
      }
      throw error;
    } finally {
      if (timer) clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
    }
  }
  function request(path, body, options) {
    return read(path, body === undefined ? {} : {
      method: "POST", headers: JSON_HEADERS, body: JSON.stringify(body),
    }, async (response) => {
      const data = await response.json();
      if (!response.ok) throw Object.assign(new Error(data.error || t("phone.mobile.requestFailed")), { status: response.status });
      return data;
    }, options);
  }
  function setupState() {
    return read("/setup/state", { cache: "no-store" }, async (response) => {
      if (response.status === 410) throw new ApiError(t("phone.mobile.setup.expired"), 410);
      if (!response.ok) throw new Error(response.status === 401 || response.status === 403
        ? t("phone.mobile.setup.invalid")
        : t("phone.mobile.setup.readFailed"));
      return response.json();
    }, { timeout: 8000, timeoutError: t("phone.mobile.setup.readTimeout") });
  }
  return {
    request, setupState,
    frame: (signal) => fetch("/api/phone/frame", { signal }),
    original: (signal) => fetch("/api/phone/original", { signal }),
    upload: (sessionId, file, onProgress) => api.upload(sessionId, file, onProgress, {
      XMLHttpRequest, readBody: false, error: (message) => new Error(message),
      failed: t("phone.mobile.uploadFailed"), interrupted: t("phone.mobile.uploadInterrupted"), cancelled: t("phone.mobile.uploadCancelled"),
    }),
  };
}
