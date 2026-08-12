/* The preview stage: file intake, gestures, renderer selection, and the wipe.
 *
 * The stage owns the decoded image and nothing else does. Renderers are chosen
 * once per image and swapped wholesale, so the fallback path never has to ask
 * whether a GPU device happens to exist right now.
 *
 * Comparing against the source is a first-class mode, not a hidden gesture:
 * a segmented control offers effect / original / split, where split stacks a
 * clipped 2D copy of the source over the live renderer with a draggable wipe
 * between them. Press-and-hold still works on the desktop because hands learn
 * it once and use it forever.
 */

import { api } from "../core/api.js";
import { store } from "../core/store.js";
import { role, setText, setPressed, clamp } from "../core/dom.js";
import { mobileLayout, touchQuery } from "../core/media.js";
import { renderSdr, __math } from "./cpu.js";
import { createHdrRenderer } from "./gpu.js";
import { createSdrGpuRenderer } from "./sdr-gpu.js";
import { analyse, mountScope } from "./scope.js";
import { createUploader } from "./session.js";

const hdrDisplayQuery = window.matchMedia("(dynamic-range: high)");

/* Preview sizes are quantised: the server's preview cache keys on the edge and
 * holds eight entries, so a continuous "how wide is the stage right now" would
 * evict on every window drag. Three tiers cover phone to desktop, clamped to
 * what the server says it can decode. */
const PREVIEW_TIERS = [960, 1280, 2048];

const TOUCH_HINT = "点击添加或更换图片；用视图切换对照原图";
const MOUSE_HINT = "点击添加图片；已有图片时轻点更换，按住查看原图";

const VIEW_MODES = [["original", "原图"], ["split", "分割"], ["effect", "效果"]];

/* The SDR rendition of the preview source.
 *
 * The JPEG holds an HDR input divided by `scale`, which is right for the
 * renderers -- they multiply it back -- and wrong for everything that shows the
 * source as it is: the original view, the histogram and the zebras all want the
 * picture an SDR screen would display, which is the linear value times the
 * scale, clipped at white. At scale 1 that is the identity, so the very same
 * ImageData is handed back and an SDR photograph is untouched down to the byte.
 */
function displayMapped(source, scale) {
  if (!(scale > 1)) return source;
  const { SRGB_TO_LINEAR, linearToSrgb8 } = __math;
  const table = new Uint8ClampedArray(256);
  for (let i = 0; i < 256; i++) {
    table[i] = linearToSrgb8(Math.min(1, SRGB_TO_LINEAR[i] * scale));
  }
  const mapped = new ImageData(source.width, source.height);
  const from = source.data;
  const to = mapped.data;
  for (let i = 0; i < from.length; i += 4) {
    to[i] = table[from[i]];
    to[i + 1] = table[from[i + 1]];
    to[i + 2] = table[from[i + 2]];
    to[i + 3] = from[i + 3];
  }
  return mapped;
}

function decodeBlob(blob) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const image = new Image();
    image.onload = () => resolve({ image, url });
    image.onerror = () => { URL.revokeObjectURL(url); reject(new Error("无法解码内嵌 JPEG 预览。")); };
    image.src = url;
  });
}

