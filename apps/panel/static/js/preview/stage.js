/* The preview stage: file intake, gestures, renderer selection, and the loop.
 *
 * The stage owns the decoded image and nothing else does. Renderers are chosen
 * once per image and swapped wholesale, so the fallback path never has to ask
 * whether a GPU device happens to exist right now.
 */

import { api } from "../core/api.js";
import { role, setText } from "../core/dom.js";
import { renderSdr } from "./cpu.js";
import { createHdrRenderer } from "./gpu.js";
import { createSdrGpuRenderer } from "./sdr-gpu.js";
import { analyse, mountScope } from "./scope.js";
import { createUploader } from "./session.js";

const DESKTOP_PREVIEW_EDGE = 1280;
const MOBILE_PREVIEW_EDGE = 960;
const hdrDisplayQuery = window.matchMedia("(dynamic-range: high)");
const touchQuery = window.matchMedia(
  "(max-width: 640px), (max-width: 1024px) and (hover: none) and (pointer: coarse)");

const TOUCH_HINT = "点击添加图片；已有图片时轻点更换；用 HDR 开关查看原图";
const MOUSE_HINT = "点击添加图片；已有图片时轻点更换，按住查看原图";

function decodeBlob(blob) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const image = new Image();
    image.onload = () => resolve({ image, url });
    image.onerror = () => { URL.revokeObjectURL(url); reject(new Error("无法解码内嵌 JPEG 预览。")); };
    image.src = url;
  });
}

