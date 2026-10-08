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
import { createDetail, createDetailElements } from "./stage/detail.js";
import { createView } from "./stage/view.js";
import { createRendering } from "./stage/rendering.js";
import { createPhoto } from "./stage/photo.js";
import { createIntake } from "./stage/intake.js";
import { createGestures } from "./stage/gestures.js";
import { createOptimization } from "./stage/optimization.js";

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
