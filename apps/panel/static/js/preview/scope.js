/* Histogram, clipping percentages, and the zebra overlay.
 *
 * All three are properties of the capture, not of the settings, so the pixel
 * walk runs once per image. Only the histogram is redrawn when a slider moves,
 * and only to reposition the expansion-start marker.
 */

import { role, setPressed, setText } from "../core/dom.js";
import { resolvedTheme } from "../ui/theme.js";

/** One pass over the source: luma + per-channel counts, clipping, zebra mask. */
export function analyse(source) {
  const data = source.data;
  const { width } = source;
  const luma = new Uint32Array(256);
  const red = new Uint32Array(256);
  const green = new Uint32Array(256);
  const blue = new Uint32Array(256);
  const zebra = new ImageData(width, source.height);
  const mask = zebra.data;

  const total = data.length / 4;
  let hot = 0;
  let cold = 0;

  for (let p = 0, i = 0; p < data.length; p += 4, i++) {
    const r = data[p], g = data[p + 1], b = data[p + 2];
    red[r]++; green[g]++; blue[b]++;
    const y = Math.round(0.2126 * r + 0.7152 * g + 0.0722 * b);
    luma[y < 0 ? 0 : y > 255 ? 255 : y]++;

    const peak = Math.max(r, g, b);
    const isHot = peak >= 250;
    const isCold = peak <= 4;
    if (isHot) hot++;
    if (isCold) cold++;
    if (!isHot && !isCold) continue;

    // Diagonal stripes, so the overlay reads as a marking rather than a fill.
    const x = i % width;
    const row = (i / width) | 0;
    if ((x + row) % 8 >= 3) continue;
    const o = i * 4;
    if (isHot) { mask[o] = 220; mask[o + 1] = 60; mask[o + 2] = 70; }
    else { mask[o] = 40; mask[o + 1] = 110; mask[o + 2] = 235; }
    mask[o + 3] = 235;
  }

  return {
    histogram: { luma, red, green, blue, total },
    clipping: { hot: hot / total, cold: cold / total },
    zebra,
  };
}

/* The histogram is painted on a canvas, so it cannot inherit the theme the way
 * the rest of the panel does. Rather than hard-code two palettes here, the
 * colours are declared on `.scope-graph` as custom properties and read back at
 * draw time -- including the blend mode, which has to invert with the
 * background: overlapping RGB channels are combined with `lighter` on a dark
 * graph and `multiply` on a light one, since either one alone washes the
 * channels out on the wrong surface. */
const PALETTE_KEYS = ["grid", "luma", "red", "green", "blue", "marker"];
const MOBILE_SCOPE = "(max-width: 640px)";
const SCOPE_OPEN_KEY = "hyperdr.mobileScopeOpen";

function readPalette(canvas) {
  const style = getComputedStyle(canvas);
  const palette = {};
  for (const key of PALETTE_KEYS) {
    palette[key] = style.getPropertyValue(`--hist-${key}`).trim();
  }
  palette.blend = resolvedTheme() === "dark" ? "lighter" : "multiply";
  return palette;
}

function drawSeries(context, counts, style, blend, width, height) {
  let max = 0;
  for (let i = 1; i < 255; i++) if (counts[i] > max) max = counts[i]; // ignore 0/255 spikes
  max = Math.max(max, 1);
  context.fillStyle = style;
  if (blend) context.globalCompositeOperation = blend;
  context.beginPath();
  context.moveTo(0, height);
  for (let i = 0; i < 256; i++) {
    const x = (i / 255) * width;
    const value = Math.min(1, counts[i] / max);
    context.lineTo(x, height - Math.pow(value, 0.55) * (height - 2));
  }
  context.lineTo(width, height);
  context.closePath();
  context.fill();
  context.globalCompositeOperation = "source-over";
}

