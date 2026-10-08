/* Load quantised preview frames, maintain the neutral reference and schedule settings changes. */

import { api } from "../../core/api.js";
import { store } from "../../core/store.js";
import { setText } from "../../core/dom.js";
import { t, onLocaleChange } from "../../i18n/index.js";
import { prefs, previewCeilingPx } from "../../ui/prefs-schema.js";
import { AI_POST_KEYS, CONTROLS, defaultSettings, isHdrSource, referenceSettings, toOptions } from "../../settings/schema.js";
import { planeToImageData } from "../cpu.js";
import { createPreviewScheduler } from "../scheduler.js";
import { diagnosticFrame } from "../packet.js";
import { analyse } from "../scope.js";
import { histogramFromPlane } from "../histogram.js";
import { quantizedPreviewTier } from "./policy.js";

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


export function createPhoto(ctx) {
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
    const box = frame.getBoundingClientRect();
    return quantizedPreviewTier(ceiling, box.width, box.height, window.devicePixelRatio);
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
