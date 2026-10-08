/* The preview stage: file intake, gestures, renderer selection, and the wipe.
 *
 * The stage owns the decoded image and nothing else does. Renderers are chosen
 * once per image and swapped wholesale, so the fallback path never has to ask
 * whether a GPU device happens to exist right now.
 *
 * Press-and-hold compares against the source on desktop.
 */
import { mountScope } from "./scope.js";
import { store } from "../core/store.js";
import { createStageContext } from "./stage/context.js";

import { api } from "../core/api.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { prefs, previewCeilingPx } from "../ui/prefs-schema.js";
import { role, setText, clamp } from "../core/dom.js";
import { touchQuery } from "../core/media.js";
import { renderSdr, planeToImageData } from "./cpu.js";
import { createHdrRenderer } from "./gpu.js";
import { createSdrGpuRenderer } from "./sdr-gpu.js";
import { createPreviewScheduler } from "./scheduler.js";
import { diagnosticFrame } from "./packet.js";
import { analyse } from "./scope.js";
import { histogramFromPlane } from "./histogram.js";
import { createUploader } from "./session.js";
import { pickInputFile } from "./file-picker.js";
import {
  AI_POST_KEYS, CONTROLS, defaultSettings, effectiveOutputGamut, isHdrSource, referenceSettings, toOptions,
} from "../settings/schema.js";
import { fallbackFields, modelLabel } from "../settings/model-select.js";
import { createDetail, createDetailElements } from "./stage/detail.js";
import { createView } from "./stage/view.js";

export function mountStage({ toast }) {
  const ctx = createStageContext({ toast });
  createDetailElements(ctx);
  ctx.refreshScope = mountScope({ analysis: ctx.analysis });

  // All collaborators share this mount's context. Wire their calls before any
  // immediate store subscription or native drop can start loading a photo.
  const detail = ctx.actions.detail = createDetail(ctx);
  const view = ctx.actions.view = createView(ctx);
  const rendering = ctx.actions.rendering = createRendering(ctx);
  const photo = ctx.actions.photo = createPhoto(ctx);
  const intake = ctx.actions.intake = createIntake(ctx);
  const gestures = ctx.actions.gestures = createGestures(ctx);
  const optimization = ctx.actions.optimization = createOptimization(ctx);

  // Keep listener/subscription order: pan and detail consume pointer events
  // before the press-and-hold gesture, and settings coalesce before AI invalidation.
  view.mountGeometry();
  detail.mountResize();
  view.mountPan();
  detail.mountInteractions();
  intake.mountNativeDrop();
  intake.mountSupport();
  intake.mountPicker();
  gestures.mountPointer();
  intake.mountDrop();
  gestures.mountKeyboard();
  view.mountWheel();
  rendering.mountReactions();
  view.mountReactions();
  intake.mountReactions();
  photo.mountScheduler();
  optimization.mountModelChange();
  optimization.mountControls();
  rendering.mountDisplay();
  gestures.mountPointerHint();
  rendering.mountPreference();
  photo.mountPreference();

  optimization.mountLocale();
  gestures.mountLocale();
  view.mountLocale();
  rendering.mountLocale();
  photo.mountLocale();
  intake.mountLocale();
  detail.mountLocale();
  gestures.applyPointerHint();
  rendering.reportInitialCapability();

  return {
    openPicker: intake.openPicker,
    redraw: rendering.schedule,
    reload: photo.load,
    async acceptPhonePhoto(current) {
      store.set({ restoring: true, uploading: true, phoneUploading: false,
        sessionId: current.sessionId, file: current.file, result: null, exports: [] });
      try { await photo.preparePhoto(); }
      finally { store.set({ restoring: false, uploading: false }); }
    },
    clear: photo.clear,
    /** The decoded preview pixels, for the mask overlay. Null before upload. */
    getSource: () => ctx.image.source,
    getFrame: () => ctx.image.frame,
    onSourceChange(listener) {
      ctx.sourceListeners.add(listener);
      return () => ctx.sourceListeners.delete(listener);
    },
  };
}

/* Select, replace and report the HDR / SDR GPU / CPU presentation path. */


