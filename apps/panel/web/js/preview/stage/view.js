/* Fit and transform the preview layers and keep the original comparison wipe aligned. */

import { store } from "../../core/store.js";
import { setText, clamp } from "../../core/dom.js";
import { t, onLocaleChange } from "../../i18n/index.js";
import { fittedSize, clampedPan, wheelZoomLevel, zoomAtPointer } from "./geometry.js";

export function createView(ctx) {
  const { image, actions } = ctx;
  const { stage, frame, viewport, divider, hdrCanvas, originalCanvas, badge, hdrStatus, detailButton, detailCanvas } = ctx.dom;

  const showingOriginal = () => {
    const state = store.get();
    return state.viewMode === "original" || Boolean(state.comparing);
  };

  /* ── the wipe ─────────────────────────────────────────────────────── */

  /** The effect canvas's displayed rectangle, in frame coordinates. */
  function imageRect() {
    const canvas = ctx.renderer?.kind === "hdr" ? hdrCanvas : ctx.dom.sdrCanvas;
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
    const bounds = viewport.getBoundingClientRect();
    const gutter = Number.parseFloat(
      getComputedStyle(viewport).getPropertyValue("--stage-gutter")) || 0;
    const { width, height } = fittedSize(image.source.width, image.source.height,
      bounds.width, bounds.height, gutter);
    stage.style.width = `${width}px`;
    stage.style.height = `${height}px`;
  }

  // CSS fits both layers to the same frame. Keep the original's native pixels
  // instead of shrinking them to slider drafts or enlarging an old thumbnail.
  function paintOriginal() {
    originalCanvas.width = image.original.width;
    originalCanvas.height = image.original.height;
    const context = originalCanvas.getContext(
      "2d", { colorSpace: "display-p3" }) || originalCanvas.getContext("2d");
    context.putImageData(image.original, 0, 0);
  }

  function syncView() {
    const state = store.get();
    const hasImage = Boolean(image.source);
    stage.dataset.viewMode = state.comparing ? "original" : state.viewMode;
    const split = state.viewMode === "split" && hasImage && !state.comparing;
    const original = showingOriginal();
    const showOriginalCanvas = Boolean(image.original) && (split || original);

    // The original is a separate 2D layer.  It must not be rendered from the
    // current native frame because that frame is regenerated for every look
    // adjustment.  In split mode it is clipped over the live effect; in
    // original/press-and-hold mode it covers the effect canvas completely.
    originalCanvas.hidden = !showOriginalCanvas;
    hdrCanvas.hidden = original || (ctx.renderer?.kind !== "hdr");
    ctx.dom.sdrCanvas.hidden = original || ctx.renderer?.kind === "hdr"
      || (!ctx.renderer && !image.frame);
    divider.hidden = !split;
    if (split) {
      originalCanvas.style.clipPath = `inset(0 ${((1 - state.splitRatio) * 100).toFixed(2)}% 0 0)`;
      positionDivider();
    } else {
      originalCanvas.style.removeProperty("clip-path");
    }

    setText(badge, original ? t("stage.badgeOriginal")
      : ctx.renderer?.kind === "hdr" ? "HDR" : t("stage.badgeSdr"));
    badge.hidden = !hasImage || ctx.renderer?.kind !== "hdr";
    badge.title = original
      ? t("stage.titleOriginal")
      : t("stage.titleHdr");
    hdrStatus.hidden = !hasImage;
    stage.classList.toggle("is-comparing", original);
    stage.setAttribute("aria-pressed", String(original));
    detailButton.hidden = !hasImage;
  }

  function applyZoom() {
    const state = store.get();
    const { x, y } = clampedPan(state, frame.clientWidth, frame.clientHeight);
    for (const canvas of frame.querySelectorAll("canvas")) {
      if (canvas === detailCanvas) continue;
      canvas.style.transform = `translate(${x}px, ${y}px) scale(${state.viewerZoom})`;
    }
    stage.classList.toggle("is-zoomed", state.viewerZoom > 1);
    positionDivider();
  }

  function mountGeometry() {
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
      fitStageToImage();
      positionDivider();
    }).observe(viewport);
    store.watchAny(["viewerZoom", "viewerPanX", "viewerPanY"], applyZoom);
    new ResizeObserver(applyZoom).observe(frame);
  }

  function mountPan() {
    const pan = { pointer: null, x: 0, y: 0, originX: 0, originY: 0 };
    stage.addEventListener("pointerdown", (event) => {
      if (store.get().viewerZoom <= 1 || event.button !== 0 || event.target.closest("button, [role='slider']")) return;
      event.stopImmediatePropagation(); event.preventDefault();
      const state = store.get();
      const { x, y } = clampedPan(state, frame.clientWidth, frame.clientHeight);
      Object.assign(pan, { pointer: event.pointerId, x: event.clientX, y: event.clientY,
        originX: x, originY: y });
      stage.setPointerCapture(event.pointerId);
    });
    stage.addEventListener("pointermove", (event) => {
      if (pan.pointer !== event.pointerId) return;
      store.set({ viewerPanX: pan.originX + event.clientX - pan.x, viewerPanY: pan.originY + event.clientY - pan.y });
    });
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) stage.addEventListener(type, (event) => {
      if (pan.pointer !== event.pointerId) return;
      pan.pointer = null; event.stopImmediatePropagation();
    });
  }

  function mountWheel() {
    /* Wheel zoom, anchored at the pointer so the detail under it stays put.
     * A trackpad pinch arrives as a ctrl+wheel and is honoured everywhere; a
     * plain wheel zooms only in the desktop layout, where the stage never
     * scrolls -- in the stacked phone-width layout it scrolls the page. */
    const wideLayout = window.matchMedia("(width >= 860px)");
    stage.addEventListener("wheel", (event) => {
      if (!image.source || (!event.ctrlKey && !wideLayout.matches)) return;
      event.preventDefault();
      const state = store.get();
      const next = wheelZoomLevel(state.viewerZoom, event);
      if (next === null) return;
      if (next <= 1.001) { store.set({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0 }); return; }
      store.set(zoomAtPointer(state, next, event.clientX, event.clientY,
        frame.getBoundingClientRect(), frame.clientWidth, frame.clientHeight));
    }, { passive: false });
  }

  function mountReactions() {
    store.watchAny(["viewMode", "comparing", "splitRatio"], () => { syncView(); actions.rendering.schedule(); }, { immediate: true });
  }

  function mountLocale() {
    onLocaleChange(syncView);
  }

  return { showingOriginal, imageRect, positionDivider, fitStageToImage, paintOriginal, syncView, applyZoom, mountGeometry, mountPan, mountWheel, mountReactions, mountLocale };
}
