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
import { createRendering } from "./stage/rendering.js";
import { createPhoto } from "./stage/photo.js";
import { createIntake } from "./stage/intake.js";
import { createGestures } from "./stage/gestures.js";

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