export function mountStage({ curve, toast }) {
  const stage = role("stage");
  const frame = stage.querySelector(".stage-frame");
  const viewport = stage.closest(".stage-viewport");
  const empty = role("stage-empty");
  const selectButton = role("stage-select");
  const emptyTitle = role("stage-title");
  const progressText = role("upload-progress");
  const progressBar = role("upload-bar");
  const hdrStatus = role("hdr-status");
  const badge = role("hdr-badge");
  const fileInput = role("file-input");
  const divider = role("divider");
  const hdrCanvas = role("canvas-hdr");
  const originalCanvas = role("canvas-original");
  const viewModeGroup = role("view-mode");
  const expandButton = role("stage-expand");
  const mathModeButton = role("math-mode");
  const optimizeButton = role("optimize");
  let sdrCanvas = role("canvas-sdr");

  /** Decoded image + derived buffers. Replaced wholesale, never patched. */
  const image = {
    source: null,
    display: null,
    output: null,
    bitmap: null,
    label: "",
    previewRequestEdge: 0,
    // What the server divided the linear image by to fit it in the JPEG. Every
    // renderer multiplies by this after linearising, so an HDR input's
    // highlights are present to be expanded rather than already clipped white.
    scale: 1,
    // Automatic scene exposure selected by the native RAW decoder. The
    // brightness control is an additional user bias and stays separate so the
    // original comparison view remains an untreated source view.
    exposureEv: 0,
  };
  let expanded = false;
  const sourceListeners = new Set();
  const notifySource = () => { for (const listener of [...sourceListeners]) listener(); };
  const analysis = { current: null, modelGain: null };
  const refreshScope = mountScope({ curve, analysis });

  let renderer = null;        // WebGPU/WebGL renderer, or null for the CPU path
  let modelGain = null;
  let frame_ = 0;
  let imageGeneration = 0;
  let rendererGeneration = 0;

  const isCurrentImage = (epoch) => epoch === imageGeneration;
  const invalidateImage = () => ++imageGeneration;
  const isCurrentRenderer = (epoch) => epoch === rendererGeneration;
  const invalidateRenderer = () => ++rendererGeneration;

  /* ── view mode segmented ──────────────────────────────────────────── */

  const modeButtons = VIEW_MODES.map(([id, label]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.textContent = label;
    button.addEventListener("click", () => store.set({ viewMode: id }));
    viewModeGroup.append(button);
    return [id, button];
  });

  const showingOriginal = () => {
    const state = store.get();
    return state.viewMode === "original" || (state.comparing && state.viewMode !== "split");
  };

  /* ── the wipe ─────────────────────────────────────────────────────── */

  /** The effect canvas's displayed rectangle, in frame coordinates. */
  function imageRect() {
    const canvas = renderer?.kind === "hdr" ? hdrCanvas : sdrCanvas;
    const c = canvas.getBoundingClientRect();
    const f = frame.getBoundingClientRect();
    return { left: c.left - f.left, top: c.top - f.top, width: c.width, height: c.height, clientLeft: c.left };
  }

  function positionDivider() {
    const state = store.get();
    if (state.viewMode !== "split" || !image.source) return;
    const rect = imageRect();
    divider.style.left = `${rect.left + state.splitRatio * rect.width}px`;
    divider.style.top = `${rect.top}px`;
    divider.style.height = `${rect.height}px`;
    divider.setAttribute("aria-valuenow", String(Math.round(state.splitRatio * 100)));
  }

  /* Fit the visible frame to the decoded image without ever cropping it.
   * Empty state sizing remains in CSS; loaded images use exact pixel geometry
   * so portrait, landscape, and panoramic sources all carry their own border. */
  function fitStageToImage() {
    if (!image.source || !viewport) {
      stage.style.removeProperty("--stage-aspect");
      stage.style.removeProperty("width");
      stage.style.removeProperty("height");
      return;
    }
    stage.style.setProperty(
      "--stage-aspect",
      `${image.source.width} / ${image.source.height}`);
    if (mobileLayout.matches || expanded) {
      stage.style.removeProperty("width");
      stage.style.removeProperty("height");
      return;
    }
    const bounds = viewport.getBoundingClientRect();
    const gutter = Number.parseFloat(
      getComputedStyle(viewport).getPropertyValue("--stage-gutter")) || 0;
    const availableWidth = Math.max(0, bounds.width - 2 * gutter);
    const availableHeight = Math.max(0, bounds.height - 2 * gutter);
    const aspect = image.source.width / image.source.height;
    let width = Math.min(availableWidth, availableHeight * aspect);
    let height = width / aspect;
    if (height > availableHeight) {
      height = availableHeight;
      width = height * aspect;
    }
    stage.style.width = `${width}px`;
    stage.style.height = `${height}px`;
  }

  function syncView() {
    const state = store.get();
    const hasImage = Boolean(image.source);
    const split = state.viewMode === "split" && hasImage;
    const original = showingOriginal();

    originalCanvas.hidden = !split;
    divider.hidden = !split;
    if (split) {
      originalCanvas.style.clipPath = `inset(0 ${((1 - state.splitRatio) * 100).toFixed(2)}% 0 0)`;
      positionDivider();
    }

    setText(badge, original ? "SDR" : "HDR");
    badge.hidden = !hasImage || renderer?.kind !== "hdr";
    stage.classList.toggle("is-comparing", original);
    stage.setAttribute("aria-pressed", String(original));
    for (const [id, button] of modeButtons) setPressed(button, id === state.viewMode);
  }

  let dividerPointer = null;
  divider.addEventListener("pointerdown", (event) => {
    // The stage would read this as the start of a tap-to-replace.
    event.stopPropagation();
    event.preventDefault();
    dividerPointer = event.pointerId;
    divider.setPointerCapture(event.pointerId);
  });
  divider.addEventListener("pointermove", (event) => {
    if (dividerPointer !== event.pointerId) return;
    const rect = imageRect();
    store.set({ splitRatio: clamp((event.clientX - rect.clientLeft) / rect.width, 0.05, 0.95) });
  });
  const endDividerDrag = (event) => {
    if (dividerPointer !== event.pointerId) return;
    dividerPointer = null;
  };
  divider.addEventListener("pointerup", endDividerDrag);
  divider.addEventListener("pointercancel", endDividerDrag);
  divider.addEventListener("keydown", (event) => {
    const delta = { ArrowLeft: -0.05, ArrowRight: 0.05 }[event.key];
    if (!delta) return;
    event.preventDefault();
    store.set({ splitRatio: clamp(store.get().splitRatio + delta, 0.05, 0.95) });
  });

  new ResizeObserver(() => {
    if (!mobileLayout.matches && !expanded) fitStageToImage();
    positionDivider();
  }).observe(viewport);

  /* ── capability reporting ─────────────────────────────────────────── */

  function setCapability(message, ok) {
    setText(hdrStatus, message);
    hdrStatus.classList.toggle("is-ok", Boolean(ok));
    stage.dataset.previewMode = renderer?.kind || "sdr-cpu";
  }

  function reportInitialCapability() {
    if (!hdrDisplayQuery.matches) setCapability("SDR 显示模式", false);
    else if (!window.isSecureContext) setCapability("HDR 需要受信任的 HTTPS", false);
    else if (!navigator.gpu) setCapability("此浏览器无法启用 WebGPU HDR", false);
    else setCapability("HDR 能力就绪", true);
  }

  /* ── rendering ────────────────────────────────────────────────────── */

  function draw() {
    frame_ = 0;
    if (!image.source) return;
    const state = store.get();
    curve.refreshTable(state);
    const original = showingOriginal();
    if (renderer) {
      renderer.draw(curve.table, {
        strength: state.hdrStrength, headroom: state.hdrRange,
        original, expansionStart: state.expansionStart,
        areaCoverage: state.areaCoverage, exposureBias: state.brightness,
        vibrance: state.vibrance, sourceScale: image.scale,
        sourceExposure: image.exposureEv,
        modelGain: state.previewOptimized ? modelGain : null,
        modelStrength: state.modelStrength,
      });
    } else {
      renderSdr(sdrCanvas, {
        source: image.source, display: image.display, output: image.output, curve,
        settings: state, original, sourceScale: image.scale,
        sourceExposure: image.exposureEv,
        modelGain: state.previewOptimized ? modelGain : null,
      });
    }
  }

  function schedule() {
    if (!image.source) return;
    if (frame_) cancelAnimationFrame(frame_);
    frame_ = requestAnimationFrame(draw);
  }

  function showCanvas(mode) {
    hdrCanvas.hidden = mode !== "hdr";
    sdrCanvas.hidden = mode !== "sdr";
  }

  function chooseSdrRenderer(reason, epoch = rendererGeneration, forceCpu = false) {
    if (!isCurrentRenderer(epoch) || !image.bitmap) return;
    renderer?.destroy();
    renderer = null;
    try {
      if (forceCpu) throw new Error("WebGL context lost");
      let created = null;
      created = createSdrGpuRenderer(sdrCanvas, () => {
        if (isCurrentRenderer(epoch) && renderer === created) {
          chooseSdrRenderer("SDR 图形设备已断开", epoch, true);
        }
      });
      renderer = created;
      renderer.upload(image.bitmap);
      if (modelGain) renderer.uploadGainMap(modelGain);
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
    syncView();
    schedule();
  }

  async function chooseRenderer(epoch = invalidateRenderer()) {
    if (!isCurrentRenderer(epoch) || !image.bitmap) return;
    renderer?.destroy();
    renderer = null;

    if (!hdrDisplayQuery.matches) {
      chooseSdrRenderer("当前屏幕为 SDR", epoch);
    } else if (!window.isSecureContext) {
      chooseSdrRenderer("HTTP 模式", epoch);
    } else if (!navigator.gpu) {
      chooseSdrRenderer("当前浏览器没有可用的 WebGPU", epoch);
    } else {
      let created = null;
      try {
        created = await createHdrRenderer(hdrCanvas, () => {
          if (isCurrentRenderer(epoch) && renderer === created) {
            chooseSdrRenderer("HDR 图形设备已断开", epoch);
          }
        });
        if (!isCurrentRenderer(epoch) || !image.bitmap) { created.destroy(); return; }
        renderer = created;
        renderer.upload(image.bitmap);
        if (modelGain) renderer.uploadGainMap(modelGain);
        showCanvas("hdr");
        const gamut = renderer.outputColorSpace === "display-p3" ? "Display P3" : "扩展 sRGB";
        setCapability(`真 HDR · ${gamut} · 16-bit 浮点`, true);
      } catch (error) {
        created?.destroy();
        if (!isCurrentRenderer(epoch)) return;
        chooseSdrRenderer("WebGPU HDR 初始化失败", epoch);
      }
    }
    if (!isCurrentRenderer(epoch)) return;
    syncView();
    schedule();
  }

  /* ── loading ──────────────────────────────────────────────────────── */

  function previewTier() {
    const ceiling = Number(store.get().capabilities?.previewMaxEdge);
    // Before /api/state resolves, let the server apply its configured maximum.
    if (!Number.isFinite(ceiling) || ceiling <= 0) return null;
    const allowed = PREVIEW_TIERS.filter((tier) => tier <= ceiling);
    const list = allowed.length ? allowed : [ceiling];
    const box = frame.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const want = Math.max(box.width, box.height, 640) * dpr;
    for (const tier of list) if (tier >= want) return tier;
    return list[list.length - 1];
  }

  let nativeFullscreenActive = false;

  function updateExpandedState(next, { exitNative = true } = {}) {
    expanded = Boolean(next && image.source && mobileLayout.matches);
    viewport.classList.toggle("is-expanded", expanded);
    document.documentElement.classList.toggle("preview-expanded", expanded);
    expandButton.setAttribute("aria-pressed", String(expanded));
    expandButton.setAttribute("aria-label", expanded ? "退出全屏查看" : "全屏查看");

    if (!expanded) {
      if (exitNative && document.fullscreenElement === viewport) {
        document.exitFullscreen?.().catch(() => {});
      }
      return;
    }

    // CSS expansion is the dependable path on every mobile browser. Native
    // fullscreen is only an enhancement and must be requested while this click
    // still owns user activation.
    if (!document.fullscreenElement && typeof viewport.requestFullscreen === "function") {
      viewport.requestFullscreen().catch(() => {});
    }

    // Let the fixed overlay acquire its final dimensions, then ask for a
    // higher cached preview tier only when the existing decode is too small.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!expanded) return;
      const wanted = previewTier();
      if (wanted && wanted > image.previewRequestEdge) load();
    }));
  }

  document.addEventListener("fullscreenchange", () => {
    if (document.fullscreenElement === viewport) {
      nativeFullscreenActive = true;
    } else if (nativeFullscreenActive) {
      nativeFullscreenActive = false;
      updateExpandedState(false, { exitNative: false });
    }
  });

  function clear(message = "选择图片") {
    invalidateImage();
    invalidateRenderer();
    updateExpandedState(false);
    image.bitmap?.close();
    Object.assign(image, {
      source: null,
      display: null,
      output: null,
      bitmap: null,
      label: "",
      previewRequestEdge: 0,
      scale: 1,
      exposureEv: 0,
    });
    notifySource();
    analysis.current = null;
    renderer?.destroy();
    renderer = null;
    modelGain = null;
    analysis.modelGain = null;
    store.set({
      comparing: false, maskKey: null,
      previewOptimized: false, modelGainReady: false, optimizing: false,
    });
    stage.classList.remove("has-image", "is-comparing");
    fitStageToImage();
    stage.removeAttribute("role");
    stage.removeAttribute("tabindex");
    for (const canvas of [sdrCanvas, hdrCanvas, originalCanvas]) {
      canvas.hidden = true;
      canvas.width = 0;
      canvas.height = 0;
    }
    divider.hidden = true;
    empty.style.display = "flex";
    setText(emptyTitle, message);
    refreshScope();
    syncView();
  }

  async function load() {
    const sessionId = store.get().sessionId;
    const epoch = invalidateImage();
    if (!sessionId) { clear(); reportInitialCapability(); return; }
    setText(emptyTitle, "正在生成可调节预览…");

    try {
      const state = store.get();
      const requestedEdge = previewTier();
      const preview = await api.preview(sessionId, {
        highlightRecovery: state.highlightRecovery,
        maxEdge: requestedEdge,
      });
      const { image: decoded, url } = await decodeBlob(preview.blob);
      if (!isCurrentImage(epoch)) { URL.revokeObjectURL(url); return; }

      // The contract says to trust the headers over re-measuring the bitmap.
      const width = preview.width || decoded.naturalWidth;
      const height = preview.height || decoded.naturalHeight;

      const scratch = document.createElement("canvas");
      scratch.width = width;
      scratch.height = height;
      const context = scratch.getContext("2d", { willReadFrequently: true });
      context.drawImage(decoded, 0, 0, width, height);
      URL.revokeObjectURL(url);

      const bitmap = await createImageBitmap(scratch);
      if (!isCurrentImage(epoch)) { bitmap.close(); return; }
      image.bitmap?.close();
      image.bitmap = bitmap;
      image.source = context.getImageData(0, 0, width, height);
      image.output = context.createImageData(width, height);
      image.label = state.file?.name || "图片";
      image.previewRequestEdge = requestedEdge || Math.max(width, height);
      image.scale = preview.scale || 1;
      image.exposureEv = preview.exposure || 0;
      image.display = displayMapped(image.source, image.scale);
      notifySource();

      for (const canvas of [sdrCanvas, hdrCanvas, originalCanvas]) {
        canvas.width = width;
        canvas.height = height;
      }
      originalCanvas.getContext("2d").putImageData(image.display, 0, 0);
      analysis.current = analyse(
        image.display, image.source,
        image.scale * Math.pow(2, image.exposureEv));

      empty.style.display = "none";
      stage.classList.add("has-image");
      fitStageToImage();
      stage.setAttribute("role", "button");
      stage.tabIndex = 0;
      store.set({ comparing: false });
      refreshScope();
      await chooseRenderer();
    } catch (error) {
      if (!isCurrentImage(epoch)) return;
      clear(error.message || "无法载入预览。");
    }
  }

  const upload = createUploader({
    onProgress: (fraction) => {
      progressBar.style.width = `${Math.round(fraction * 100)}%`;
      setText(progressText, fraction > 0 && fraction < 1
        ? `上传中 · ${Math.round(fraction * 100)}%` : "");
    },
    onReady: async () => {
      modelGain = null;
      analysis.modelGain = null;
      store.set({
        previewOptimized: false, modelGainReady: false, optimizing: false,
      });
      await load();
    },
    onError: (message, { preserveCurrent } = {}) => {
      if (!preserveCurrent) clear(message);
      toast(message, true);
    },
  });

  /* ── input wiring ─────────────────────────────────────────────────── */

  const canReplace = () => {
    const state = store.get();
    return !state.uploading && !state.optimizing && !state.jobId;
  };
  const openPicker = () => { if (canReplace()) fileInput.click(); };
  selectButton.addEventListener("click", openPicker);
  expandButton.addEventListener("click", (event) => {
    event.stopPropagation();
    updateExpandedState(!expanded);
  });
  const isStageControl = (target) =>
    target instanceof Element
    && Boolean(target.closest("button, a, input, select, textarea, [role='slider']"));
  fileInput.addEventListener("change", (event) => {
    upload(event.target.files);
    fileInput.value = "";
  });

  const gesture = { pointerId: null, at: 0, x: 0, y: 0, timer: 0 };

  function beginCompare(event) {
    if (!image.source || store.get().comparing || store.get().viewMode === "split") return;
    event?.preventDefault();
    store.set({ comparing: true });
    if (event?.pointerId != null) { try { stage.setPointerCapture(event.pointerId); } catch (_) {} }
  }

  function endCompare(event) {
    if (!store.get().comparing) return;
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
    if (event.button !== 0 || !canReplace() || isStageControl(event.target)) return;
    gesture.pointerId = event.pointerId;
    gesture.at = performance.now();
    gesture.x = event.clientX;
    gesture.y = event.clientY;
    clearTimeout(gesture.timer);
    // Press-and-hold compares against the original; a tap opens the picker.
    // Touch devices get the segmented control instead, since a long press
    // there already means "select".
    if (image.source && !touchQuery.matches) {
      gesture.timer = setTimeout(() => beginCompare(event), 240);
    }
  });

  stage.addEventListener("pointerup", (event) => {
    const isActive = gesture.pointerId === event.pointerId;
    const elapsed = performance.now() - gesture.at;
    const moved = Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y);
    const wasComparing = store.get().comparing;
    cancelGesture(event);
    if (isActive && !wasComparing && !isStageControl(event.target)
        && elapsed < 320 && moved < 12) openPicker();
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
    if (canReplace() && event.dataTransfer.files.length) upload(event.dataTransfer.files);
  });

  stage.addEventListener("contextmenu", (event) => { if (image.source) event.preventDefault(); });
  stage.addEventListener("selectstart", (event) => { if (touchQuery.matches) event.preventDefault(); });
  stage.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && expanded) {
      event.preventDefault();
      updateExpandedState(false);
    } else if (event.target === stage
        && (event.key === " " || event.key === "Enter") && !event.repeat) {
      event.preventDefault();
      openPicker();
    } else if (event.key === "Escape") cancelGesture(event);
  });

  /* ── reactions ────────────────────────────────────────────────────── */

  store.watchAny(["viewMode", "comparing", "splitRatio"], () => { syncView(); schedule(); }, { immediate: true });
  store.watchAny(["uploading"], (state) => {
    stage.classList.toggle("is-uploading", state.uploading);
    stage.setAttribute("aria-busy", String(state.uploading));
    selectButton.disabled = state.uploading;
  });
  store.watchAny(
    ["brightness", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage",
     "encoding", "contrast", "vibrance", "previewOptimized", "modelStrength"],
    (state) => { curve.validateOnce(state); schedule(); },
    { immediate: true });

  /* Every other control acts on the decoded pixels the browser already holds,
   * so a redraw is enough. Highlight recovery acts *during* the RAW decode, so
   * the pixels themselves are stale and the preview has to be fetched again. */
  let decodedWith = store.get().highlightRecovery;
  store.watch("highlightRecovery", (mode) => {
    if (mode === decodedWith) return;
    decodedWith = mode;
    modelGain = null;
    analysis.modelGain = null;
    store.set({ previewOptimized: false, modelGainReady: false });
    if (store.get().sessionId) load();
  });

  async function optimize() {
    const state = store.get();
    if (state.previewOptimized || state.optimizing) return;
    if (modelGain) {
      store.set({ previewOptimized: true, modelGainReady: true });
      return;
    }
    if (!state.sessionId || !state.capabilities?.model?.ready) return;
    store.set({ optimizing: true });
    try {
      const gain = await api.modelPreview(state.sessionId, state.highlightRecovery);
      if (store.get().sessionId !== state.sessionId || store.get().file !== state.file
          || store.get().highlightRecovery !== state.highlightRecovery) return;
      modelGain = gain;
      analysis.modelGain = gain;
      renderer?.uploadGainMap(gain);
      store.set({ previewOptimized: true, modelGainReady: true });
      schedule();
      toast("模型优化已应用");
    } catch (error) {
      modelGain = null;
      analysis.modelGain = null;
      store.set({ previewOptimized: false, modelGainReady: false });
      toast(error.message || "模型优化失败。", true);
    } finally {
      store.set({ optimizing: false });
    }
  }

  mathModeButton.addEventListener("click", () => {
    if (!store.get().optimizing) store.set({ previewOptimized: false });
  });
  optimizeButton.addEventListener("click", optimize);
  store.watchAny(
    ["file", "capabilities", "optimizing", "previewOptimized", "modelGainReady", "jobId"],
    (state) => {
      const ready = Boolean(state.capabilities?.model?.ready);
      const locked = state.optimizing || Boolean(state.jobId);
      mathModeButton.disabled = !state.file || locked;
      optimizeButton.disabled =
        !state.file || locked || (!ready && !state.modelGainReady);
      mathModeButton.setAttribute("aria-pressed", String(!state.previewOptimized));
      optimizeButton.setAttribute("aria-pressed", String(state.previewOptimized));
      setText(optimizeButton, state.optimizing ? "优化中…" : "优化");
      optimizeButton.title = state.previewOptimized
        ? "当前正在显示模型优化效果"
        : state.modelGainReady
        ? "切换到已缓存的模型优化效果"
        : ready ? "使用机器模型生成当前图片的增益图"
        : (state.capabilities?.model?.reason || "模型尚未就绪");
    },
    { immediate: true },
  );

  hdrDisplayQuery.addEventListener?.("change", () => {
    reportInitialCapability();
    if (image.source) chooseRenderer();
  });

  const applyPointerHint = () =>
    stage.setAttribute("aria-label", touchQuery.matches ? TOUCH_HINT : MOUSE_HINT);
  touchQuery.addEventListener?.("change", () => {
    applyPointerHint();
    store.set({ comparing: false });
  });
  mobileLayout.addEventListener?.("change", () => {
    fitStageToImage();
    positionDivider();
  });

  applyPointerHint();
  reportInitialCapability();

  return {
    redraw: schedule,
    reload: load,
    clear,
    /** The decoded preview pixels, for the mask overlay. Null before upload. */
    getSource: () => image.source,
    /** What those pixels were divided by, so the mask reads the same scene
     *  luminance the renderers do. */
    getSourceScale: () => image.scale,
    /** The automatic scene exposure, in EV, before the user's brightness bias. */
    getSourceExposure: () => image.exposureEv,
    /** The complete linear multiplier used for masks and histogram simulation. */
    getSourceSceneScale: () => image.scale * Math.pow(2, image.exposureEv),
    onSourceChange(listener) {
      sourceListeners.add(listener);
      return () => sourceListeners.delete(listener);
    },
  };
}