export function mountStage(store, { curve, toast }) {
  const stage = role("stage");
  const empty = role("stage-empty");
  const emptyTitle = role("stage-title");
  const progress = role("upload-progress");
  const caption = role("viewer-caption");
  const hdrStatus = role("hdr-status");
  const lamp = role("hdr-lamp");
  const badge = role("hdr-badge");
  const mobileToggle = role("mobile-hdr");
  const fileInput = role("file-input");
  let sdrCanvas = role("canvas-sdr");
  const hdrCanvas = role("canvas-hdr");

  /** Decoded image + derived buffers. Replaced wholesale, never patched. */
  const image = { source: null, output: null, bitmap: null, label: "" };
  const analysis = { current: null };
  const refreshScope = mountScope(store, { analysis });

  let renderer = null;        // WebGPU/WebGL renderer, or null for the CPU path
  let frame = 0;
  let loadToken = 0;

  /* ── capability reporting ─────────────────────────────────────────── */

  function setCapability(message, ok) {
    lamp.classList.remove("is-pending", "is-ok", "is-bad");
    lamp.classList.add(ok ? "is-ok" : "is-bad");
    lamp.setAttribute("aria-label", message);
    lamp.title = message;
    setText(hdrStatus, message);
    stage.dataset.previewMode = renderer?.kind || "sdr-cpu";
  }

  function reportInitialCapability() {
    if (!hdrDisplayQuery.matches) setCapability("SDR 显示模式", false);
    else if (!window.isSecureContext) setCapability("HDR 需要受信任的 HTTPS", false);
    else if (!navigator.gpu) setCapability("此 Safari 无法启用 WebGPU HDR", false);
    else setCapability("HDR 能力就绪", true);
  }

  /* ── HDR on/off state ─────────────────────────────────────────────── */

  const showingOriginal = () =>
    store.value("comparing") || (touchQuery.matches && !store.value("hdrOn"));

  function syncHdrState() {
    const original = showingOriginal();
    const hasHdrPreview = renderer?.kind === "hdr";
    const label = original ? "SDR" : "HDR";
    const toggleLabel = original ? "查看效果" : "查看原图";
    stage.classList.toggle("is-comparing", original);
    stage.setAttribute("aria-pressed", String(original));
    setText(badge, label);
    badge.hidden = !image.source || !hasHdrPreview;
    setText(mobileToggle, toggleLabel);
    mobileToggle.classList.toggle("is-on", !original);
    mobileToggle.setAttribute("aria-pressed", String(original));
    mobileToggle.disabled = !image.source;
  }

  /* ── rendering ────────────────────────────────────────────────────── */

  function draw() {
    frame = 0;
    if (!image.source) return;
    const state = store.get();
    curve.refreshTable(state);
    if (renderer) {
      renderer.draw(curve.table, {
        strength: state.hdrStrength, headroom: state.hdrRange,
        original: showingOriginal(), expansionStart: state.expansionStart,
        areaCoverage: state.areaCoverage, exposureBias: state.brightness,
      });
    } else {
      renderSdr(sdrCanvas, {
        source: image.source, output: image.output, curve,
        settings: state, original: showingOriginal(),
      });
    }
    setText(caption, image.label);
  }

  function schedule() {
    if (!image.source) return;
    if (frame) cancelAnimationFrame(frame);
    frame = requestAnimationFrame(draw);
  }

  function showCanvas(mode) {
    hdrCanvas.hidden = mode !== "hdr";
    sdrCanvas.hidden = mode !== "sdr";
  }

  function chooseSdrRenderer(reason) {
    renderer?.destroy();
    renderer = null;
    try {
      renderer = createSdrGpuRenderer(sdrCanvas);
      renderer.upload(image.bitmap);
      showCanvas("sdr");
      setCapability(`${reason} · GPU SDR 示意`, false);
    } catch (error) {
      renderer = null;
      // A canvas that has successfully created a WebGL context cannot later
      // switch to 2D. Replace it before entering the last-resort CPU path if
      // WebGL setup failed after context creation.
      const replacement = sdrCanvas.cloneNode(false);
      replacement.width = sdrCanvas.width;
      replacement.height = sdrCanvas.height;
      sdrCanvas.replaceWith(replacement);
      sdrCanvas = replacement;
      showCanvas("sdr");
      setCapability(`${reason} · 兼容 SDR 示意`, false);
    }
    syncHdrState();
    schedule();
  }

  async function chooseRenderer() {
    renderer?.destroy();
    renderer = null;

    if (!hdrDisplayQuery.matches) {
      chooseSdrRenderer("当前屏幕为 SDR");
    } else if (!window.isSecureContext) {
      chooseSdrRenderer("HTTP 模式");
    } else if (!navigator.gpu) {
      chooseSdrRenderer("当前 Safari 没有可用的 WebGPU");
    } else {
      try {
        renderer = await createHdrRenderer(hdrCanvas, () => {
          chooseSdrRenderer("HDR 图形设备已断开");
        });
        renderer.upload(image.bitmap);
        showCanvas("hdr");
        const gamut = renderer.outputColorSpace === "display-p3" ? "Display P3" : "扩展 sRGB";
        setCapability(`真 HDR · ${gamut} · 16-bit 浮点`, true);
      } catch (error) {
        chooseSdrRenderer("WebGPU HDR 初始化失败");
      }
    }
    syncHdrState();
    schedule();
  }

  /* ── loading ──────────────────────────────────────────────────────── */

  function clear(message = "点击添加图片") {
    loadToken++;
    image.bitmap?.close();
    Object.assign(image, { source: null, output: null, bitmap: null, label: "" });
    analysis.current = null;
    renderer?.destroy();
    renderer = null;
    store.set({ comparing: false, hdrOn: true });
    stage.classList.remove("has-image", "is-comparing");
    for (const canvas of [sdrCanvas, hdrCanvas]) { canvas.hidden = true; canvas.width = 0; canvas.height = 0; }
    empty.style.display = "flex";
    setText(emptyTitle, message);
    setText(caption, message);
    refreshScope();
    syncHdrState();
  }

  async function load() {
    const sessionId = store.value("sessionId");
    const token = ++loadToken;
    if (!sessionId) { clear(); reportInitialCapability(); return; }
    setText(caption, "正在读取本地预览…");
    setText(emptyTitle, "正在生成可调节预览…");

    try {
      const maxEdge = touchQuery.matches ? MOBILE_PREVIEW_EDGE : DESKTOP_PREVIEW_EDGE;
      const { image: decoded, url } = await decodeBlob(
        await api.previewBlob(
          sessionId, store.value("highlightRecovery"), maxEdge));
      if (token !== loadToken) { URL.revokeObjectURL(url); return; }

      const scale = Math.min(1, maxEdge /
        Math.max(decoded.naturalWidth, decoded.naturalHeight));
      const width = Math.max(1, Math.round(decoded.naturalWidth * scale));
      const height = Math.max(1, Math.round(decoded.naturalHeight * scale));

      const scratch = document.createElement("canvas");
      scratch.width = width;
      scratch.height = height;
      const context = scratch.getContext("2d", { willReadFrequently: true });
      context.drawImage(decoded, 0, 0, width, height);
      URL.revokeObjectURL(url);

      image.bitmap?.close();
      image.bitmap = await createImageBitmap(scratch);
      image.source = context.getImageData(0, 0, width, height);
      image.output = context.createImageData(width, height);
      image.label = store.value("file")?.name || "图片";

      for (const canvas of [sdrCanvas, hdrCanvas]) { canvas.width = width; canvas.height = height; }
      analysis.current = analyse(image.source);

      empty.style.display = "none";
      stage.classList.add("has-image");
      store.set({ hdrOn: true, comparing: false });
      syncHdrState();
      refreshScope();
      await chooseRenderer();
    } catch (error) {
      if (token !== loadToken) return;
      clear(error.message || "无法载入预览。");
    }
  }

  const upload = createUploader(store, {
    onProgress: (text) => setText(progress, text),
    onReady: load,
    onError: (message) => clear(message),
  });

  /* ── input wiring ─────────────────────────────────────────────────── */

  const openPicker = () => { if (!store.value("uploading")) fileInput.click(); };
  fileInput.addEventListener("change", (event) => {
    upload(event.target.files);
    fileInput.value = "";
  });

  const gesture = { pointerId: null, at: 0, x: 0, y: 0, timer: 0 };

  function beginCompare(event) {
    if (!image.source || store.value("comparing")) return;
    event?.preventDefault();
    store.set({ comparing: true });
    if (event?.pointerId != null) { try { stage.setPointerCapture(event.pointerId); } catch (_) {} }
  }

  function endCompare(event) {
    if (!store.value("comparing")) return;
    store.set({ comparing: false });
    if (event?.pointerId != null) {
      try { if (stage.hasPointerCapture(event.pointerId)) stage.releasePointerCapture(event.pointerId); }
      catch (_) {}
    }
  }

  function cancelGesture(event) {
    clearTimeout(gesture.timer);
    gesture.timer = 0;
    gesture.pointerId = null;
    endCompare(event);
  }

  stage.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || store.value("uploading")) return;
    gesture.pointerId = event.pointerId;
    gesture.at = performance.now();
    gesture.x = event.clientX;
    gesture.y = event.clientY;
    clearTimeout(gesture.timer);
    // Press-and-hold compares against the original; a tap opens the picker.
    // Touch devices get an explicit toggle instead, since a long press there
    // already means "select".
    if (image.source && !touchQuery.matches) {
      gesture.timer = setTimeout(() => beginCompare(event), 240);
    }
  });

  stage.addEventListener("pointerup", (event) => {
    const isActive = gesture.pointerId === event.pointerId;
    const elapsed = performance.now() - gesture.at;
    const moved = Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y);
    const wasComparing = store.value("comparing");
    cancelGesture(event);
    if (isActive && !wasComparing && elapsed < 320 && moved < 12) openPicker();
  });

  stage.addEventListener("pointercancel", cancelGesture);
  stage.addEventListener("lostpointercapture", cancelGesture);
  stage.addEventListener("blur", cancelGesture);
  window.addEventListener("blur", cancelGesture);

  for (const type of ["dragover", "dragenter"]) {
    stage.addEventListener(type, (event) => {
      event.preventDefault();
      stage.classList.add("is-drop-target");
    });
  }
  stage.addEventListener("dragleave", (event) => {
    if (!stage.contains(event.relatedTarget)) stage.classList.remove("is-drop-target");
  });
  stage.addEventListener("drop", (event) => {
    event.preventDefault();
    stage.classList.remove("is-drop-target");
    if (event.dataTransfer.files.length) upload(event.dataTransfer.files);
  });

  stage.addEventListener("contextmenu", (event) => { if (image.source) event.preventDefault(); });
  stage.addEventListener("selectstart", (event) => { if (touchQuery.matches) event.preventDefault(); });
  stage.addEventListener("keydown", (event) => {
    if ((event.key === " " || event.key === "Enter") && !event.repeat) {
      event.preventDefault();
      openPicker();
    } else if (event.key === "Escape") cancelGesture(event);
  });

  mobileToggle.addEventListener("click", () => {
    if (!touchQuery.matches || !image.source) return;
    store.set({ hdrOn: !store.value("hdrOn") });
  });

  /* ── reactions ────────────────────────────────────────────────────── */

  store.watch(["comparing", "hdrOn"], () => { syncHdrState(); schedule(); });
  store.watch(["uploading"], (state) => {
    stage.classList.toggle("is-uploading", state.uploading);
    stage.setAttribute("aria-busy", String(state.uploading));
  });
  store.watch(
    ["brightness", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage", "encoding", "look", "contrast"],
    () => { curve.schedule(); schedule(); });

  /* Every other control acts on the decoded pixels the browser already holds,
   * so a redraw is enough. Highlight recovery acts *during* the RAW decode, so
   * the pixels themselves are stale and the preview has to be fetched again. */
  let decodedWith = store.value("highlightRecovery");
  store.subscribe((state, moved) => {
    if (!moved.has("highlightRecovery")) return;
    if (state.highlightRecovery === decodedWith) return;
    decodedWith = state.highlightRecovery;
    if (state.sessionId) load();
  });

  hdrDisplayQuery.addEventListener?.("change", () => {
    reportInitialCapability();
    if (image.source) chooseRenderer();
  });

  const applyPointerHint = () => stage.setAttribute("aria-label", touchQuery.matches ? TOUCH_HINT : MOUSE_HINT);
  touchQuery.addEventListener?.("change", () => {
    applyPointerHint();
    store.set({ hdrOn: true });
  });

  applyPointerHint();
  reportInitialCapability();
  syncHdrState();

  return { redraw: schedule, reload: load, clear };
}
