/* A single histogram: filled source and clearly outlined current output. */
import { role, setPressed, setText, readColor } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { store } from "../core/store.js";
import { histogramFromPlane, histogramFromDisplayImage,
  distribution, SDR_WIDTH } from "./histogram.js";
const P3_LUMA = [0.2289746, 0.6917385, 0.0792869];

/* One pass over the source plus the native output planes: luma + per-channel
 * counts and zebra masks. The histogram is deliberately computed from
 * the linear Float32 contract, never from the browser's folded 8-bit display
 * copy. The masks are painted with token colours read at call time, so a theme
 * flip between images cannot leave yesterday's red on today's photo. */
export function analyse(source, rendered = null) {
  // Keep the original two-argument export shape for small integrations while
  // accepting the native frame and its linear display range as optional
  // trailing arguments from the stage.
  const frame = arguments[2] || null;
  const rangeLinear = Number.isFinite(arguments[3]) ? arguments[3] : 1;
  const data = source.data;
  const { width } = source;
  const height = source.height;
  const zebraHot = new ImageData(width, source.height);
  const zebraCold = new ImageData(width, source.height);
  const hotColor = readColor("--zebra-hot");
  const coldColor = readColor("--zebra-cold");

  for (let p = 0, i = 0; p < data.length; p += 4, i++) {
    const r = data[p], g = data[p + 1], b = data[p + 2];
    const output = frame?.hdr;
    const outputPeak = output
      ? Math.max(output[i * 3], output[i * 3 + 1], output[i * 3 + 2])
      : Math.max(r, g, b) / 255;
    const outputLuma = output
      ? P3_LUMA[0] * output[i * 3]
        + P3_LUMA[1] * output[i * 3 + 1]
        + P3_LUMA[2] * output[i * 3 + 2]
      : (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    const isHot = outputPeak >= Math.max(1, rangeLinear) * 0.999;
    const isCold = outputLuma <= 1e-6;
    if (!isHot && !isCold) continue;

    // Diagonal stripes, so the overlay reads as a marking rather than a fill.
    const x = i % width;
    const row = (i / width) | 0;
    if ((x + row) % 8 >= 3) continue;
    const o = i * 4;
    const target = isHot ? zebraHot.data : zebraCold.data;
    const color = isHot ? hotColor : coldColor;
    target[o] = color.r;
    target[o + 1] = color.g;
    target[o + 2] = color.b;
    target[o + 3] = 235;
  }

  const reference = arguments[4] || null;
  const histogram = reference || (frame?.base
    ? histogramFromPlane(frame.base, frame.width, frame.height, rangeLinear)
    : histogramFromDisplayImage(source, rangeLinear));
  const renderedHistogram = frame?.hdr
    ? histogramFromPlane(frame.hdr, frame.width, frame.height, rangeLinear)
    : rendered ? histogramFromDisplayImage(rendered, rangeLinear) : null;
  return {
    source,
    histogram,
    zebraHot,
    zebraCold,
    renderedHistogram,
    rangeLinear: Math.max(rangeLinear, 1),
  };
}

export function mountScope({ analysis }) {
  const canvas = role("histogram"), content = role("scope-content");
  const zebraHotCanvas = role("canvas-zebra-hot"), zebraColdCanvas = role("canvas-zebra-cold");
  const modeButtons = [["luma", "scope.luma"], ["rgb", "scope.rgb"]].map(([id, label]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.addEventListener("click", () => store.set({ histMode: id }));
    role("hist-mode").append(button);
    return { id, label, button };
  });
  function syncMode() {
    content.dataset.mode = store.get().histMode;
    for (const { id, label, button } of modeButtons) {
      setText(button, t(label));
      setPressed(button, id === store.get().histMode);
    }
  }

  function draw() {
    const data = analysis.current;
    const ctx = canvas.getContext("2d");
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (!width || !height) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    if (canvas.width !== Math.round(width * ratio)) canvas.width = Math.round(width * ratio);
    if (canvas.height !== Math.round(height * ratio)) canvas.height = Math.round(height * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, width, height);
    if (!data) return;
    const palette = {};
    for (const key of ["grid", "luma", "red", "green", "blue", "output", "backdrop"]) palette[key] = readColor(`--hist-${key}`).css;
    const rgb = store.get().histMode === "rgb";
    const channels = rgb ? ["red", "green", "blue"] : ["luma"];
    const series = hist => hist ? channels.map(key => [key, distribution(hist, key)]) : [];
    const source = series(data.histogram), output = series(data.renderedHistogram);
    let peak = .001;
    for (const [, counts] of [...source, ...output]) for (const n of counts) peak = Math.max(peak, n);
    const bottom = height - 1;
    const y = n => bottom - Math.sqrt(n / peak) * (bottom - 6);

    ctx.fillStyle = palette.output; ctx.globalAlpha = .05;
    ctx.fillRect(width * SDR_WIDTH, 0, width * (1 - SDR_WIDTH), height);
    ctx.globalAlpha = 1; ctx.lineWidth = 1; ctx.strokeStyle = palette.grid;
    for (const x of [SDR_WIDTH * .25, SDR_WIDTH * .75, SDR_WIDTH, .85]) {
      ctx.beginPath(); ctx.moveTo(x * width, 0); ctx.lineTo(x * width, height); ctx.stroke();
    }
    for (const fraction of [.25, .5, .75]) {
      ctx.beginPath(); ctx.moveTo(0, fraction * height); ctx.lineTo(width, fraction * height); ctx.stroke();
    }
    function path(counts) {
      ctx.beginPath();
      counts.forEach((n, i) => {
        const x = (i + .5) / counts.length * width;
        if (!i) ctx.moveTo(x, y(n)); else ctx.lineTo(x, y(n));
      });
    }
    // Only the source has a filled area, so the result never covers it.
    for (const [key, counts] of source) {
      path(counts); ctx.lineTo(width, bottom); ctx.lineTo(0, bottom); ctx.closePath();
      ctx.fillStyle = palette[key]; ctx.globalAlpha = rgb ? .15 : .38; ctx.fill();
    }
    // A narrow backdrop separates current curves from the source fill.
    ctx.globalAlpha = 1; ctx.lineJoin = "round";
    for (const [key, counts] of output) {
      path(counts); ctx.strokeStyle = palette.backdrop; ctx.lineWidth = 4; ctx.stroke();
      ctx.strokeStyle = key === "luma" ? palette.output : palette[key];
      ctx.lineWidth = 2; ctx.stroke();
    }
    // Paint the source outline last: even coincident curves retain its dashes.
    ctx.setLineDash([5, 4]); ctx.lineWidth = 1.4;
    for (const [key, counts] of source) {
      path(counts); ctx.strokeStyle = palette[key]; ctx.stroke();
    }
    ctx.setLineDash([]);
  }
  let queued = false;
  function scheduleDraw() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; draw(); });
  }
  function paintZebra() {
    const data = analysis.current, state = store.get();
    for (const [mask, node, on] of [[data?.zebraHot, zebraHotCanvas, state.zebraHot], [data?.zebraCold, zebraColdCanvas, state.zebraCold]]) {
      if (!on || !mask) { node.hidden = true; continue; }
      if (node.width !== mask.width) node.width = mask.width;
      if (node.height !== mask.height) node.height = mask.height;
      node.getContext("2d").putImageData(mask, 0, 0); node.hidden = false;
    }
  }
  new ResizeObserver(scheduleDraw).observe(canvas);
  store.watch("histMode", () => { syncMode(); scheduleDraw(); }, { immediate: true });
  store.watchAny(["zebraHot", "zebraCold"], paintZebra, { immediate: true });
  onLocaleChange(() => { syncMode(); scheduleDraw(); });
  new MutationObserver(scheduleDraw).observe(document.documentElement, { attributeFilter: ["data-theme"] });
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", scheduleDraw);
  return function update() {
    content.dataset.empty = String(!analysis.current);
    draw();
    paintZebra();
  };
}