function createRendering(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage, hdrStatus, hdrCanvas } = ctx.dom;

  const { hdrDisplayQuery } = ctx;

  /* ── capability reporting ─────────────────────────────────────────── */


  function setCapability(key, ok, params) {
    ctx.lastCapability = { key, ok, params };
    const state = store.get();
    const format = state.encoding === "sdr-tiff" ? "TIFF" : "JPEG";
    const gamut = effectiveOutputGamut(state.encoding, state.outputGamut) === "p3" ? "Display P3" : "sRGB";
    const message = ["sdr-jpeg", "sdr-tiff"].includes(state.encoding) ? t("hdr.sdrOutput", { format, gamut })
      : t(key, params?.reasonKey ? { ...params, reason: t(params.reasonKey) } : params);
    const domain = ctx.sourceDomainLabel ? t(ctx.sourceDomainLabel) : "";
    setText(hdrStatus, domain ? `${domain} · ${message}` : message);
    hdrStatus.classList.toggle("is-ok", Boolean(ok));
    hdrStatus.hidden = !Boolean(image.source);
    stage.dataset.previewMode = ctx.renderer?.kind || "uninitialized";
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
    ctx.animationFrame = 0;
    if (!image.source) return;
    if (ctx.renderer) {
      // `originalCanvas` owns the comparison view; keep the GPU renderer on
      // the current effect frame even while that layer is temporarily over it.
      renderer.draw(null, { original: false });
    } else {
      renderSdr(ctx.dom.sdrCanvas, { frame: image.frame, original: false });
    }
  }

  function schedule() {
    if (!image.source) return;
    if (ctx.animationFrame) cancelAnimationFrame(ctx.animationFrame);
    ctx.animationFrame = requestAnimationFrame(draw);
  }

  function showCanvas(mode) {
    hdrCanvas.hidden = mode !== "hdr" || actions.view.showingOriginal();
    ctx.dom.sdrCanvas.hidden = mode !== "sdr" || actions.view.showingOriginal();
  }

  function prepareHdrCanvas() {
    // Let the visible stage establish its clip before WebGPU creates the
    // swap chain. This matters on Chromium when the canvas can become a
    // DirectComposition overlay.
    hdrCanvas.hidden = false;
    ctx.dom.sdrCanvas.hidden = true;
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
    if (["sdr-jpeg", "sdr-tiff"].includes(store.get().encoding)) return "hdr.reason.sdrOutput";
    // The preference is a hard veto, not a hint: someone who turned true HDR
    // off wants the SDR path even on hardware that could do better.
    if (!prefs.get().hdrPreview) return "hdr.reason.disabledByPreference";
    if (!hdrDisplayQuery.matches) return "hdr.reason.sdrScreen";
    if (!window.isSecureContext) return "hdr.reason.httpMode";
    if (!navigator.gpu) return "hdr.reason.noWebgpu";
    return "";
  }

  const canUseHdrRenderer = () => sdrReason() === "";

  function chooseSdrRenderer(reason, epoch = ctx.rendererGeneration, forceCpu = false) {
    if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;
    ctx.renderer?.destroy();
    ctx.renderer = null;
    try {
      if (forceCpu) throw new Error("WebGL context lost");
      let created = null;
      created = createSdrGpuRenderer(ctx.dom.sdrCanvas, () => {
        if (ctx.isCurrentRenderer(epoch) && ctx.renderer === created) {
          chooseSdrRenderer("hdr.reason.sdrDeviceLost", epoch, true);
        }
      });
      ctx.renderer = created;
      ctx.renderer.upload(image.frame);
      showCanvas("sdr");
      setCapability("hdr.sdrPreviewWhy", false, { reasonKey: reason });
    } catch (error) {
      ctx.renderer = null;
      // A canvas that has successfully created a WebGL context cannot later
      // switch to 2D. Replace it before entering the last-resort CPU path if
      // WebGL setup failed after context creation.
      const replacement = ctx.dom.sdrCanvas.cloneNode(false);
      replacement.width = ctx.dom.sdrCanvas.width;
      replacement.height = ctx.dom.sdrCanvas.height;
      ctx.dom.sdrCanvas.replaceWith(replacement);
      ctx.dom.sdrCanvas = replacement;
      showCanvas("sdr");
      setCapability("hdr.sdrCompatWhy", false, { reasonKey: reason });
    }
    actions.view.syncView();
    schedule();
  }

  async function chooseRenderer(epoch = ctx.invalidateRenderer()) {
    if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;

    // Look changes replace the uploaded planes, not the display technology.
    // Reusing the live renderer avoids tearing down the visible swap chain and
    // also means the HDR capability probe runs only when the renderer really
    // has to be created.  Device/display capability changes still fall through
    // to the normal destroy-and-select path below.
    const wantsHdr = canUseHdrRenderer();
    if ((wantsHdr && ctx.renderer?.kind === "hdr")
        || (!wantsHdr && ctx.renderer?.kind === "sdr-gpu")) {
      ctx.renderer.upload(image.frame);
      showCanvas(wantsHdr ? "hdr" : "sdr");
      if (wantsHdr) {
        const gamut = ctx.renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } else {
        const reason = sdrReason();
        if (reason) setCapability("hdr.sdrPreviewWhy", false, { reasonKey: reason });
        else setCapability("hdr.sdrPreview", false);
      }
      actions.view.syncView();
      schedule();
      return;
    }

    ctx.renderer?.destroy();
    ctx.renderer = null;

    const blocked = sdrReason();
    if (blocked) {
      chooseSdrRenderer(blocked, epoch);
    } else {
      let created = null;
      setCapability("hdr.verifying", false);
      try {
        await prepareHdrCanvas();
        if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;
        created = await createHdrRenderer(hdrCanvas, () => {
          if (ctx.isCurrentRenderer(epoch) && ctx.renderer === created) {
            chooseSdrRenderer("hdr.reason.deviceLost", epoch);
          }
        });
        if (!ctx.isCurrentRenderer(epoch) || !image.frame) { created.destroy(); return; }
        ctx.renderer = created;
        ctx.renderer.upload(image.frame);
        showCanvas("hdr");
        const gamut = ctx.renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } catch (error) {
        created?.destroy();
        if (!ctx.isCurrentRenderer(epoch)) return;
        const detail = error?.message ? `: ${error.message}` : "";
        console.error("HyperDR HDR renderer initialization failed", error);
        chooseSdrRenderer(t("hdr.reason.initFailed", { detail }), epoch);
      }
    }
    if (!ctx.isCurrentRenderer(epoch)) return;
    actions.view.syncView();
    schedule();
  }
  function mountReactions() {
    store.watchAny(["encoding", "outputGamut"], () => {
      if (ctx.lastCapability) setCapability(ctx.lastCapability.key, ctx.lastCapability.ok, ctx.lastCapability.params);
    });
  }

  function mountDisplay() {
    hdrDisplayQuery.addEventListener?.("change", () => {
      reportInitialCapability();
      if (image.source) chooseRenderer();
    });
  }

  function mountPreference() {
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
  }

  function mountLocale() {
    /* Nothing here re-renders on its own, so a language change re-emits the
     * strings this module wrote imperatively. `lastCapability` is kept as a key
     * plus parameters precisely so this does not have to re-probe the GPU. */
    onLocaleChange(() => {
      if (ctx.lastCapability) {
        setCapability(ctx.lastCapability.key, ctx.lastCapability.ok, ctx.lastCapability.params);
      }
    });
  }


  return { setCapability, reportInitialCapability, draw, schedule, showCanvas, prepareHdrCanvas, sdrReason, canUseHdrRenderer, chooseSdrRenderer, chooseRenderer, mountReactions, mountDisplay, mountPreference, mountLocale };
}

