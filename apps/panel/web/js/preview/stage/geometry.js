/* Compute fit, pan limits and pointer-anchored zoom without touching the DOM. */
import { clamp } from "../../core/dom.js";

export function fittedSize(imageWidth, imageHeight, viewportWidth, viewportHeight, gutter) {
  const availableWidth = Math.max(0, viewportWidth - 2 * gutter);
  const availableHeight = Math.max(0, viewportHeight - 2 * gutter);
  const aspect = imageWidth / imageHeight;
  let width = Math.min(availableWidth, availableHeight * aspect);
  let height = width / aspect;
  if (height > availableHeight) {
    height = availableHeight;
    width = height * aspect;
  }
  return { width, height };
}

export function clampedPan(state, width, height) {
  const maxX = width * (state.viewerZoom - 1) / 2;
  const maxY = height * (state.viewerZoom - 1) / 2;
  return {
    x: clamp(state.viewerPanX, -maxX, maxX),
    y: clamp(state.viewerPanY, -maxY, maxY),
  };
}

export function wheelZoomLevel(zoom, event) {
  const pixels = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY;
  const next = clamp(zoom * Math.exp(-pixels * (event.ctrlKey ? 0.01 : 0.0015)), 1, 4);
  return Math.abs(next - zoom) < 1e-4 ? null : next;
}

export function zoomAtPointer(state, next, clientX, clientY, box, width, height) {
  const pointerX = clientX - (box.left + box.width / 2);
  const pointerY = clientY - (box.top + box.height / 2);
  const { x: panX, y: panY } = clampedPan(state, width, height);
  const ratio = next / state.viewerZoom;
  return {
    viewerZoom: Number(next.toFixed(4)),
    viewerPanX: pointerX - (pointerX - panX) * ratio,
    viewerPanY: pointerY - (pointerY - panY) * ratio,
  };
}
