/* Handle press-and-hold comparison and the stage keyboard shortcuts. */

import { store } from "../../core/store.js";
import { touchQuery } from "../../core/media.js";
import { t, onLocaleChange } from "../../i18n/index.js";

/* Gesture descriptions remain available to screen readers. */
const TOUCH_HINT = "stage.hintTouch";
const MOUSE_HINT = "stage.hintMouse";

export function createGestures(ctx) {
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