/* Load quantised preview frames, maintain the neutral reference and schedule settings changes. */


/* Preview sizes are quantised so a continuous "how wide is the stage right now"
 * does not create a new native frame on every window drag. Three tiers cover
 * phone to desktop, clamped to what the server says it can decode. */
const PREVIEW_TIERS = [960, 1280, 2048];
const DRAFT_PREVIEW_EDGE = 640;
const imageAdjustments = (settings) =>
  Object.fromEntries(CONTROLS.map(({ key }) => [key, settings[key]]));
const INPUT_DOMAIN_LABELS = Object.freeze({
  "display-referred-hdr": "stage.input.hdr",
  "dual-rendition": "stage.input.dual",
  "display-referred-sdr": "stage.input.sdr",
  "scene-referred": "stage.input.scene",
  unknown: "stage.input.unknown",
});


function createPhoto(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage, frame, viewport, empty, emptyTitle, progressBar, progressText, divider, hdrCanvas, originalCanvas } = ctx.dom;

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

  function clear(message = t("stage.empty")) {
    actions.detail.closeDetail();
    ++ctx.modelRequest;
    ctx.invalidateImage();
    ctx.invalidateRenderer();
    Object.assign(image, {
      source: null,
      frame: null,
      original: null,
      originalHistogram: null,

    });
    ctx.notifySource();
    analysis.current = null;
    ctx.renderer?.destroy();
    ctx.renderer = null;
    ctx.sourceDomainLabel = "";
    ctx.modelGain = null;
    analysis.modelGain = null;
    store.set({
      comparing: false, maskKey: null,
      viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
      rawProfile: "", rawProfileName: "", rawLook: "", rawLookName: "",
      lensCorrection: true, lensProfileName: "",
      sourceDomain: "",
      sourceUnadjusted: null,
      hasCaptureMetadata: false,
      previewReady: false,
      previewOptimized: false, modelGainReady: false, optimizing: false,
      modelIdentity: null,
    });
    stage.classList.remove("has-image", "is-comparing", "is-loading");
    actions.view.fitStageToImage();
    stage.removeAttribute("role");
    stage.removeAttribute("tabindex");
    for (const canvas of [ctx.dom.sdrCanvas, hdrCanvas, originalCanvas]) {
      canvas.hidden = true;
      canvas.width = 0;
      canvas.height = 0;
    }
    divider.hidden = true;
    empty.style.display = "flex";
    setText(emptyTitle, message);
    actions.rendering.reportInitialCapability();
    ctx.refreshScope();
    actions.view.syncView();
  }

  async function load({
    resetOriginal = false, draft = false, requestedAt = performance.now(),
    newPhoto = false, scheduled = false,
  } = {}) {
    if (newPhoto) actions.detail.closeDetail();
    if (resetOriginal && !scheduled) ctx.previewScheduler.cancel();
    if (store.get().previewOptimized && !store.get().capabilities?.model?.ready) {
      store.set({ previewOptimized: false, modelGainReady: false, modelIdentity: null });
    }
    // Restored AI views also need their actual model identity and fallback state.
    if (store.get().previewOptimized && !store.get().modelGainReady) {
      return actions.optimization.optimize({ resetOriginal, scheduled });
    }
    store.set({ previewError: false });
    const sessionId = store.get().sessionId;
    const epoch = ctx.invalidateImage();
    if (!sessionId) { clear(); actions.rendering.reportInitialCapability(); return; }
    setText(emptyTitle, t("stage.generating"));
    // The first frame of a photograph: the empty card becomes a progress
    // report. The bar is indeterminate, so the upload's percentage is cleared.
    if (!image.source) {
      stage.classList.add("is-loading");
      progressBar.style.removeProperty("width");
      setText(progressText, "");
    }

    try {
      let state = store.get();
      const referenceEdge = previewTier();
      const requestedEdge = draft ? Math.min(referenceEdge || DRAFT_PREVIEW_EDGE, DRAFT_PREVIEW_EDGE) : referenceEdge;
      const fetchStarted = performance.now();
      let reference = null;
      // Track the requested tier, not returned dimensions: small source photos
      // must not trigger another reference decode on every adjustment.
      if (resetOriginal || !image.original || (referenceEdge ?? Infinity) > image.originalEdge) {
        reference = await api.preview(sessionId, {
          options: { ...toOptions(referenceSettings(state.encoding)), colorGamut: state.colorGamut,
            outputGamut: state.outputGamut, clampSrgb: state.clampSrgb, rawProfile: state.rawProfile, rawLook: state.rawLook,
            lensCorrection: state.lensCorrection, useModel: false },
          highlightRecovery: "blend", maxEdge: referenceEdge,
        });
        if (!ctx.isCurrentImage(epoch)) return;
        const sourceDomain = reference.metadata.inputDomain || "";
        const sourceUnadjusted = reference.metadata.unadjusted || null;
        // The domain is a fact about the file, known only once the decoder has
        // read it. A newly opened HDR photograph starts from its own rendering
        // rather than from the SDR enhancement preset, so the first frame
        // below already shows the photograph and every control reads as
        // "unchanged". Remembered adjustments remain the user's explicit choice.
        // Only the image adjustments are replaced: output format, gamut and
        // model are workflow choices preparePhoto() already carried over.
        const adjustments = newPhoto && isHdrSource(sourceDomain)
          && !prefs.get().rememberAdjustments
          ? imageAdjustments(defaultSettings(state.encoding, sourceDomain, sourceUnadjusted)) : {};
        store.set({ sourceDomain, sourceUnadjusted, sourceColor: reference.metadata.sourceColor || null,
          hasCaptureMetadata: reference.metadata.hasCaptureMetadata === true, ...adjustments,
          ...(isHdrSource(sourceDomain) ? { previewOptimized: false, modelGainReady: false } : {}) });
        state = store.get();
      }
      const preview = await api.preview(sessionId, {
        options: {
          ...toOptions(state),
          useModel: Boolean(state.previewOptimized),
          modelId: state.modelId,
        },
        highlightRecovery: state.highlightRecovery,
        maxEdge: requestedEdge,
      });
      const receivedAt = performance.now();
      if (!ctx.isCurrentImage(epoch)) return;
      const { width, height } = preview;
      const diagnostic = diagnosticFrame(preview);
      const sameBase = preview.metadata.baseId && image.frame?.metadata.baseId === preview.metadata.baseId
        && image.frame.width === width && image.frame.height === height;
      image.frame = preview;
      ctx.sourceDomainLabel = INPUT_DOMAIN_LABELS[state.sourceDomain]
        || INPUT_DOMAIN_LABELS.unknown;
      // Keep the domain learned from the untouched reference. AI deliberately
      // decodes a gain-map photograph's SDR base; that frame's input domain
      // describes model input, not the original photo used by reset/export.
      setCapability("hdr.verifyingOutput", false);
      // Diagnostics receive an SDR display copy. Preview rendering consumes
      // only the untouched native float planes above.
      if (!sameBase) image.source = planeToImageData(preview.base, width, height);
      if (reference) {
        image.original = planeToImageData(reference.base, reference.width, reference.height);
        image.originalEdge = referenceEdge ?? Infinity;
        const referenceDiagnostic = diagnosticFrame(reference);
        image.originalHistogram = histogramFromPlane(referenceDiagnostic.base,
          referenceDiagnostic.width, referenceDiagnostic.height);
        actions.view.paintOriginal();
      }
      ctx.notifySource();

      for (const canvas of [ctx.dom.sdrCanvas, hdrCanvas]) {
        if (canvas.width !== width) canvas.width = width;
        if (canvas.height !== height) canvas.height = height;
      }
      // Scope statistics use the untouched native linear planes. The 8-bit
      // image copy remains only for the original comparison canvas and zebra
      // presentation; folding HDR through a display shoulder here destroyed
      // the very highlight distribution the graph is meant to show.
      analysis.current = analyse(
        planeToImageData(diagnostic.base, diagnostic.width, diagnostic.height), null, diagnostic,
        Math.max(1, 2 ** Number(preview.metadata.headroomStops ??
          (state.previewOptimized ? state.aiHdrRange : state.hdrRange) ?? 0)),
        image.originalHistogram);

      empty.style.display = "none";
      stage.classList.add("has-image");
      stage.classList.remove("is-loading");
      actions.view.fitStageToImage();
      stage.setAttribute("role", "button");
      stage.tabIndex = 0;
      store.set({ comparing: false });
      ctx.refreshScope();
      if (preview.metadata.status === "degraded") {
        const reasons = (preview.metadata.degradationReasons || []).join(", ");
        toast(t("hdr.degraded", { reasons: reasons || t("hdr.degradedFallback") }), true);
      }
      await actions.rendering.chooseRenderer();
      if (ctx.isCurrentImage(epoch)) {
        actions.view.applyZoom();
        await new Promise((resolve) => requestAnimationFrame(resolve));
        if (!ctx.isCurrentImage(epoch)) return;
        store.set({ previewReady: true, previewTiming: {
          draft, width, height,
          requestMs: receivedAt - fetchStarted,
          presentationMs: performance.now() - receivedAt,
          inputToFrameMs: performance.now() - requestedAt,
          bytes: preview.byteLength,
        } });
        if (detail.active) actions.detail.requestDetail();
      }
    } catch (error) {
      if (!ctx.isCurrentImage(epoch)) return;
      // A newer slider event may have cancelled this decode, or another
      // legitimate conversion may temporarily own the RAW budget. Neither is
      // a bad image and neither should flash the destructive red error toast.
      if (error.status === 499) return;
      store.set({ previewReady: false });
      if (error.status === 503) {
        toast(t("err.previewSwitching"));
        return;
      }
      store.set({ previewError: true });
      const message = error.message || t("err.preview");
      if (error.status === 404) {
        clear(message);
        return;
      }
      // A model-backed frame that failed leaves the last frame on screen, and
      // that frame is not the AI result. Keeping "AI 优化" selected over it
      // claimed an enhancement the photograph never received, so any failure
      // returns to the mathematical frame, which the state change reloads. A
      // model artifact that disappeared after a restart or cleanup (409) is
      // the common case, and says so.
      if (store.get().previewOptimized) {
        ctx.modelGain = null;
        analysis.modelGain = null;
        store.set({ previewOptimized: false, modelGainReady: false, modelIdentity: null });
        toast(error.status === 409 ? t("adjust.aiExpired")
          : t("adjust.aiPreviewFailed", { detail: message }), true);
        return;
      }
      if (!image.frame) {
        clear(message);
        return;
      }
      toast(message, true);
    }
  }

  async function preparePhoto() {
    ctx.modelGain = null;
    analysis.modelGain = null;
    image.original = null;
    const activeGamut = store.get().colorGamut;
    const activeOutputGamut = store.get().outputGamut;
    store.set({
      // All image adjustments are image-scoped. Do not carry a previous
      // photograph's grade into a newly uploaded image. Keep the selected
      // output format, which is a workflow choice rather than a grade.
      // An HDR photograph replaces these with its own rendering as soon as the
      // first frame names its domain; see load().
      ...(prefs.get().rememberAdjustments ? {} : defaultSettings(store.get().encoding)),
      modelId: store.get().modelId,
      colorGamut: activeGamut,
      outputGamut: activeOutputGamut,
      sourceColor: null,
      clampSrgb: store.get().clampSrgb,
      rawProfile: "", rawProfileName: "", rawLook: "", rawLookName: "",
      lensCorrection: true, lensProfileName: "",
      sourceDomain: "",
      sourceUnadjusted: null,
      hasCaptureMetadata: false,
      previewReady: false,
      viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
      previewOptimized: false, modelGainReady: false, optimizing: false,
      modelIdentity: null,
    });
    await load({ resetOriginal: true, newPhoto: true });
  }
  function mountScheduler() {
    ctx.previewScheduler = createPreviewScheduler((request) => load({ ...request, scheduled: true }));
    let interactionDirty = false;
    store.watch("sessionId", () => { ctx.previewScheduler.cancel(); interactionDirty = false; });
    store.watch("previewInteracting", (active) => {
      if (!active && interactionDirty) {
        interactionDirty = false;
        ctx.previewScheduler.request(false);
      }
    });
    store.watchAny(
      ["brightness", "hdrStrength", "hdrRange", "expansionStart", "areaCoverage",
       "encoding", "contrast", "vibrance", "previewOptimized", "modelStrength",
       "colorGamut", "outputGamut", "clampSrgb", "lutId", "lutInput", "lutOutput", "lutStrength",
       ...AI_POST_KEYS],
      (state, _previous, changed) => {
        if (!state.sessionId || state.restoring || state.uploading) return;
        // AI post controls are independent from the mathematical mode. A hidden
        // value change must not cause a native decode while the manual preview
        // is active; once AI is selected the same controls invalidate its frame.
        if (!state.previewOptimized
            && changed.length > 0
            && changed.every((key) => AI_POST_KEYS.includes(key))) return;
        interactionDirty ||= Boolean(state.previewInteracting);
        ctx.previewScheduler.request(Boolean(state.previewInteracting));
      },
      { immediate: true });

    /* Input/base options invalidate both the decoded source and model cache. */
    store.subscribe((state, _previous, changed) => {
      if (!changed.some((key) => ["highlightRecovery", "clampSrgb", "colorGamut", "outputGamut", "rawProfile", "rawLook", "lensCorrection"].includes(key))) return;
      ++ctx.modelRequest;
      ctx.modelGain = null;
      analysis.modelGain = null;
      image.original = null;
      store.set({ modelGainReady: false, modelIdentity: null, optimizing: false,
        ...(state.previewOptimized ? { previewReady: false } : {}),
      });
      if (state.sessionId && !state.restoring && !state.uploading) {
        // Discard stale results while allowing the worker's current operation
        // to finish. The scheduler then runs only the latest profile/settings.
        invalidateImage();
        ctx.previewScheduler.request(false, performance.now(), true);
      }
    });
  }

  function mountPreference() {
    prefs.watch("previewCeiling", () => {
      if (image.source) load();
    });
  }

  function mountLocale() {
    onLocaleChange(() => {
      if (!image.source) setText(emptyTitle, t("stage.empty"));
    });
  }


  return { previewTier, clear, load, preparePhoto, mountScheduler, mountPreference, mountLocale };
}

