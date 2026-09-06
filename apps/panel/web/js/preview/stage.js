/* The preview stage: file intake, gestures, renderer selection, and the wipe.
 *
 * The stage owns the decoded image and nothing else does. Renderers are chosen
 * once per image and swapped wholesale, so the fallback path never has to ask
 * whether a GPU device happens to exist right now.
 *
 * Press-and-hold compares against the source on desktop.
 */

import { api } from "../core/api.js";
import { store } from "../core/store.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { prefs, previewCeilingPx } from "../ui/prefs-schema.js";
import { role, setText, clamp } from "../core/dom.js";
import { mobileLayout, touchQuery } from "../core/media.js";
import { renderSdr, planeToImageData } from "./cpu.js";
import { createHdrRenderer } from "./gpu.js";
import { createSdrGpuRenderer } from "./sdr-gpu.js";
import { analyse, mountScope } from "./scope.js";
import { createUploader } from "./session.js";
import { AI_POST_KEYS, defaultSettings, toOptions } from "../settings/schema.js";

const hdrDisplayQuery = window.matchMedia("(dynamic-range: high)");

/* Preview sizes are quantised so a continuous "how wide is the stage right now"
 * does not create a new native frame on every window drag. Three tiers cover
 * phone to desktop, clamped to what the server says it can decode. */
const PREVIEW_TIERS = [960, 1280, 2048];
const PREVIEW_RELOAD_DELAY_MS = 240;

/* Shown on the photograph itself (see .stage-hint), so the gestures are
 * discoverable by sighted users too -- an aria-label alone only speaks to
 * screen readers. */
