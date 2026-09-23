import { decodePreview } from "/js/preview/packet.js";
import { assessPhoneHdr } from "/js/preview/phone-diagnostics.js";
import { createSdrGpuRenderer } from "/js/preview/sdr-gpu.js";
import { renderSdr } from "/js/preview/cpu.js";
import { bindSaveAction } from "/js/run/save.js";

const $ = (id) => document.getElementById(id);
const setupCheck = new URLSearchParams(location.search).get("check") || "";
let snapshot = null, capabilities = null, online = false, transfer = null;
let frame = null, original = null, photoId = "", displayedVersion = 0;
let renderer = null, canvas = $("photo"), frameRequest = null, rendering = false;
let comparing = false, zoom = 1, panX = 0, panY = 0;
const pointers = new Map();
let gesture = null;

async function request(path, body, { timeout = 0, signal } = {}) {
  const control = timeout || signal ? new AbortController() : null;
  const cancel = () => control.abort();
  if (signal?.aborted) cancel();
  else signal?.addEventListener("abort", cancel, { once: true });
  const timer = timeout && setTimeout(cancel, timeout);
  try {
    const response = await fetch(path, {
      ...(body === undefined ? {} : {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
      }),
      ...(control ? { signal: control.signal } : {}),
    });
    const data = await response.json();
    if (!response.ok) throw Object.assign(new Error(data.error || "请求未完成，请重试。"), { status: response.status });
    return data;
  } catch (error) {
    if (error.name === "AbortError" && !signal?.aborted) throw Object.assign(new Error("请求超时，请重试。"), { status: 0, timeout: true });
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
    signal?.removeEventListener("abort", cancel);
  }
}
function notice(message = "") { $("notice").textContent = message; $("notice").hidden = !message; }
function connectionState(connected) {
  online = connected;
  $("connection").dataset.online = String(connected && Boolean(snapshot?.enabled && snapshot?.desktopConnected));
  $("connection").querySelector("span").textContent = snapshot && !snapshot.enabled ? "连接已关闭" : !connected ? "正在重连" : snapshot?.desktopConnected ? "已连接" : "等待电脑";
  availability();
}
function availability() {
  const ready = online && snapshot?.enabled && snapshot.desktopConnected && capabilities?.ready;
  const busy = transfer || snapshot?.upload || snapshot?.pending || snapshot?.current?.busy;
  $("pick-photos").disabled = !ready || Boolean(busy);
  $("pick-label").textContent = snapshot?.current?.file ? "换一张照片" : "选择照片";
  $("import-hint").textContent = snapshot && !snapshot.enabled ? "请在电脑上重新开启连接，并扫描新的二维码。"
    : !online ? "连接恢复后，照片和调整会自动同步。"
    : !snapshot?.desktopConnected ? "请在电脑上打开手机连接工作台。"
    : !capabilities?.ready ? "电脑上的照片处理服务尚未就绪。"
    : snapshot?.current?.busy ? "电脑正在处理照片，请稍候。"
    : "也可以在电脑上打开照片，手机会同步显示。";
}
function syncExports(entries) {
  const key = entries.map((e) => `${e.sessionId}/${e.id}`).join("|");
  if ($("export-list").dataset.key === key) return;
  $("export-list").dataset.key = key;
  $("exports").hidden = !entries.length;
  $("export-count").textContent = `${entries.length} 个结果`;
  $("export-list").replaceChildren(...entries.map((entry) => {
    const card = document.createElement("article"); card.className = "export-card";
    const mark = document.createElement("span"); mark.className = "export-mark"; mark.textContent = "↙";
    const info = document.createElement("div");
    const title = document.createElement("h3"); title.textContent = entry.name;
    const meta = document.createElement("p"); meta.textContent = `${(entry.bytes / 1048576).toFixed(1)} MB · ${new Date(entry.createdAt * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
    const saveState = document.createElement("p");
    saveState.className = "save-state phone-save-state";
    saveState.setAttribute("role", "status");
    saveState.setAttribute("aria-live", "polite");
    saveState.hidden = true;
    const save = document.createElement("button");
    save.type = "button";
    save.className = "phone-save-button";
    bindSaveAction(save, saveState, () => ({
      sessionId: entry.sessionId, exportId: entry.id, name: entry.name,
    }), { downloadKey: "save.button.phone" });
    info.append(title, meta, saveState); card.append(mark, info, save); return card;
  }));
}
function applySnapshot(next) {
  snapshot = next;
  $("computer").textContent = next.computer;
  const current = next.current || {};
  const hasPhoto = Boolean(current.file);
  $("welcome").hidden = hasPhoto;
  $("photo-workspace").hidden = !hasPhoto;
  $("workflow").hidden = hasPhoto;
  $("filename").textContent = current.file?.name || "";
  const id = `${current.sessionId || ""}/${current.options?.highlightRecovery || ""}`;
  if (id !== photoId) {
    photoId = id; frame = null; original = null; displayedVersion = 0;
    comparing = false; draw();
    canvas.style.visibility = "hidden";
    $("compare").disabled = true;
    resetView();
  }
  $("viewer-state").textContent = next.pending ? "正在交给电脑编辑器"
    : current.status === "exporting" ? "正在导出成品"
    : current.status === "error" ? "预览未完成，请在电脑查看原因或换一张照片"
    : next.frameReady && displayedVersion === next.frameVersion ? "已同步最新效果"
    : "正在更新效果";
  if (next.upload && !transfer) showTransfer(next.upload.name, next.upload.progress);
  else if (!transfer) $("transfer").hidden = true;
  syncExports(next.completed || []);
  connectionState(true);
  if (!next.frameReady) frameRequest?.abort();
  else if (displayedVersion !== next.frameVersion) loadFrame();
}
function newCanvas() {
  const next = document.createElement("canvas"); next.id = "photo";
  next.setAttribute("aria-label", "照片效果预览");
  canvas.replaceWith(next); canvas = next;
}
let diagnosticRun = null, lastDiagnostic = null, rendererRefreshPending = false;
const diagnosticMessages = {
  insecure: ["需要安全连接才能检测 HDR", "请重新扫描电脑上的设置二维码，安装并信任证书后进入 HTTPS 工作台。"],
  webgpu: ["此浏览器尚未提供 WebGPU", "可以继续上传和保存照片；请尝试更新系统与浏览器后重新检测。"],
  display: ["当前未检测到 HDR 显示能力", "屏幕或浏览器目前报告 SDR。可以继续使用 SDR 预览，保存的成品不受影响。"],
  renderer: ["HDR 渲染器未通过检测", "当前使用 SDR 预览。可重新检测，并在详细信息中查看原因。"],
  ready: ["HDR 预览能力检测通过", "这是设备能力检测；加载照片后，预览标记会显示实际渲染模式。"],
};
function publishDiagnostics(result) {
  lastDiagnostic = result;
  const [title, description] = diagnosticMessages[result.reason];
  $("diagnostic-title").textContent = title;
  $("diagnostic-description").textContent = description;
  $("diagnostics").dataset.hdr = String(result.hdr);
  $("diagnostic-detail").textContent = `安全上下文：${result.secureContext ? "是" : "否"} · WebGPU：${result.webgpu ? "有" : "无"} · HDR 显示：${result.displayHdr ? "是" : "否"}\n${result.detail || "未运行 HDR 渲染器：前置条件未满足。"}`;
  request("/api/phone/diagnostics", { ...result, setupCheck }).then(() => {
    $("diagnostic-report").textContent = "检测结果已同步到电脑。";
  }).catch((error) => { $("diagnostic-report").textContent = `检测已完成，暂未同步到电脑：${error.message}`; });
}
setInterval(() => {
  if (!document.hidden && online && lastDiagnostic) {
    request("/api/phone/diagnostics", { ...lastDiagnostic, setupCheck }).catch(() => {});
  }
}, 20000);
function probeDiagnostics() {
  if (diagnosticRun) return diagnosticRun;
  $("retry-diagnostics").disabled = true;
  diagnosticRun = (async () => {
    try {
      const probe = document.createElement("canvas"); probe.width = 2; probe.height = 2;
      const { result, renderer: testRenderer } = await assessPhoneHdr(probe);
      testRenderer?.destroy(); publishDiagnostics(result);
    } catch (error) {
      // A capability check that fails must still leave the page usable.
      publishDiagnostics({ secureContext: Boolean(window.isSecureContext), webgpu: Boolean(navigator.gpu),
        displayHdr: false, hdr: false, reason: "renderer", detail: String(error.message || error) });
    }
  })().finally(() => { diagnosticRun = null; $("retry-diagnostics").disabled = false; });
  return diagnosticRun;
}
async function refreshDiagnostics() {
  await probeDiagnostics();
  if (!renderer) return;
  if (rendering) { rendererRefreshPending = true; return; }
  rendererRefreshPending = false;
  rendererLost();
}
$("retry-diagnostics").addEventListener("click", refreshDiagnostics);
try { matchMedia("(dynamic-range: high)").addEventListener("change", refreshDiagnostics); } catch {}
async function initRenderer() {
  if (renderer) return;
  if (diagnosticRun) await diagnosticRun;
  let candidate = null;
  try {
    const assessment = await assessPhoneHdr(canvas, () => { if (candidate && renderer === candidate) rendererLost(); });
    candidate = assessment.renderer;
    publishDiagnostics(assessment.result);
  } catch (error) {
    publishDiagnostics({ secureContext: Boolean(window.isSecureContext), webgpu: Boolean(navigator.gpu),
      displayHdr: false, hdr: false, reason: "renderer", detail: String(error.message || error) });
  }
  renderer = candidate;
  if (!renderer) newCanvas();
  if (!renderer) {
    try { renderer = createSdrGpuRenderer(canvas, () => rendererLost()); }
    catch { newCanvas(); renderer = { kind: "cpu", upload() {}, destroy() {}, draw(_unused, params) { renderSdr(canvas, { frame, original: params.original }); } }; }
  }
  const hdr = renderer.kind === "hdr";
  $("render-badge").textContent = hdr ? "真 HDR" : "SDR 预览";
  $("render-badge").dataset.hdr = String(hdr);
  $("preview-note").textContent = hdr ? "电脑调整后自动更新 · 双指缩放查看细节"
    : !window.isSecureContext ? "当前为 SDR 预览。真 HDR 需要可信 HTTPS；保存的成品不受影响。"
    : "当前屏幕或浏览器使用 SDR 预览；保存的 HDR 成品不受影响。";
}
function rendererLost() {
  const previous = renderer; renderer = null;
  previous?.destroy(); newCanvas(); displayedVersion = 0;
  if (snapshot?.frameReady) loadFrame();
}
async function loadFrame() {
  if (rendering || !snapshot?.frameReady || !online) return;
  const id = photoId, version = snapshot.frameVersion;
  rendering = true; frameRequest = new AbortController();
  let retry = false;
  try {
    const response = await fetch("/api/phone/frame", { signal: frameRequest.signal });
    if (!response.ok) { if (response.status === 409) return; throw new Error("预览获取失败，正在重试。"); }
    const data = await response.arrayBuffer();
    if (id !== photoId || !snapshot.frameReady || version !== snapshot.frameVersion || Number(response.headers.get("X-Frame-Version")) !== version) { retry = true; return; }
    const next = decodePreview(data);
    if (!original) {
      const source = await fetch("/api/phone/original", { signal: frameRequest.signal });
      if (!source.ok) throw new Error("原图正在准备，请稍候。");
      const originalData = decodePreview(await source.arrayBuffer());
      if (id !== photoId) { retry = true; return; }
      original = originalData;
      $("original-photo").width = original.width; $("original-photo").height = original.height;
      renderSdr($("original-photo"), { frame: original, original: true });
    }
    await initRenderer();
    if (id !== photoId || version !== snapshot.frameVersion) { retry = true; return; }
    frame = next;
    canvas.width = frame.width; canvas.height = frame.height;
    renderer.upload(frame); draw(); canvas.style.visibility = "visible";
    displayedVersion = version;
    $("compare").disabled = false;
    $("viewer-state").textContent = snapshot.current.status === "exporting" ? "正在导出成品" : "已同步最新效果";
    transform();
  } catch (error) {
    if (error.name !== "AbortError") $("viewer-state").textContent = error.message;
  } finally {
    rendering = false; frameRequest = null;
    if (rendererRefreshPending) { rendererRefreshPending = false; rendererLost(); }
    else if (retry && snapshot?.frameReady) loadFrame();
  }
}
function draw() {
  canvas.hidden = comparing;
  $("original-photo").hidden = !comparing;
  if (frame && !comparing) renderer?.draw(null, { original: false });
}
function transform() {
  const box = $("canvas-wrap").getBoundingClientRect();
  panX = Math.max(-box.width * (zoom - 1) / 2, Math.min(box.width * (zoom - 1) / 2, panX));
  panY = Math.max(-box.height * (zoom - 1) / 2, Math.min(box.height * (zoom - 1) / 2, panY));
  canvas.style.transform = `translate(${panX}px, ${panY}px) scale(${zoom})`;
  $("original-photo").style.transform = canvas.style.transform;
}
function resetView() { zoom = 1; panX = panY = 0; transform(); }
$("compare").addEventListener("pointerdown", (event) => {
  event.preventDefault(); $("compare").setPointerCapture(event.pointerId); comparing = true; draw();
});
const endCompare = () => { comparing = false; draw(); };
for (const event of ["pointerup", "pointercancel", "lostpointercapture", "blur"]) $("compare").addEventListener(event, endCompare);
$("compare").addEventListener("contextmenu", (event) => event.preventDefault());
$("compare").addEventListener("keydown", (event) => { if ([" ", "Enter"].includes(event.key)) { event.preventDefault(); comparing = true; draw(); } });
$("compare").addEventListener("keyup", endCompare);
$("fullscreen").addEventListener("click", () => {
  const expanded = document.body.classList.toggle("fullscreen");
  $("fullscreen").setAttribute("aria-label", expanded ? "退出全屏" : "全屏预览");
  $("fullscreen").setAttribute("aria-pressed", String(expanded)); resetView();
});
document.addEventListener("keydown", (event) => { if (event.key === "Escape") { document.body.classList.remove("fullscreen"); resetView(); } });
const surface = $("canvas-wrap");
surface.addEventListener("pointerdown", (event) => {
  if (!frame) return;
  surface.setPointerCapture(event.pointerId); pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  gesture = { points: [...pointers.values()], zoom, panX, panY };
});
surface.addEventListener("pointermove", (event) => {
  if (!pointers.has(event.pointerId) || !gesture) return;
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  const points = [...pointers.values()];
  if (points.length === 2 && gesture.points.length === 2) {
    const distance = (p) => Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
    zoom = Math.max(1, Math.min(4, gesture.zoom * distance(points) / Math.max(1, distance(gesture.points))));
  } else if (points.length === 1 && gesture.points.length === 1) {
    panX = gesture.panX + points[0].x - gesture.points[0].x;
    panY = gesture.panY + points[0].y - gesture.points[0].y;
  }
  transform();
});
for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) surface.addEventListener(event, (e) => {
  pointers.delete(e.pointerId); gesture = { points: [...pointers.values()], zoom, panX, panY };
});
surface.addEventListener("dblclick", () => { zoom = zoom === 1 ? 2 : 1; panX = panY = 0; transform(); });
window.addEventListener("resize", transform);

function showTransfer(name, progress, cancellable = true) {
  $("transfer").hidden = false; $("transfer-name").textContent = name;
  $("transfer-title").textContent = progress >= 1 ? "正在准备照片" : "正在传到电脑";
  $("upload-progress").value = progress; $("upload-percent").textContent = `${Math.round(progress * 100)}%`;
  $("cancel-upload").hidden = !cancellable;
}
async function upload(file) {
  if (!file || transfer) return;
  const extension = "." + file.name.split(".").pop().toLowerCase();
  if (!capabilities.inputExtensions.includes(extension)) { notice("暂不支持这个格式，请选择照片或 RAW 文件。"); return; }
  if (!file.size || file.size > capabilities.maxUploadMB * 1048576) { notice(`请选择非空且不超过 ${capabilities.maxUploadMB} MB 的照片。`); return; }
  const task = { cancelled: false, sid: null, xhr: null, progress: Promise.resolve() };
  transfer = task; notice(); showTransfer(file.name, 0); availability();
  try {
    const result = await request("/api/phone/import", { name: file.name }); task.sid = result.sessionId;
    if (task.cancelled) return;
    await new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest(); task.xhr = xhr;
      xhr.open("POST", "/api/upload?" + new URLSearchParams({ id: task.sid, name: file.name }));
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      let lastProgress = 0;
      xhr.upload.onprogress = (event) => {
        if (!event.lengthComputable) return;
        const progress = event.loaded / event.total; showTransfer(file.name, progress);
        if (Date.now() - lastProgress > 500) {
          lastProgress = Date.now();
          task.progress = task.progress.then(() => request("/api/phone/upload", { sessionId: task.sid, progress })).catch(() => {});
        }
      };
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) resolve();
        else { let message = "上传失败，请重试。"; try { message = JSON.parse(xhr.responseText).error || message; } catch {} reject(new Error(message)); }
      };
      xhr.onerror = () => reject(new Error("上传中断，请检查 Wi-Fi 后重新选择照片。"));
      xhr.onabort = () => reject(new Error("已取消上传"));
      xhr.send(file);
    });
    await task.progress;
    if (!task.cancelled) applySnapshot(await request("/api/phone/upload", { sessionId: task.sid, complete: true }));
  } catch (error) { if (!task.cancelled) notice(error.message); task.cancelled = true; }
  finally {
    await task.progress;
    if (task.cancelled && task.sid) await request("/api/phone/upload", { sessionId: task.sid, cancel: true }).catch(() => {});
    transfer = null; $("transfer").hidden = true; availability();
  }
}
$("cancel-upload").addEventListener("click", async () => {
  if (transfer) { transfer.cancelled = true; transfer.xhr?.abort(); }
  else if (snapshot?.upload) {
    try { applySnapshot(await request("/api/phone/upload", { sessionId: snapshot.upload.sessionId, cancel: true })); }
    catch (error) { notice(error.message); }
  }
});
$("pick-photos").addEventListener("click", () => $("photos-input").click());
$("photos-input").addEventListener("change", (event) => { upload(event.target.files[0]); event.target.value = ""; });

let events = null;
function subscribe() {
  // Never two subscriptions at once: an EventSource that is still open or
  // reconnecting keeps its place.
  if (document.hidden || retryPaused || (events && events.readyState !== EventSource.CLOSED)) return;
  events?.close();
  const stream = events = new EventSource("/api/phone/events");
  stream.onmessage = (event) => { if (events === stream && !document.hidden) applySnapshot(JSON.parse(event.data)); };
  stream.onerror = () => {
    if (events !== stream || document.hidden) return;
    connectionState(false);
    if (stream.readyState === EventSource.CLOSED) scheduleRetry();
  };
}
const STATE_TIMEOUT_MS = 8000;
let initializing = null, initControl = null, retryTimer = 0, retryDelay = 1000, retryPaused = false;
function scheduleRetry() {
  if (retryPaused || document.hidden || retryTimer) return;
  retryTimer = setTimeout(() => { retryTimer = 0; initialize(); }, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 8000);
}
async function runInitialize(signal) {
  const current = () => !signal.aborted && !document.hidden;
  let capabilitiesOk = Boolean(capabilities), stateOk = false, authFailure = false;
  if (!capabilities) {
    try {
      const next = await request("/api/state", undefined, { timeout: STATE_TIMEOUT_MS, signal });
      if (!current()) return;
      capabilities = next;
      $("photos-input").accept = ["image/*", ...capabilities.inputExtensions].join(",");
      capabilitiesOk = true;
    } catch (error) {
      if (!current()) return;
      authFailure = authFailure || error.status === 401 || error.status === 403;
      connectionState(false);
    }
  }
  try {
    const next = await request("/api/phone/state", undefined, { timeout: STATE_TIMEOUT_MS, signal });
    if (!current()) return;
    applySnapshot(next);
    stateOk = true;
  } catch (error) {
    if (!current()) return;
    authFailure = authFailure || error.status === 401 || error.status === 403;
    connectionState(false);
  }
  retryPaused = authFailure || (stateOk && !snapshot.enabled);
  if (stateOk && !retryPaused) subscribe();
  if (capabilitiesOk && stateOk && !retryPaused) {
    notice(""); $("retry-connection").hidden = true;
    retryPaused = false; retryDelay = 1000; clearTimeout(retryTimer); retryTimer = 0;
    return;
  }
  // 401/403 means the connection code is gone: retrying cannot bring it back.
  if (retryPaused) { events?.close(); events = null; }
  notice(retryPaused
    ? "连接口令已失效。请在电脑上重新开启手机连接，并扫描新的二维码。"
    : "连接暂时不可用，正在自动重试……也可以点击“重试连接”。");
  $("retry-connection").hidden = false;
  connectionState(false);
  scheduleRetry();
}
function initialize(manual = false) {
  if (manual) {
    retryPaused = false; retryDelay = 1000;
    clearTimeout(retryTimer); retryTimer = 0;
  }
  if (document.hidden || retryPaused) return;
  if (!initializing) {
    const control = initControl = new AbortController();
    initializing = runInitialize(control.signal).finally(() => {
      if (initControl === control) { initializing = null; initControl = null; }
    });
  }
  return initializing;
}
$("retry-connection").addEventListener("click", () => initialize(true));
function pauseConnection() {
  initControl?.abort(); initControl = null; initializing = null;
  endCompare(); events?.close(); events = null; frameRequest?.abort();
  clearTimeout(retryTimer); retryTimer = 0;
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) pauseConnection();
  else { probeDiagnostics(); initialize(); }
});
window.addEventListener("pagehide", pauseConnection);
window.addEventListener("pageshow", (event) => { if (event.persisted) initialize(); });
probeDiagnostics();
initialize();