/* Accept picker, native drop, browser drop and clipboard photos through the uploader. */


function createIntake(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage, selectButton, fileInput, supportHint, uploadCancel, progressBar, progressText, uploadOverlayText, uploadOverlay, emptyTitle } = ctx.dom;

  const upload = createUploader({
    onProgress: (fraction) => {
      const percent = Math.round(fraction * 100);
      progressBar.style.width = `${percent}%`;
      const uploading = t("stage.uploading", { percent });
      setText(progressText, fraction > 0 && fraction < 1 ? uploading : "");
      setText(uploadOverlayText, uploading);
    },
    onReady: actions.photo.preparePhoto,
    onError: (message, { preserveCurrent, cancelled } = {}) => {
      // A user-aborted upload is a confirmation, not a failure: keep the
      // current image (or the plain empty state) and say so quietly.
      if (cancelled) {
        if (!preserveCurrent) actions.photo.clear();
        toast(message);
        return;
      }
      if (!preserveCurrent) actions.photo.clear(message);
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
  function mountNativeDrop() {
    window.addEventListener("hyperdr:native-file-drop", consumeNativeDrop);
    store.watchAny(["capabilities", "restoring"], consumeNativeDrop);
    consumeNativeDrop();
  }

  /* What the picker offers and what the hint promises both come from the
   * converter's own extension table, served in /api/state. The markup used to
   * carry a hand-written accept list -- the fifth copy of that list in the
   * project, and the one most likely to be forgotten. */
  const describeSupport = () => {
    const capabilities = store.get().capabilities;
    const extensions = capabilities?.inputExtensions;
    if (!Array.isArray(extensions) || !extensions.length) return;
    fileInput.accept = extensions.join(",");
    setText(supportHint, t("stage.support"));
    supportHint.title = extensions.join(" ");
  };
  function mountSupport() {
    store.watch("capabilities", describeSupport);
    describeSupport();
  }

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

  let pickingFile = false;
  const openPicker = async () => {
    if (!canReplace() || pickingFile) return;
    pickingFile = true;
    try {
      await pickInputFile({ capabilities: store.get().capabilities,
        dialog: window.__TAURI__?.dialog, fileInput, upload });
    } catch (error) {
      toast(error.message || t("err.nativeInput"), true);
    } finally {
      pickingFile = false;
    }
  };
  function mountDrop() {
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
  }

  function mountReactions() {
    store.watchAny(["uploading"], (state) => {
      stage.classList.toggle("is-uploading", state.uploading);
      stage.setAttribute("aria-busy", String(state.uploading));
      selectButton.disabled = state.uploading;
      uploadOverlay.hidden = !state.uploading;
      // The first photo arrives on the empty card, whose headline would
      // otherwise keep inviting a drop while the bar fills underneath it.
      if (state.uploading && !image.source) setText(emptyTitle, t("stage.reading"));
    });
    store.watch("uploadProgress", (fraction) => {
      const percent = Math.round(fraction * 100);
      progressBar.style.width = `${percent}%`;
      setText(uploadOverlayText, t("stage.uploading", { percent }));
    });
  }

  function mountLocale() {
    onLocaleChange(() => {
      setText(supportHint, t("stage.support"));
    });
  }

  function mountPicker() {
    selectButton.addEventListener("click", openPicker);
    fileInput.addEventListener("change", (event) => {
      startUpload(event.target.files);
      fileInput.value = "";
    });
    uploadCancel.addEventListener("click", (event) => {
      event.stopPropagation();
      upload.abort();
    });
  }


  return { canReplace, consumeNativeDrop, describeSupport, startUpload, openPicker, mountNativeDrop, mountSupport, mountPicker, mountDrop, mountReactions, mountLocale };
}

/* Handle press-and-hold comparison and the stage keyboard shortcuts. */

/* Gesture descriptions remain available to screen readers. */
const TOUCH_HINT = "stage.hintTouch";
const MOUSE_HINT = "stage.hintMouse";

function createGestures(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage } = ctx.dom;

  const isStageControl = (target) =>
    target instanceof Element
    && Boolean(target.closest("button, a, input, select, textarea, [role='slider']"));
  const gesture = { pointerId: null, at: 0, x: 0, y: 0, timer: 0 };

  function beginCompare(event) {
    if (!image.source || store.get().comparing) return;
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
  function mountPointer() {
    stage.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !actions.intake.canReplace() || isStageControl(event.target)) return;
      gesture.pointerId = event.pointerId;
      gesture.at = performance.now();
      gesture.x = event.clientX;
      gesture.y = event.clientY;
      clearTimeout(gesture.timer);
      // Press-and-hold compares against the original; an empty-stage tap imports.
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
      if (!image.source && isActive && !wasComparing && !isStageControl(event.target)
          && elapsed < 320 && moved < 12) actions.intake.openPicker();
    });

    stage.addEventListener("pointercancel", cancelGesture);
    stage.addEventListener("lostpointercapture", cancelGesture);
    stage.addEventListener("blur", cancelGesture);
  }

  function mountKeyboard() {
    stage.addEventListener("contextmenu", (event) => { if (image.source) event.preventDefault(); });
    stage.addEventListener("selectstart", (event) => {
      if (touchQuery.matches) event.preventDefault();
    });
    stage.addEventListener("keydown", (event) => {
      if (event.target === stage && ["Enter", " "].includes(event.key) && !event.repeat) {
        event.preventDefault();
        if (image.source) beginCompare(event); else actions.intake.openPicker();
      } else if (event.key === "Escape") cancelGesture(event);
    });

    stage.addEventListener("keyup", (event) => {
      if (["Enter", " "].includes(event.key)) endCompare(event);
    });

    /* Space compares without the canvas having focus first: after a click on
     * the photo's surroundings or when nothing is focused, the documented
     * shortcut used to do nothing. It is an allow-list -- the page itself or the
     * viewer area -- because everything else focusable (buttons, fields, the
     * rail's collapsible headers) already has its own meaning for Space. */
    const comparesOnSpace = (target) => target === document.body || target === document.documentElement
      || (target instanceof Element && Boolean(target.closest(".app__stage"))
        && !target.closest("button, a, input, select, textarea, summary, [contenteditable], [role='slider']"));
    document.addEventListener("keydown", (event) => {
      if (event.key !== " " || event.repeat || event.ctrlKey || event.metaKey || event.altKey) return;
      if (event.target === stage || !comparesOnSpace(event.target) || !image.source) return;
      event.preventDefault();
      beginCompare();
    });
    document.addEventListener("keyup", (event) => {
      if (event.key === " " && event.target !== stage) endCompare();
    });
    window.addEventListener("blur", () => endCompare());
  }

  const applyPointerHint = () => {
    const text = t(touchQuery.matches ? TOUCH_HINT : MOUSE_HINT);
    stage.setAttribute("aria-label", text);
  };

  function mountPointerHint() {
    touchQuery.addEventListener?.("change", () => {
      applyPointerHint();
      store.set({ comparing: false });
    });
  }

  function mountLocale() {
    onLocaleChange(applyPointerHint);
  }


  return { isStageControl, beginCompare, endCompare, cancelGesture, applyPointerHint, mountPointer, mountKeyboard, mountPointerHint, mountLocale };
}

