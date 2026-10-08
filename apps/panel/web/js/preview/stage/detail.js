/* Own the full-resolution detail overlay and its region requests. */

import { api } from "../../core/api.js";
import { store } from "../../core/store.js";
import { clamp } from "../../core/dom.js";
import { t, onLocaleChange } from "../../i18n/index.js";
import { toOptions } from "../../settings/schema.js";
import { renderSdr } from "../cpu.js";

export function createDetail(ctx) {
  const { image, detail } = ctx;
  const { frame, detailButton, detailOverlay, detailCanvas, detailStatus } = ctx.dom;

  function positionDetail() {
    if (!detail.frame) return;
    const { regionX, regionY } = detail.frame.metadata;
    detailCanvas.style.left = `${Math.round(detailOverlay.clientWidth / 2 - (detail.centerX - regionX))}px`;
    detailCanvas.style.top = `${Math.round(detailOverlay.clientHeight / 2 - (detail.centerY - regionY))}px`;
  }

  function detailNeedsPixels() {
    if (!detail.frame) return true;
    const m = detail.frame.metadata;
    const left = Math.max(0, detail.centerX - detailOverlay.clientWidth / 2);
    const top = Math.max(0, detail.centerY - detailOverlay.clientHeight / 2);
    const right = Math.min(detail.fullWidth, detail.centerX + detailOverlay.clientWidth / 2);
    const bottom = Math.min(detail.fullHeight, detail.centerY + detailOverlay.clientHeight / 2);
    return left < m.regionX || top < m.regionY
      || right > m.regionX + detail.frame.width
      || bottom > m.regionY + detail.frame.height;
  }

  async function requestDetail() {
    if (!detail.active || !store.get().sessionId || !image.frame) return;
    const request = ++detail.request;
    const state = store.get();
    const width = Math.min(2048, Math.max(1, Math.ceil(detailOverlay.clientWidth) + 512));
    const height = Math.min(2048, Math.max(1, Math.ceil(detailOverlay.clientHeight) + 512));
    const center = !detail.fullWidth;
    const x = Math.max(0, Math.round(detail.centerX - width / 2));
    const y = Math.max(0, Math.round(detail.centerY - height / 2));
    detailStatus.textContent = t("stage.detailLoading");
    try {
      const pixels = await api.detailPreview(state.sessionId, {
        options: { ...toOptions(state), useModel: Boolean(state.previewOptimized),
          modelId: state.modelId },
        highlightRecovery: state.highlightRecovery,
        x, y, width, height, center,
      });
      if (!detail.active || request !== detail.request
          || state.sessionId !== store.get().sessionId) return;
      if (pixels.metadata.detail !== true) throw new Error(t("err.previewData"));
      detail.frame = pixels;
      detail.fullWidth = Number(pixels.metadata.fullWidth);
      detail.fullHeight = Number(pixels.metadata.fullHeight);
      if (center) {
        detail.centerX = detail.fullWidth / 2;
        detail.centerY = detail.fullHeight / 2;
      }
      detailCanvas.width = pixels.width;
      detailCanvas.height = pixels.height;
      renderSdr(detailCanvas, { frame: pixels });
      positionDetail();
      detailStatus.textContent = t("stage.detailStatus");
    } catch (error) {
      if (!detail.active || request !== detail.request || error.status === 499) return;
      detailStatus.textContent = error.message || t("err.preview");
    }
  }

  function closeDetail() {
    ++detail.request;
    detail.active = false;
    detail.frame = null;
    detail.fullWidth = detail.fullHeight = 0;
    detailOverlay.hidden = true;
    detailButton.setAttribute("aria-pressed", "false");
    detailButton.textContent = t("stage.detailOpen");
  }

  function mountResize() {
    new ResizeObserver(() => {
      if (!detail.active) return;
      positionDetail();
      if (detailNeedsPixels()) requestDetail();
    }).observe(frame);
  }

  function mountInteractions() {
    detailButton.addEventListener("click", (event) => {
      event.preventDefault(); event.stopImmediatePropagation();
      if (detail.active) { closeDetail(); return; }
      if (!image.frame) return;
      detail.active = true;
      detailOverlay.hidden = false;
      detailOverlay.focus({ preventScroll: true });
      detailButton.setAttribute("aria-pressed", "true");
      detailButton.textContent = t("stage.detailClose");
      store.set({ viewMode: "effect", comparing: false, viewerZoom: 1,
        viewerPanX: 0, viewerPanY: 0 });
      requestDetail();
    });
    detailOverlay.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault(); event.stopImmediatePropagation();
      detailOverlay.focus({ preventScroll: true });
      detail.pointer = event.pointerId;
      detail.x = event.clientX; detail.y = event.clientY;
      detailOverlay.setPointerCapture(event.pointerId);
    });
    detailOverlay.addEventListener("pointermove", (event) => {
      if (detail.pointer !== event.pointerId || !detail.fullWidth) return;
      detail.centerX = clamp(detail.centerX - (event.clientX - detail.x), 0, detail.fullWidth);
      detail.centerY = clamp(detail.centerY - (event.clientY - detail.y), 0, detail.fullHeight);
      detail.x = event.clientX; detail.y = event.clientY;
      positionDetail();
    });
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) {
      detailOverlay.addEventListener(type, (event) => {
        if (detail.pointer !== event.pointerId) return;
        detail.pointer = null;
        event.stopImmediatePropagation();
        if (detailNeedsPixels()) requestDetail();
      });
    }
    detailOverlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); closeDetail(); detailButton.focus(); return; }
      const move = { ArrowLeft: [-128, 0], ArrowRight: [128, 0],
        ArrowUp: [0, -128], ArrowDown: [0, 128] }[event.key];
      if (!move || !detail.fullWidth) return;
      event.preventDefault();
      detail.centerX = clamp(detail.centerX + move[0], 0, detail.fullWidth);
      detail.centerY = clamp(detail.centerY + move[1], 0, detail.fullHeight);
      positionDetail();
      if (detailNeedsPixels()) requestDetail();
    });
    detailOverlay.addEventListener("wheel", (event) => {
      event.preventDefault(); event.stopImmediatePropagation();
      if (!detail.fullWidth) return;
      detail.centerX = clamp(detail.centerX + event.deltaX, 0, detail.fullWidth);
      detail.centerY = clamp(detail.centerY + event.deltaY, 0, detail.fullHeight);
      positionDetail();
      if (detailNeedsPixels()) requestDetail();
    }, { passive: false });
  }

  function mountLocale() {
    onLocaleChange(() => {
      detailButton.textContent = t(detail.active ? "stage.detailClose" : "stage.detailOpen");
      detailOverlay.setAttribute("aria-label", t("stage.detailLabel"));
      if (detail.frame) detailStatus.textContent = t("stage.detailStatus");
    });
  }

  return { positionDetail, detailNeedsPixels, requestDetail, closeDetail, mountResize, mountInteractions, mountLocale };
}

export function createDetailElements(ctx) {
  const { stage, frame } = ctx.dom;
  const detailButton = document.createElement("button");
  detailButton.type = "button";
  detailButton.className = "stage-detail-button";
  detailButton.hidden = true;
  detailButton.setAttribute("aria-pressed", "false");
  detailButton.textContent = t("stage.detailOpen");
  stage.append(detailButton);
  const detailOverlay = document.createElement("div");
  detailOverlay.className = "stage-detail-overlay";
  detailOverlay.hidden = true;
  detailOverlay.tabIndex = 0;
  detailOverlay.setAttribute("role", "region");
  detailOverlay.setAttribute("aria-label", t("stage.detailLabel"));
  const detailCanvas = document.createElement("canvas");
  const detailStatus = document.createElement("span");
  detailStatus.className = "stage-detail-status";
  detailStatus.textContent = t("stage.detailStatus");
  detailOverlay.append(detailCanvas, detailStatus);
  frame.append(detailOverlay);
  Object.assign(ctx.dom, { detailButton, detailOverlay, detailCanvas, detailStatus });
}