const TOUCH_HINT = "stage.hintTouch";
const MOUSE_HINT = "stage.hintMouse";
const INPUT_DOMAIN_LABELS = Object.freeze({
  "display-referred-hdr": "stage.input.hdr",
  "display-referred-sdr": "stage.input.sdr",
  "scene-referred": "stage.input.scene",
  unknown: "stage.input.unknown",
});

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
  const supportHint = role("stage-support");
  const divider = role("divider");
  const hdrCanvas = role("canvas-hdr");
  const originalCanvas = role("canvas-original");
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
  let sourceDomainLabel = "";

  const isCurrentImage = (epoch) => epoch === imageGeneration;
  const invalidateImage = () => ++imageGeneration;
  const isCurrentRenderer = (epoch) => epoch === rendererGeneration;
  const invalidateRenderer = () => ++rendererGeneration;

  const showingOriginal = () => {
    const state = store.get();
    return state.viewMode === "original" || Boolean(state.comparing);
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

  // Keep the comparison pixels independent from look reloads, while matching
  // the intrinsic canvas size of the current native frame. Preview tiers can
  // change when the stage is expanded, so the first cached ImageData may not
  // have the same dimensions as the new HDR plane.
  function paintOriginal(width, height) {
    originalCanvas.width = width;
    originalCanvas.height = height;
    const context = originalCanvas.getContext(
      "2d", { colorSpace: "display-p3" }) || originalCanvas.getContext("2d");
    if (image.original.width === width && image.original.height === height) {
      context.putImageData(image.original, 0, 0);
      return;
    }
    const sourceCanvas = document.createElement("canvas");
    sourceCanvas.width = image.original.width;
    sourceCanvas.height = image.original.height;
    const sourceContext = sourceCanvas.getContext(
      "2d", { colorSpace: "display-p3" }) || sourceCanvas.getContext("2d");
    sourceContext.putImageData(image.original, 0, 0);
    context.imageSmoothingEnabled = true;
    context.drawImage(sourceCanvas, 0, 0, width, height);
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

    setText(badge, original ? t("stage.badgeOriginal")
      : renderer?.kind === "hdr" ? "HDR" : t("stage.badgeSdr"));
    badge.hidden = !hasImage || renderer?.kind !== "hdr";
    badge.title = original
      ? t("stage.titleOriginal")
      : t("stage.titleHdr");
    hdrStatus.hidden = !hasImage;
    hintEl.hidden = !hasImage;
    if (!hasImage) hintEl.classList.remove("is-visible");
    stage.classList.toggle("is-comparing", original);
    stage.setAttribute("aria-pressed", String(original));
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

  let lastCapability = null;

  function setCapability(key, ok, params) {
    lastCapability = { key, ok, params };
    const message = t(key, params);
    const domain = sourceDomainLabel ? t(sourceDomainLabel) : "";
    setText(hdrStatus, domain ? `${domain} · ${message}` : message);
    hdrStatus.classList.toggle("is-ok", Boolean(ok));
    hdrStatus.hidden = !Boolean(image.source);
    stage.dataset.previewMode = renderer?.kind || "uninitialized";
  }

  function reportInitialCapability() {
    if (!prefs.get().hdrPreview) setCapability("hdr.disabled", false);
    else if (!hdrDisplayQuery.matches) setCapability("hdr.sdrScreen", false);
    else if (!window.isSecureContext) setCapability("hdr.httpMode", false);
    else if (!navigator.gpu) setCapability("hdr.noWebgpu", false);
    else setCapability("hdr.waiting", false);
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

  function prepareHdrCanvas() {
    // Let the visible stage establish its clip before WebGPU creates the
    // swap chain. This matters on Chromium when the canvas can become a
    // DirectComposition overlay.
    hdrCanvas.hidden = false;
    sdrCanvas.hidden = true;
    return new Promise((resolve) => requestAnimationFrame(resolve));
  }

  /** Why the true-HDR path is unavailable, or "" when it is available.
   *
   *  One function so the branch that picks the renderer, the branch that reuses
   *  it, and the status line can never disagree about the reason -- the
   *  diagnostics group reports this string, and "SDR preview" with no cause was
   *  the least useful thing it could say.
   */
  function sdrReason() {
    // The preference is a hard veto, not a hint: someone who turned true HDR
    // off wants the SDR path even on hardware that could do better.
    if (!prefs.get().hdrPreview) return "hdr.reason.disabledByPreference";
    if (!hdrDisplayQuery.matches) return "hdr.reason.sdrScreen";
    if (!window.isSecureContext) return "hdr.reason.httpMode";
    if (!navigator.gpu) return "hdr.reason.noWebgpu";
    return "";
  }

  const canUseHdrRenderer = () => sdrReason() === "";

  function chooseSdrRenderer(reason, epoch = rendererGeneration, forceCpu = false) {
    if (!isCurrentRenderer(epoch) || !image.frame) return;
    renderer?.destroy();
    renderer = null;
    try {
      if (forceCpu) throw new Error("WebGL context lost");
      let created = null;
      created = createSdrGpuRenderer(sdrCanvas, () => {
        if (isCurrentRenderer(epoch) && renderer === created) {
          chooseSdrRenderer("hdr.reason.sdrDeviceLost", epoch, true);
        }
      });
      renderer = created;
      renderer.upload(image.frame);
      showCanvas("sdr");
      setCapability("hdr.sdrPreviewWhy", false, { reason: t(reason) });
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
      setCapability("hdr.sdrCompatWhy", false, { reason: t(reason) });
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
      if (wantsHdr) {
        const gamut = renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } else {
        const reason = sdrReason();
        if (reason) setCapability("hdr.sdrPreviewWhy", false, { reason: t(reason) });
        else setCapability("hdr.sdrPreview", false);
      }
      syncView();
      schedule();
      return;
    }

    renderer?.destroy();
    renderer = null;

    const blocked = sdrReason();
    if (blocked) {
      chooseSdrRenderer(blocked, epoch);
    } else {
      let created = null;
      setCapability("hdr.verifying", false);
      try {
        await prepareHdrCanvas();
        if (!isCurrentRenderer(epoch) || !image.frame) return;
        created = await createHdrRenderer(hdrCanvas, () => {
          if (isCurrentRenderer(epoch) && renderer === created) {
            chooseSdrRenderer("hdr.reason.deviceLost", epoch);
          }
        });
        if (!isCurrentRenderer(epoch) || !image.frame) { created.destroy(); return; }
        renderer = created;
        renderer.upload(image.frame);
        showCanvas("hdr");
        const gamut = renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } catch (error) {
        created?.destroy();
        if (!isCurrentRenderer(epoch)) return;
        const detail = error?.message ? `: ${error.message}` : "";
        console.error("HyperDR HDR renderer initialization failed", error);
        chooseSdrRenderer(t("hdr.reason.initFailed", { detail }), epoch);
      }
    }
    if (!isCurrentRenderer(epoch)) return;
    syncView();
    schedule();
  }

  /* ── loading ──────────────────────────────────────────────────────── */

  function previewTier() {
    const served = Number(store.get().capabilities?.previewMaxEdge);
    // Before /api/state resolves, let the server apply its configured maximum.
    if (!Number.isFinite(served) || served <= 0) return null;
    // The preference can only lower the ceiling: raising it past what the
    // server will decode would just produce a rejected request.
    const ceiling = Math.min(served, previewCeilingPx());
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
    expandButton.setAttribute("aria-label",
      expanded ? t("stage.collapse") : t("stage.expand"));

    if (!expanded) {
      if (exitNative && document.fullscreenElement === viewport) {
        document.exitFullscreen?.().catch(() => {});
      }
      fitStageToImage();
      positionDivider();
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
      positionDivider();
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

  function clear(message = t("stage.empty")) {
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
    sourceDomainLabel = "";
    modelGain = null;
    analysis.modelGain = null;
    store.set({
      comparing: false, maskKey: null,
      previewReady: false,
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
    reportInitialCapability();
    refreshScope();
    syncView();
  }

  async function load({ resetOriginal = false } = {}) {
    clearTimeout(nativeReloadTimer);
    const sessionId = store.get().sessionId;
    const epoch = invalidateImage();
    if (!sessionId) { clear(); reportInitialCapability(); return; }
    setText(emptyTitle, t("stage.generating"));

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
      sourceDomainLabel = INPUT_DOMAIN_LABELS[preview.metadata.inputDomain]
        || INPUT_DOMAIN_LABELS.unknown;
      setCapability("hdr.verifyingOutput", false);
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
      // The comparison content remains the first frame, but its canvas is
      // resampled to the current frame size so original and HDR share one
      // intrinsic resolution at every preview tier.
      paintOriginal(width, height);
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
        toast(t("hdr.degraded", { reasons: reasons || t("hdr.degradedFallback") }), true);
      }
      await chooseRenderer();
      if (isCurrentImage(epoch)) store.set({ previewReady: true });
    } catch (error) {
      if (!isCurrentImage(epoch)) return;
      // A newer slider event may have cancelled this decode, or another
      // legitimate conversion may temporarily own the RAW budget. Neither is
      // a bad image and neither should flash the destructive red error toast.
      if (error.status === 499) return;
      store.set({ previewReady: false });
      if (error.status === 503) {
        toast(t("err.previewSwitching"));
        return;
      }
      const message = error.message || t("err.preview");
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
      const uploading = t("stage.uploading", { percent });
      setText(progressText, fraction > 0 && fraction < 1 ? uploading : "");
      setText(uploadOverlayText, uploading);
    },
    onReady: async () => {
      modelGain = null;
      analysis.modelGain = null;
      image.original = null;
      const activeGamut = store.get().colorGamut;
      store.set({
        // All image adjustments are image-scoped. Do not carry a previous
        // photograph's grade into a newly uploaded image. Keep the selected
        // output format, which is a workflow choice rather than a grade.
        ...(prefs.get().rememberAdjustments ? {} : defaultSettings(store.get().encoding)),
        colorGamut: activeGamut,
        clampSrgb: activeGamut === "srgb" ? true : store.get().clampSrgb,
        previewReady: false,
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
    return !state.restoring && !state.starting && !state.uploading && !state.optimizing && !state.jobId;
  };
  const nativeDropQueueKey = "__HYPERDR_NATIVE_FILE_DROPS__";
  const consumeNativeDrop = () => {
    const queued = globalThis[nativeDropQueueKey];
    const capabilities = store.get().capabilities;
    // Keep a native drop queued until the boot capability request completes;
    // otherwise a very quick drop after launch would be mistaken for a browser
    // page that does not support the desktop bridge.
    if (!Array.isArray(queued) || !capabilities || store.get().restoring) return;
    globalThis[nativeDropQueueKey] = [];
    if (!canReplace() || !capabilities.nativePathInput) return;
    const path = queued.find((value) => typeof value === "string" && value);
    if (path) upload.startNativePath(path);
  };
  // Rust queues before dispatching, so this also handles a drop that arrived
  // during panel initialization.
  window.addEventListener("hyperdr:native-file-drop", consumeNativeDrop);
  store.watchAny(["capabilities", "restoring"], consumeNativeDrop);
  consumeNativeDrop();
  /* What the picker offers and what the hint promises both come from the
   * converter's own extension table, served in /api/state. The markup used to
   * carry a hand-written accept list -- the fifth copy of that list in the
   * project, and the one most likely to be forgotten. */
  const describeSupport = () => {
    const capabilities = store.get().capabilities;
    const extensions = capabilities?.inputExtensions;
    if (!Array.isArray(extensions) || !extensions.length) return;
    fileInput.accept = ["image/*", ...extensions].join(",");
    setText(supportHint, t("stage.support"));
    supportHint.title = extensions.join(" ");
  };
  store.watch("capabilities", describeSupport);
  describeSupport();

  /* One image per session, so a multiple selection is not an error -- but it is
   * not what the user asked for either, and silently keeping the first of five
   * files reads as the panel losing four of them. */
  const startUpload = (files) => {
    const list = Array.from(files || []);
    if (!list.length) return false;
    if (list.length > 1) {
      toast(t("err.oneFile", { name: list[0].name }));
    }
    upload.start(list);
    return true;
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
    startUpload(event.target.files);
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
    if (!canReplace()) return;
    // A folder, a link or a text selection arrives with no files at all. Doing
    // nothing at that point looks like the drop was missed rather than refused.
    if (!startUpload(event.dataTransfer.files)) {
      toast(t("err.singleFileDrop"), true);
    }
  });

  /* Pasting is the sibling of dropping and was simply missing: a screenshot on
   * the clipboard had to be saved to disk first. Ignored while a text field has
   * focus, so pasting into an input still pastes text. */
  document.addEventListener("paste", (event) => {
    const target = event.target;
    if (target instanceof Element
        && target.closest("input, textarea, [contenteditable]")) return;
    const files = Array.from(event.clipboardData?.files || []);
    if (!files.length || !canReplace()) return;
    event.preventDefault();
    startUpload(files);
  });

  stage.addEventListener("contextmenu", (event) => { if (image.source) event.preventDefault(); });
  stage.addEventListener("selectstart", (event) => {
    if (touchQuery.matches) event.preventDefault();
  });
  stage.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && expanded) {
      event.preventDefault();
      updateExpandedState(false);
    } else if (event.target === stage && event.key === "Enter" && !event.repeat) {
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
     "encoding", "contrast", "vibrance", "previewOptimized", "modelStrength",
     "colorGamut", "clampSrgb",
     ...AI_POST_KEYS],
    (state, _previous, changed) => {
      if (!state.sessionId || state.restoring || state.uploading) return;
      // AI post controls are independent from the mathematical mode. A hidden
      // value change must not cause a native decode while the manual preview
      // is active; once AI is selected the same controls invalidate its frame.
      if (!state.previewOptimized
          && changed.length > 0
          && changed.every((key) => AI_POST_KEYS.includes(key))) return;
      clearTimeout(nativeReloadTimer);
      nativeReloadTimer = setTimeout(load, PREVIEW_RELOAD_DELAY_MS);
    },
    { immediate: true });

  /* Every other control acts on the decoded pixels the browser already holds,
   * so a redraw is enough. Highlight recovery acts *during* the RAW decode, so
   * the pixels themselves are stale and the preview has to be fetched again. */
  store.subscribe((state, _previous, changed) => {
    if (!changed.includes("highlightRecovery")) return;
    modelGain = null;
    analysis.modelGain = null;
    image.original = null;
    store.set({ modelGainReady: false,
      ...(!changed.includes("previewOptimized") && !state.restoring
        ? { previewOptimized: false } : {}),
    });
    if (state.sessionId && !state.restoring && !state.uploading) load({ resetOriginal: true });
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
      toast(t("adjust.aiApplied"));
    } catch (error) {
      modelGain = null;
      analysis.modelGain = null;
      store.set({ previewOptimized: false, modelGainReady: false });
      toast(error.message || t("adjust.aiFailed"), true);
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
      setText(optimizeButton, state.optimizing ? t("adjust.aiBusy") : t("adjust.ai"));
      optimizeButton.title = state.previewOptimized
        ? t("adjust.aiShowing")
        : state.modelGainReady
        ? t("adjust.aiCached")
        : ready ? t("adjust.aiReady")
        : (state.capabilities?.model?.reason || t("adjust.aiNotReady"));
      // The disabled button's title is unreachable on touch, so the reason
      // the AI mode cannot be used is also printed under the toggle.
      const unavailable = Boolean(state.file) && !state.previewOptimized
        && !state.modelGainReady && !ready;
      optimizeNote.hidden = !unavailable;
      if (unavailable) {
        setText(optimizeNote,
          t("adjust.aiUnavailable", {
            reason: state.capabilities?.model?.reason || t("adjust.aiNotReady"),
          }));
      }
    },
    { immediate: true },
  );

  hdrDisplayQuery.addEventListener?.("change", () => {
    reportInitialCapability();
    if (image.source) chooseRenderer();
  });

  const applyPointerHint = () => {
    const text = t(touchQuery.matches ? TOUCH_HINT : MOUSE_HINT);
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

  /* Preference reactions.
   *
   * Turning true HDR off has to re-pick the renderer, not merely relabel the
   * status line: the WebGPU context is chosen once per image and would keep
   * painting until the next load. Narrowing the resolution cap re-requests the
   * frame at the new tier, which is what `load` does when the tier moves. */
  prefs.watch("hdrPreview", () => {
    reportInitialCapability();
    if (image.source) chooseRenderer();
  });
  prefs.watch("previewCeiling", () => {
    if (image.source) load();
  });

  /* Nothing here re-renders on its own, so a language change re-emits the
   * strings this module wrote imperatively. `lastCapability` is kept as a key
   * plus parameters precisely so this does not have to re-probe the GPU. */
  onLocaleChange(() => {
    applyPointerHint();
    syncView();
    if (lastCapability) {
      setCapability(lastCapability.key, lastCapability.ok, lastCapability.params);
    }
    if (!image.source) setText(emptyTitle, t("stage.empty"));
    setText(supportHint, t("stage.support"));
    expandButton.setAttribute("aria-label",
      expanded ? t("stage.collapse") : t("stage.expand"));
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