/* Request AI gain maps and update the optimization controls. */


function createOptimization(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { mathModeButton, optimizeButton } = ctx.dom;

  function mountModelChange() {
    // Invalidate even in manual mode: the next AI click must use the new model.
    // Keep the selected workflow during inference so undo records one model change.
    store.subscribe((state, previous, changed) => {
      if (!changed.includes("modelId")) return;
      if (state.modelId === previous.modelId) return;
      ++ctx.modelRequest;
      ctx.modelGain = null;
      analysis.modelGain = null;
      if (state.previewOptimized) {
        ctx.invalidateImage();
      }
      store.set({ modelGainReady: false, modelIdentity: null, optimizing: false,
        ...(state.previewOptimized ? { previewReady: false } : {}) });
      if (state.previewOptimized && !state.restoring && !state.uploading) ctx.previewScheduler.request(false);
    });
  }

  async function optimize({ resetOriginal = false, scheduled = false } = {}) {
    const state = store.get();
    if (isHdrSource(state.sourceDomain)) return;
    if (state.optimizing || (state.previewOptimized && state.modelGainReady && ctx.modelGain)) return;
    if (ctx.modelGain && state.modelGainReady) {
      store.set({ previewOptimized: true });
      return;
    }
    if (!state.sessionId || !state.capabilities?.model?.ready) return;
    const request = ++ctx.modelRequest;
    const current = () => request === ctx.modelRequest
      && store.get().sessionId === state.sessionId && store.get().file === state.file
      && store.get().highlightRecovery === state.highlightRecovery
      && store.get().clampSrgb === state.clampSrgb && store.get().colorGamut === state.colorGamut
      && store.get().rawProfile === state.rawProfile
      && store.get().rawLook === state.rawLook
      && store.get().lensCorrection === state.lensCorrection
      && store.get().modelId === state.modelId;
    if (!scheduled) ctx.previewScheduler.cancel();
    ctx.invalidateImage();
    store.set({ optimizing: true, previewReady: false });
    try {
      const gain = await api.modelPreview(
        state.sessionId, state.highlightRecovery, state.modelId,
        { colorGamut: state.colorGamut, clampSrgb: state.clampSrgb, rawProfile: state.rawProfile,
          rawLook: state.rawLook, lensCorrection: state.lensCorrection });
      if (!current()) return;
      ctx.modelGain = gain;
      analysis.modelGain = gain;
      ctx.renderer?.uploadGainMap(gain);
      store.set({ previewOptimized: true, modelGainReady: true,
        modelIdentity: gain.identity });
      // Keep switching/export locked until the new native frame is presented.
      if (!scheduled) ctx.previewScheduler.cancel();
      await actions.photo.load({ resetOriginal, scheduled });
      if (current() && store.get().previewReady) announceModel(gain.identity);
    } catch (error) {
      if (!current()) return;
      ctx.modelGain = null;
      analysis.modelGain = null;
      store.set({ previewOptimized: false, modelGainReady: false, modelIdentity: null });
      // The converter's reason is kept, but it is English engine prose; the
      // sentence around it says what happened and what is on screen now.
      toast(error.message ? t("adjust.aiFailedDetail", { detail: error.message })
        : t("adjust.aiFailed"), true);
    } finally {
      if (current()) store.set({ optimizing: false });
    }
  }

  /* The selection stays on model 2 when it falls back. The persistent status
   * line is rendered by the selector itself; this toast is the transient
   * counterpart so the change is noticed even when the sidebar is scrolled away
   * from the control. */
  function announceModel(identity) {
    if (!identity) return;
    if (identity.inferenceMode === "pixel_only_fallback") {
      toast(t("adjust.modelFallback", {
        fields: fallbackFields(identity.fallbackReason),
        model: modelLabel(identity.effectiveModelId),
      }));
      return;
    }
    toast(t("adjust.aiApplied", { model: modelLabel(identity.effectiveModelId) }));
  }
  function mountControls() {
    mathModeButton.addEventListener("click", () => {
      if (!store.get().optimizing) store.set({ previewOptimized: false });
    });
    optimizeButton.addEventListener("click", optimize);
    const optimizeNote = role("optimize-note");
    store.watchAny(
      ["file", "capabilities", "optimizing", "previewOptimized", "modelGainReady", "jobId", "encoding", "lutInput", "lutId", "sourceDomain"],
      (state) => {
        const authoredHdr = isHdrSource(state.sourceDomain);
        optimizeButton.closest(".optimize-toggle").hidden = authoredHdr;
        const ready = Boolean(state.capabilities?.model?.ready);
        const locked = state.optimizing || Boolean(state.jobId);
        mathModeButton.disabled = !state.file || locked;
        optimizeButton.disabled =
          !state.file || locked || ["sdr-jpeg", "sdr-tiff"].includes(state.encoding)
          || authoredHdr
          || (state.lutId && ["hlg", "pq", "slog3-sgamut3cine"].includes(state.lutInput))
          || (!ready && !state.modelGainReady);
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
        const unavailable = Boolean(state.file) && !authoredHdr && !state.previewOptimized
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
  }

  function mountLocale() {
    onLocaleChange(() => {
      setText(optimizeButton, store.get().optimizing ? t("adjust.aiBusy") : t("adjust.ai"));
    });
  }


  return { optimize, announceModel, mountModelChange, mountControls, mountLocale };
}