export function mountScope(store, { analysis }) {
  const container = role("scope");
  const canvas = role("histogram");
  const zebraCanvas = role("canvas-zebra");
  const zebraToggle = role("zebra-toggle");
  const hotChip = role("clip-hot");
  const coldChip = role("clip-cold");
  const hotSummary = role("clip-hot-summary");
  const coldSummary = role("clip-cold-summary");
  const mobileScope = window.matchMedia(MOBILE_SCOPE);

  function savedMobileOpen() {
    try {
      const value = localStorage.getItem(SCOPE_OPEN_KEY);
      return value == null ? false : value === "true";
    } catch (_) {
      return false;
    }
  }

  container.open = mobileScope.matches ? savedMobileOpen() : true;

  const toggleZebra = () => store.set({ zebra: !store.value("zebra") });
  for (const node of [zebraToggle, hotChip, coldChip]) node.addEventListener("click", toggleZebra);

  function draw() {
    if (!container.open) return;
    const data = analysis.current;
    if (!data) return;
    const context = canvas.getContext("2d");
    const { width, height } = canvas;
    const palette = readPalette(canvas);
    context.clearRect(0, 0, width, height);

    context.strokeStyle = palette.grid;
    context.lineWidth = 1;
    for (let g = 1; g < 4; g++) {
      const x = ((width * g) / 4) | 0;
      context.beginPath();
      context.moveTo(x + 0.5, 0);
      context.lineTo(x + 0.5, height);
      context.stroke();
    }

    const { histogram } = data;
    if (store.value("histMode") === "rgb") {
      drawSeries(context, histogram.red, palette.red, palette.blend, width, height);
      drawSeries(context, histogram.green, palette.green, palette.blend, width, height);
      drawSeries(context, histogram.blue, palette.blue, palette.blend, width, height);
    } else {
      drawSeries(context, histogram.luma, palette.luma, null, width, height);
    }

    // Where the broad highlight lift begins.
    const marker = (store.value("expansionStart") * width) | 0;
    context.strokeStyle = palette.marker;
    context.setLineDash([3, 3]);
    context.beginPath();
    context.moveTo(marker + 0.5, 0);
    context.lineTo(marker + 0.5, height);
    context.stroke();
    context.setLineDash([]);
  }

  function paintZebra() {
    const data = analysis.current;
    const on = store.value("zebra");
    if (!on || !data) { zebraCanvas.hidden = true; return; }
    zebraCanvas.width = data.zebra.width;
    zebraCanvas.height = data.zebra.height;
    zebraCanvas.getContext("2d").putImageData(data.zebra, 0, 0);
    zebraCanvas.hidden = false;
  }

  store.watch(["histMode", "expansionStart"], draw);

  container.addEventListener("toggle", () => {
    if (mobileScope.matches) {
      try { localStorage.setItem(SCOPE_OPEN_KEY, String(container.open)); } catch (_) {}
    }
    if (container.open) draw();
  });
  mobileScope.addEventListener?.("change", () => {
    container.open = mobileScope.matches ? savedMobileOpen() : true;
    if (container.open) draw();
  });

  // Canvas pixels are not restyled by a theme flip the way the DOM is, so the
  // graph is repainted whenever the resolved theme could have changed: the
  // toggle writes `data-theme`, and with no stored choice the system does.
  new MutationObserver(draw)
    .observe(document.documentElement, { attributeFilter: ["data-theme"] });
  window.matchMedia("(prefers-color-scheme: dark)")
    .addEventListener?.("change", () => {
      if (!document.documentElement.dataset.theme) draw();
    });
  store.watch(["zebra"], (state) => {
    setPressed(zebraToggle, state.zebra, { aria: "aria-checked" });
    hotChip.classList.toggle("is-on", state.zebra);
    coldChip.classList.toggle("is-on", state.zebra);
    paintZebra();
  });

  /** Called by the stage after each new image (or `null` when cleared). */
  return function update() {
    const data = analysis.current;
    container.hidden = false;
    if (!data) {
      canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
      setText(role("clip-hot-value"), "0.0%");
      setText(role("clip-cold-value"), "0.0%");
      setText(hotSummary, "0.0%");
      setText(coldSummary, "0.0%");
      zebraCanvas.hidden = true;
      return;
    }
    const hot = `${(data.clipping.hot * 100).toFixed(1)}%`;
    const cold = `${(data.clipping.cold * 100).toFixed(1)}%`;
    setText(role("clip-hot-value"), hot);
    setText(role("clip-cold-value"), cold);
    setText(hotSummary, hot);
    setText(coldSummary, cold);
    draw();
    paintZebra();
  };
}
