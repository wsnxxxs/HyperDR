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
import { renderSdr, planeToImageData } from "./cpu.js";
import { createHdrRenderer } from "./gpu.js";
import { createSdrGpuRenderer } from "./sdr-gpu.js";
import { analyse, mountScope } from "./scope.js";
import { createUploader } from "./session.js";
import { toOptions } from "../settings/schema.js";

const hdrDisplayQuery = window.matchMedia("(dynamic-range: high)");

/* Preview sizes are quantised: the server's preview cache keys on the edge and
 * holds eight entries, so a continuous "how wide is the stage right now" would
 * evict on every window drag. Three tiers cover phone to desktop, clamped to
 * what the server says it can decode. */
const PREVIEW_TIERS = [960, 1280, 2048];

/* Shown on the photograph itself (see .stage-hint), so the gestures are
 * discoverable by sighted users too -- an aria-label alone only speaks to
 * screen readers. */
const TOUCH_HINT = "轻点更换图片 · 用上方视图切换对照原图";
const MOUSE_HINT = "轻点更换图片 · 按住查看原图";

const VIEW_MODES = [["original", "原图"], ["split", "对比"], ["effect", "HDR 效果"]];

export function mountStage({ toast }) {
  const stage = role("stage");
  const frame = stage.querySelector(".stage-frame");
  const viewport = stage.closest(".stage-viewport");
  const empty = role("stage-empty");
  const selectButton = role("stage-select");
  const emptyTitle = role("stage-title");
  const progressText = role("upload-progress");
  const progressBar = role("upload-bar");
  const uploadOverlay = role("stage-upload");
  const uploadOverlayText = role("stage-upload-text");
  const uploadCancel = role("upload-cancel");
  const hintEl = role("stage-hint");
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
    frame: null,
    // The comparison image is captured once for each uploaded/decode variant.
    // `source` and `frame` are replaced whenever a look slider moves, so using
    // either one for "原图" makes the supposedly untreated side follow the
    // adjustment as well.
    original: null,
    previewRequestEdge: 0,
  };
  let expanded = false;
  const sourceListeners = new Set();
  const notifySource = () => { for (const listener of [...sourceListeners]) listener(); };
  const analysis = { current: null, modelGain: null };
  const refreshScope = mountScope({ analysis });

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
    const showOriginalCanvas = Boolean(image.original) && (split || original);

    // The original is a separate 2D layer.  It must not be rendered from the
    // current native frame because that frame is regenerated for every look
    // adjustment.  In split mode it is clipped over the live effect; in
    // original/press-and-hold mode it covers the effect canvas completely.
    originalCanvas.hidden = !showOriginalCanvas;
    hdrCanvas.hidden = original || (renderer?.kind !== "hdr");
    sdrCanvas.hidden = original || renderer?.kind === "hdr"
      || (!renderer && !image.frame);
    divider.hidden = !split;
    if (split) {
      originalCanvas.style.clipPath = `inset(0 ${((1 - state.splitRatio) * 100).toFixed(2)}% 0 0)`;
      positionDivider();
    } else {
      originalCanvas.style.removeProperty("clip-path");
    }

    setText(badge, original ? "SDR" : "HDR");
    badge.hidden = !hasImage || renderer?.kind !== "hdr";
    hintEl.hidden = !hasImage;
    if (!hasImage) hintEl.classList.remove("is-visible");
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
    if (!hdrDisplayQuery.matches) setCapability("SDR 屏幕 · 近似预览，导出仍是 HDR", false);
    else if (!window.isSecureContext) setCapability("HTTP 模式 · 近似预览，导出仍是 HDR", false);
    else if (!navigator.gpu) setCapability("无 WebGPU · 近似预览，导出仍是 HDR", false);
    else setCapability("HDR 能力就绪", true);
  }

  /* ── rendering ────────────────────────────────────────────────────── */

  function draw() {
    frame_ = 0;
    if (!image.source) return;
    if (renderer) {
      // `originalCanvas` owns the comparison view; keep the GPU renderer on
      // the current effect frame even while that layer is temporarily over it.
      renderer.draw(null, { original: false });
    } else {
      renderSdr(sdrCanvas, { frame: image.frame, original: false });
    }
  }

  function schedule() {
    if (!image.source) return;
    if (frame_) cancelAnimationFrame(frame_);
    frame_ = requestAnimationFrame(draw);
  }

  function showCanvas(mode) {
    hdrCanvas.hidden = mode !== "hdr" || showingOriginal();
    sdrCanvas.hidden = mode !== "sdr" || showingOriginal();
  }

  function canUseHdrRenderer() {
    return hdrDisplayQuery.matches && window.isSecureContext && Boolean(navigator.gpu);
  }

  function chooseSdrRenderer(reason, epoch = rendererGeneration, forceCpu = false) {
    if (!isCurrentRenderer(epoch) || !image.frame) return;
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
      renderer.upload(image.frame);
      showCanvas("sdr");
      setCapability(`${reason} · 近似预览，导出仍是 HDR`, false);
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
      setCapability(`${reason} · 兼容近似预览，导出仍是 HDR`, false);
    }
    syncView();
    schedule();
  }

  async function chooseRenderer(epoch = invalidateRenderer()) {
    if (!isCurrentRenderer(epoch) || !image.frame) return;

    // Look changes replace the uploaded planes, not the display technology.
    // Reusing the live renderer avoids tearing down the visible swap chain and
    // also means the HDR capability probe runs only when the renderer really
    // has to be created.  Device/display capability changes still fall through
    // to the normal destroy-and-select path below.
    const wantsHdr = canUseHdrRenderer();
    if ((wantsHdr && renderer?.kind === "hdr")
        || (!wantsHdr && renderer?.kind === "sdr-gpu")) {
      renderer.upload(image.frame);
      showCanvas(wantsHdr ? "hdr" : "sdr");
      syncView();
      schedule();
      return;
    }

    renderer?.destroy();
    renderer = null;

    if (!wantsHdr && !hdrDisplayQuery.matches) {
      chooseSdrRenderer("当前屏幕为 SDR", epoch);
    } else if (!wantsHdr && !window.isSecureContext) {
      chooseSdrRenderer("HTTP 模式", epoch);
    } else if (!wantsHdr && !navigator.gpu) {
      chooseSdrRenderer("当前浏览器没有可用的 WebGPU", epoch);
    } else {
      let created = null;
      try {
        created = await createHdrRenderer(hdrCanvas, () => {
          if (isCurrentRenderer(epoch) && renderer === created) {
            chooseSdrRenderer("HDR 图形设备已断开", epoch);
          }
        });
        if (!isCurrentRenderer(epoch) || !image.frame) { created.destroy(); return; }
        renderer = created;
        renderer.upload(image.frame);
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
    Object.assign(image, {
      source: null,
      frame: null,
      original: null,
      previewRequestEdge: 0,
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

  async function load({ resetOriginal = false } = {}) {
    const sessionId = store.get().sessionId;
    const epoch = invalidateImage();
    if (!sessionId) { clear(); reportInitialCapability(); return; }
    setText(emptyTitle, "正在生成可调节预览…");

    try {
      const state = store.get();
      const requestedEdge = previewTier();
      const preview = await api.preview(sessionId, {
        options: {
          ...toOptions(state),
          useModel: Boolean(state.previewOptimized),
        },
        highlightRecovery: state.highlightRecovery,
        maxEdge: requestedEdge,
      });
      if (!isCurrentImage(epoch)) return;
      const { width, height } = preview;
      image.frame = preview;
      // Diagnostics receive an SDR display copy. Preview rendering consumes
      // only the untouched native float planes above.
      image.source = planeToImageData(preview.base, width, height);
      if (resetOriginal || !image.original) {
        image.original = planeToImageData(preview.base, width, height);
      }
      image.previewRequestEdge = requestedEdge || Math.max(width, height);
      notifySource();

      for (const canvas of [sdrCanvas, hdrCanvas]) {
        canvas.width = width;
        canvas.height = height;
      }
      // Keep the comparison layer at the dimensions of the first frame. CSS
      // scales it to the current stage, so a later high-resolution preview
      // tier cannot replace the cached original with a brightened frame.
      originalCanvas.width = image.original.width;
      originalCanvas.height = image.original.height;
      const originalContext = originalCanvas.getContext(
        "2d", { colorSpace: "display-p3" }) || originalCanvas.getContext("2d");
      originalContext.putImageData(image.original, 0, 0);
      // Scope statistics use the untouched native linear planes. The 8-bit
      // image copy remains only for the original comparison canvas and zebra
      // presentation; folding HDR through a display shoulder here destroyed
      // the very highlight distribution the graph is meant to show.
      analysis.current = analyse(
        image.source, null, preview,
        Math.max(1, 2 ** Number(store.get().hdrRange || 0)));

      empty.style.display = "none";
      stage.classList.add("has-image");
      fitStageToImage();
      stage.setAttribute("role", "button");
      stage.tabIndex = 0;
      store.set({ comparing: false });
      refreshScope();
      flashHint();
      if (preview.metadata.status === "degraded") {
        const reasons = (preview.metadata.degradationReasons || []).join(", ");
        toast(`预览已降级：${reasons || "原生 HDR 解码失败"}`, true);
      }
      await chooseRenderer();
    } catch (error) {
      if (!isCurrentImage(epoch)) return;
      // A newer slider event may have cancelled this decode, or another
      // legitimate conversion may temporarily own the RAW budget. Neither is
      // a bad image and neither should flash the destructive red error toast.
      if (error.status === 499) return;
      if (error.status === 503) {
        toast("预览正在切换，请稍候。");
        return;
      }
      const message = error.message || "无法载入预览。";
      if (error.status === 404) {
        clear(message);
        return;
      }
      // A model artifact can disappear after a server restart or cleanup.
      // Fall back to the mathematical frame; the state change schedules that
      // reload while this catch keeps the last valid pixels visible.
      if (error.status === 409 && store.get().previewOptimized) {
        modelGain = null;
        analysis.modelGain = null;
        store.set({ previewOptimized: false, modelGainReady: false });
      }
      if (!image.frame) {
        clear(message);
        return;
      }
      toast(message, true);
    }
  }

  const upload = createUploader({
    onProgress: (fraction) => {
      const percent = Math.round(fraction * 100);
      progressBar.style.width = `${percent}%`;
      setText(progressText, fraction > 0 && fraction < 1 ? `上传中 · ${percent}%` : "");
      setText(uploadOverlayText, `上传中 · ${percent}%`);
    },
    onReady: async () => {
      modelGain = null;
      analysis.modelGain = null;
      image.original = null;
      store.set({
        previewOptimized: false, modelGainReady: false, optimizing: false,
      });
      await load({ resetOriginal: true });
    },
    onError: (message, { preserveCurrent, cancelled } = {}) => {
      // A user-aborted upload is a confirmation, not a failure: keep the
      // current image (or the plain empty state) and say so quietly.
      if (cancelled) {
        if (!preserveCurrent) clear();
        toast(message);
        return;
      }
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
    upload.start(event.target.files);
    fileInput.value = "";
  });
  uploadCancel.addEventListener("click", (event) => {
    event.stopPropagation();
    upload.abort();
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
    if (canReplace() && event.dataTransfer.files.length) upload.start(event.dataTransfer.files);
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
    uploadOverlay.hidden = !state.uploading;
  });
  let nativeReloadTimer = 0;
  store.watchAny(
    ["brightness", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage",
     "encoding", "contrast", "vibrance", "previewOptimized", "modelStrength"],
    () => {
      if (!store.get().sessionId) return;
      clearTimeout(nativeReloadTimer);
      nativeReloadTimer = setTimeout(load, 120);
    },
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
    image.original = null;
    store.set({ previewOptimized: false, modelGainReady: false });
    if (store.get().sessionId) load({ resetOriginal: true });
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
      toast("AI 优化已应用");
    } catch (error) {
      modelGain = null;
      analysis.modelGain = null;
      store.set({ previewOptimized: false, modelGainReady: false });
      toast(error.message || "AI 优化失败。", true);
    } finally {
      store.set({ optimizing: false });
    }
  }

  mathModeButton.addEventListener("click", () => {
    if (!store.get().optimizing) store.set({ previewOptimized: false });
  });
  optimizeButton.addEventListener("click", optimize);
  const optimizeNote = role("optimize-note");
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
      setText(optimizeButton, state.optimizing ? "优化中…" : "AI 优化");
      optimizeButton.title = state.previewOptimized
        ? "当前正在显示 AI 优化效果"
        : state.modelGainReady
        ? "切换到已缓存的 AI 优化效果"
        : ready ? "用 AI 模型分析当前图片，自动生成增益图"
        : (state.capabilities?.model?.reason || "模型尚未就绪");
      // The disabled button's title is unreachable on touch, so the reason
      // the AI mode cannot be used is also printed under the toggle.
      const unavailable = Boolean(state.file) && !state.previewOptimized
        && !state.modelGainReady && !ready;
      optimizeNote.hidden = !unavailable;
      if (unavailable) {
        setText(optimizeNote,
          `AI 优化不可用：${state.capabilities?.model?.reason || "模型尚未就绪"}，当前为手动参数预览。`);
      }
    },
    { immediate: true },
  );

  hdrDisplayQuery.addEventListener?.("change", () => {
    reportInitialCapability();
    if (image.source) chooseRenderer();
  });

  const applyPointerHint = () => {
    const text = touchQuery.matches ? TOUCH_HINT : MOUSE_HINT;
    stage.setAttribute("aria-label", text);
    setText(hintEl, text);
  };

  /* Touch users get no hover, so the hint is flashed once when an image
   * lands; desktop users see it whenever the pointer is over the stage. */
  let hintTimer = 0;
  function flashHint() {
    if (!touchQuery.matches || !image.source) return;
    hintEl.classList.add("is-visible");
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => hintEl.classList.remove("is-visible"), 4000);
  }
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
    getFrame: () => image.frame,
    onSourceChange(listener) {
      sourceListeners.add(listener);
      return () => sourceListeners.delete(listener);
    },
  };
}
