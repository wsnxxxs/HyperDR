import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs.readFileSync(new URL(
  "../../apps/panel/web/js/preview/stage/geometry.js", import.meta.url), "utf8")
  .replace(/^import .*;\r?\n/gm, "");
const { fittedSize, clampedPan, wheelZoomLevel, zoomAtPointer } = await import(
  `data:text/javascript;base64,${Buffer.from(
    "const clamp = (value, low, high) => Math.min(high, Math.max(low, value));\n" + source).toString("base64")}`);

assert.deepEqual(fittedSize(4000, 2000, 1000, 800, 20), { width: 960, height: 480 });
assert.deepEqual(fittedSize(2000, 4000, 1000, 800, 20), { width: 380, height: 760 });
assert.deepEqual(fittedSize(8000, 1000, 1000, 800, 20), { width: 960, height: 120 });
assert.deepEqual(fittedSize(1000, 1000, 20, 20, 20), { width: 0, height: 0 });

const state = { viewerZoom: 2, viewerPanX: 1000, viewerPanY: -1000 };
assert.deepEqual(clampedPan(state, 800, 600), { x: 400, y: -300 });
assert.deepEqual(clampedPan({ ...state, viewerZoom: 1 }, 800, 600), { x: 0, y: -0 });
assert.deepEqual(clampedPan({ ...state, viewerPanX: 50, viewerPanY: -30 }, 800, 600),
  { x: 50, y: -30 });

const box = { left: 10, top: 20, width: 800, height: 600 };
const wheel = { deltaY: -100, deltaMode: 0, ctrlKey: false, clientX: 510, clientY: 270 };
const next = wheelZoomLevel(1, wheel);
const zoomed = zoomAtPointer({ viewerZoom: 1, viewerPanX: 0, viewerPanY: 0 },
  next, wheel.clientX, wheel.clientY, box, 800, 600);
assert.equal(zoomed.viewerZoom, 1.1618);
// The displayed point is stationary even though the store rounds the zoom value.
assert.ok(Math.abs(zoomed.viewerPanX - (100 - 100 * Math.exp(0.15))) < 1e-10);
assert.ok(Math.abs(zoomed.viewerPanY - (-50 + 50 * Math.exp(0.15))) < 1e-10);
assert.equal(wheelZoomLevel(2, { ...wheel, deltaY: -1, deltaMode: 1 }),
  wheelZoomLevel(2, { ...wheel, deltaY: -16 }), "line deltas use 16 CSS pixels");
assert.equal(wheelZoomLevel(4, wheel), null);
assert.equal(wheelZoomLevel(2, { ...wheel, deltaY: 0 }), null);
assert.equal(wheelZoomLevel(2, { ...wheel, deltaY: 1000 }), 1);
assert.equal(wheelZoomLevel(2, { ...wheel, ctrlKey: true }), 4);
const fromClampedPan = zoomAtPointer(state, 3, 410, 320, box, 800, 600);
assert.deepEqual(fromClampedPan, { viewerZoom: 3, viewerPanX: 600, viewerPanY: -450 },
  "zoom anchors use the visible clamped pan rather than stale out-of-bounds values");
assert.ok(state.viewerPanX === 1000 && state.viewerZoom === 2, "geometry never mutates view state");
console.log("Preview stage geometry: fit, pan limits, wheel bounds and pointer anchoring passed");
