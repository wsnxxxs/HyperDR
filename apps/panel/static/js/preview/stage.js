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

const PREVIEW_BUCKETS = [960, 1440, 2048];
const CPU_PREVIEW_EDGE = 1280;
const RESIZE_DEBOUNCE_MS = 300;
const ZOOM_LEVELS = [0, 1, 2, 4];
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
  const zoomToggle = role("zoom-toggle");
  const fileInput = role("file-input");
  const stageFrame = role("stage-frame");
  let sdrCanvas = role("canvas-sdr");
  const hdrCanvas = role("canvas-hdr");

  /** Decoded image + derived buffers. Replaced wholesale, never patched. */
  const image = { source: null, output: null, bitmap: null, label: "" };
  const analysis = { current: null };
  const refreshScope = mountScope(store, { analysis });

  let renderer = null;        // WebGPU/WebGL renderer, or null for the CPU path
  let frame = 0;
  let loadToken = 0;
  let loadedEdge = 0;
  let loadingEdge = 0;
  let forceCpuPreview = false;
  let resizeTimer = 0;

  const zoom = {
    level: 0, x: 0, y: 0, pointerId: null, startX: 0, startY: 0,
    originX: 0, originY: 0, anchorX: 0, anchorY: 0, zebra: false,
  };

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

  const canAttemptHdrRenderer = () =>
    hdrDisplayQuery.matches && window.isSecureContext && Boolean(navigator.gpu);

  function bucketFor(edge, maximum) {
    const bucket = PREVIEW_BUCKETS.find((value) => value >= edge)
      || PREVIEW_BUCKETS[PREVIEW_BUCKETS.length - 1];
    return Math.min(bucket, maximum);
  }

  function requestedPreviewEdge() {
    const maximum = Math.max(320, Number(store.value("previewMaxEdge")) || 2048);
    const cssEdge = Math.max(stage.clientWidth, stage.clientHeight);
    const desired = Math.ceil(cssEdge * Math.max(1, window.devicePixelRatio || 1));
    if (forceCpuPreview || !canAttemptHdrRenderer()) {
      return Math.min(maximum, CPU_PREVIEW_EDGE, Math.max(PREVIEW_BUCKETS[0], desired));
    }
    return bucketFor(Math.max(PREVIEW_BUCKETS[0], desired), maximum);
  }

  function syncZoomButton() {
    const active = zoom.level > 0;
    zoomToggle.disabled = !image.source;
    zoomToggle.classList.toggle("is-on", active);
    zoomToggle.setAttribute("aria-pressed", String(active));
    setText(zoomToggle, active ? `${zoom.level * 100}%` : "检查 100%");
    zoomToggle.setAttribute(
      "aria-label",
      active
        ? `预览缩放 ${zoom.level * 100}%，点击切换`
        : "适合窗口，点击切换到 100% 检查");
  }

  function clampZoomOffset() {
    if (!zoom.level || !image.source) return;
    const width = stageFrame.clientWidth;
    const height = stageFrame.clientHeight;
    if (!width || !height) return;
    const nativeScale = image.source.width / width;
    const scale = nativeScale * zoom.level;
    const limitX = Math.max(0, (width * scale - stage.clientWidth) / 2);
    const limitY = Math.max(0, (height * scale - stage.clientHeight) / 2);
    zoom.x = Math.max(-limitX, Math.min(limitX, zoom.x));
    zoom.y = Math.max(-limitY, Math.min(limitY, zoom.y));
    stageFrame.style.transform = `translate(${zoom.x}px, ${zoom.y}px) scale(${scale})`;
  }

  function zoomScale(level = zoom.level) {
    if (!image.source || !stageFrame.clientWidth) return 1;
    return (image.source.width / stageFrame.clientWidth) * level;
  }

  function exitZoom({ restoreZebra = true } = {}) {
    if (!zoom.level) return;
    zoom.level = 0;
    zoom.pointerId = null;
    zoom.x = 0;
    zoom.y = 0;
    stageFrame.style.transform = "";
    stage.classList.remove("is-zoomed", "is-panning");
    if (restoreZebra && zoom.zebra) store.set({ zebra: true });
    zoom.zebra = false;
    syncZoomButton();
  }

  function setZoomLevel(level) {
    if (!image.source) return;
    if (!level) {
      exitZoom();
      return;
    }
    const entering = !zoom.level;
    if (entering) {
      zoom.zebra = Boolean(store.value("zebra"));
      if (zoom.zebra) store.set({ zebra: false });
      const scale = zoomScale(level);
      zoom.x = (1 - scale) * zoom.anchorX;
      zoom.y = (1 - scale) * zoom.anchorY;
      stage.classList.add("is-zoomed");
    }
    zoom.level = level;
    clampZoomOffset();
    syncZoomButton();
  }

  function cycleZoom() {
    const index = ZOOM_LEVELS.indexOf(zoom.level);
    setZoomLevel(ZOOM_LEVELS[(index + 1) % ZOOM_LEVELS.length]);
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
      if (Math.max(image.source.width, image.source.height) > CPU_PREVIEW_EDGE) {
        forceCpuPreview = true;
        return true;
      }
    }
    syncHdrState();
    schedule();
    return false;
  }

  async function chooseRenderer() {
    renderer?.destroy();
    renderer = null;

    let needsCpuReload = false;
    if (!hdrDisplayQuery.matches) {
      needsCpuReload = chooseSdrRenderer("当前屏幕为 SDR");
    } else if (!window.isSecureContext) {
      needsCpuReload = chooseSdrRenderer("HTTP 模式");
    } else if (!navigator.gpu) {
      needsCpuReload = chooseSdrRenderer("当前 Safari 没有可用的 WebGPU");
    } else {
      try {
        renderer = await createHdrRenderer(hdrCanvas, () => {
          if (chooseSdrRenderer("HDR 图形设备已断开")) {
            load({ edge: Math.min(
              CPU_PREVIEW_EDGE, store.value("previewMaxEdge") || CPU_PREVIEW_EDGE),
              allowDowngrade: true });
          }
        });
        renderer.upload(image.bitmap);
        showCanvas("hdr");
        const gamut = renderer.outputColorSpace === "display-p3" ? "Display P3" : "扩展 sRGB";
        setCapability(`真 HDR · ${gamut} · 16-bit 浮点`, true);
      } catch (error) {
        needsCpuReload = chooseSdrRenderer("WebGPU HDR 初始化失败");
      }
    }
    if (needsCpuReload) {
      await load({ edge: Math.min(CPU_PREVIEW_EDGE, store.value("previewMaxEdge") || CPU_PREVIEW_EDGE),
                   allowDowngrade: true });
      return;
    }
    syncHdrState();
    schedule();
  }

  /* ── loading ──────────────────────────────────────────────────────── */

  function clear(message = "点击添加图片") {
    exitZoom();
    loadToken++;
    loadedEdge = 0;
    loadingEdge = 0;
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
    syncZoomButton();
  }

  async function load({ edge = 0, allowDowngrade = false } = {}) {
    const sessionId = store.value("sessionId");
    const token = ++loadToken;
    if (!sessionId) { clear(); reportInitialCapability(); return; }
    exitZoom();
    let maxEdge = Number(edge) || requestedPreviewEdge();
    if (!allowDowngrade) maxEdge = Math.max(maxEdge, loadedEdge, loadingEdge);
    maxEdge = Math.min(maxEdge, Number(store.value("previewMaxEdge")) || maxEdge);
    loadingEdge = maxEdge;
    setText(caption, "正在读取本地预览…");
    setText(emptyTitle, "正在生成可调节预览…");

    try {
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
      loadedEdge = maxEdge;
      loadingEdge = 0;

      for (const canvas of [sdrCanvas, hdrCanvas]) { canvas.width = width; canvas.height = height; }
      analysis.current = analyse(image.source);

      empty.style.display = "none";
      stage.classList.add("has-image");
      store.set({ hdrOn: true, comparing: false });
      syncHdrState();
      syncZoomButton();
      refreshScope();
      await chooseRenderer();
    } catch (error) {
      if (token !== loadToken) return;
      loadingEdge = 0;
      clear(error.message || "无法载入预览。");
    }
  }

  const upload = createUploader(store, {
    onProgress: (text) => setText(progress, text),
    onReady: load,
    onError: (message) => clear(message),
  });

  /* ── input wiring ─────────────────────────────────────────────────── */

  const openPicker = () => {
    if (!store.value("uploading") && !zoom.level) fileInput.click();
  };
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

  function beginZoomPan(event) {
    event.preventDefault();
    zoom.pointerId = event.pointerId;
    zoom.startX = event.clientX;
    zoom.startY = event.clientY;
    zoom.originX = zoom.x;
    zoom.originY = zoom.y;
    stage.classList.add("is-panning");
    try { stage.setPointerCapture(event.pointerId); } catch (_) {}
  }

  function endZoomPan(event) {
    if (zoom.pointerId == null) return;
    const pointerId = zoom.pointerId;
    zoom.pointerId = null;
    stage.classList.remove("is-panning");
    try { if (stage.hasPointerCapture(pointerId)) stage.releasePointerCapture(pointerId); }
    catch (_) {}
    event?.preventDefault();
  }

  stage.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || store.value("uploading")) return;
    if (zoom.level) {
      beginZoomPan(event);
      return;
    }
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

  stage.addEventListener("pointermove", (event) => {
    if (!zoom.level) {
      const bounds = stage.getBoundingClientRect();
      zoom.anchorX = event.clientX - bounds.left - bounds.width / 2;
      zoom.anchorY = event.clientY - bounds.top - bounds.height / 2;
      return;
    }
    if (zoom.pointerId !== event.pointerId) return;
    event.preventDefault();
    zoom.x = zoom.originX + event.clientX - zoom.startX;
    zoom.y = zoom.originY + event.clientY - zoom.startY;
    clampZoomOffset();
  });

  stage.addEventListener("pointerup", (event) => {
    if (zoom.level) {
      endZoomPan(event);
      return;
    }
    const isActive = gesture.pointerId === event.pointerId;
    const elapsed = performance.now() - gesture.at;
    const moved = Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y);
    const wasComparing = store.value("comparing");
    cancelGesture(event);
    if (isActive && !wasComparing && elapsed < 320 && moved < 12) openPicker();
  });

  stage.addEventListener("pointercancel", (event) => {
    if (zoom.level) endZoomPan(event);
    else cancelGesture(event);
  });
  stage.addEventListener("lostpointercapture", (event) => {
    if (zoom.level) endZoomPan(event);
    else cancelGesture(event);
  });
  const cancelActivePointer = (event) => {
    if (zoom.level) endZoomPan(event);
    else cancelGesture(event);
  };
  stage.addEventListener("blur", cancelActivePointer);
  window.addEventListener("blur", cancelActivePointer);

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
    if (event.key === "Escape" && zoom.level) {
      event.preventDefault();
      exitZoom();
    } else if ((event.key === " " || event.key === "Enter") && !event.repeat && !zoom.level) {
      event.preventDefault();
      openPicker();
    } else if (event.key === "Escape") cancelGesture(event);
  });

  zoomToggle.addEventListener("click", cycleZoom);
  window.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !zoom.level) return;
    event.preventDefault();
    exitZoom();
  });

  mobileToggle.addEventListener("click", () => {
    if (!touchQuery.matches || !image.source) return;
    store.set({ hdrOn: !store.value("hdrOn") });
  });

  function schedulePreviewUpgrade() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resizeTimer = 0;
      if (zoom.level) clampZoomOffset();
      if (!image.source || !store.value("sessionId")) return;
      const edge = requestedPreviewEdge();
      if (edge > Math.max(loadedEdge, loadingEdge)) load({ edge });
    }, RESIZE_DEBOUNCE_MS);
  }

  new ResizeObserver(schedulePreviewUpgrade).observe(stage);
  window.addEventListener("resize", schedulePreviewUpgrade);

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
    if (!image.source) return;
    const edge = requestedPreviewEdge();
    if (edge > Math.max(loadedEdge, loadingEdge)) load({ edge });
    else chooseRenderer();
  });

  const applyPointerHint = () => stage.setAttribute("aria-label", touchQuery.matches ? TOUCH_HINT : MOUSE_HINT);
  touchQuery.addEventListener?.("change", () => {
    applyPointerHint();
    store.set({ hdrOn: true });
    schedulePreviewUpgrade();
  });

  applyPointerHint();
  reportInitialCapability();
  syncHdrState();
  syncZoomButton();

  return { redraw: schedule, reload: load, clear };
}
