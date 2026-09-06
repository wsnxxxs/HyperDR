import { decodePreview } from "/js/preview/packet.js";
import { createHdrRenderer } from "/js/preview/gpu.js";
import { createSdrGpuRenderer } from "/js/preview/sdr-gpu.js";
import { renderSdr } from "/js/preview/cpu.js";

const $ = (id) => document.getElementById(id);
let snapshot = null, capabilities = null, online = false, transfer = null;
let frame = null, original = null, photoId = "", displayedVersion = 0;
let renderer = null, canvas = $("photo"), frameRequest = null, rendering = false;
let comparing = false, zoom = 1, panX = 0, panY = 0;
const pointers = new Map();
let gesture = null;

async function request(path, body) {
  const response = await fetch(path, body === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "请求未完成，请重试。");
  return data;
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
  $("pick-photos").disabled = $("pick-files").disabled = !ready || Boolean(busy);
  $("pick-label").textContent = snapshot?.current?.file ? "换一张照片" : "从相册选择";
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
    const save = document.createElement("a"); save.textContent = "保存到手机"; save.download = entry.name;
    save.href = "/api/result?" + new URLSearchParams({ id: entry.sessionId, export: entry.id, download: "1" });
    info.append(title, meta); card.append(mark, info, save); return card;
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
    $("compare").disabled = $("fit").disabled = true;
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
async function initRenderer() {
  if (renderer) return;
  if (window.isSecureContext && navigator.gpu && matchMedia("(dynamic-range: high)").matches) {
    try { renderer = await createHdrRenderer(canvas, () => rendererLost()); }
    catch { newCanvas(); }
  }
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
    $("compare").disabled = $("fit").disabled = false;
    $("viewer-state").textContent = snapshot.current.status === "exporting" ? "正在导出成品" : "已同步最新效果";
    transform();
  } catch (error) {
    if (error.name !== "AbortError") $("viewer-state").textContent = error.message;
  } finally {
    rendering = false; frameRequest = null;
    if (retry && snapshot?.frameReady) loadFrame();
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
$("fit").addEventListener("click", resetView);
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
$("pick-files").addEventListener("click", () => $("files-input").click());
for (const id of ["photos-input", "files-input"]) $(id).addEventListener("change", (event) => { upload(event.target.files[0]); event.target.value = ""; });

let events = null;
function subscribe() {
  events?.close(); events = new EventSource("/api/phone/events");
  events.onmessage = (event) => { applySnapshot(JSON.parse(event.data)); };
  events.onerror = () => connectionState(false);
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { endCompare(); events?.close(); frameRequest?.abort(); }
  else { subscribe(); request("/api/phone/state").then(applySnapshot).catch(() => connectionState(false)); }
});
window.addEventListener("pagehide", () => { events?.close(); frameRequest?.abort(); });
window.addEventListener("pageshow", (event) => { if (event.persisted) subscribe(); });
async function boot() {
  try {
    capabilities = await request("/api/state");
    $("files-input").accept = capabilities.inputExtensions.join(",");
    applySnapshot(await request("/api/phone/state")); subscribe();
  } catch { notice("连接暂时不可用。请在电脑上开启手机连接工作台，扫描新的二维码。"); connectionState(false); }
}
boot();
