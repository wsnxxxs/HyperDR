/* Keep stage-owned pixels, renderers and request epochs outside the UI store. */
import { role } from "../../core/dom.js";

export function createStageContext({ toast }) {
  const stage = role("stage");
  const frame = stage.querySelector(".stage-frame");
  const viewport = stage.closest(".stage-viewport");
  const empty = role("stage-empty");
  const selectButton = role("stage-select");
  const emptyTitle = role("stage-title");
  const progressText = role("upload-progress");
  const progressBar = role("upload-bar");
  const uploadOverlay = role("stage-upload");
  const uploadOverlayText = role("stage-upload-text");
  const uploadCancel = role("upload-cancel");
  const hdrStatus = role("hdr-status");
  const badge = role("hdr-badge");
  const fileInput = role("file-input");
  const supportHint = role("stage-support");
  const divider = role("divider");
  const hdrCanvas = role("canvas-hdr");
  const originalCanvas = role("canvas-original");
  const mathModeButton = role("math-mode");
  const optimizeButton = role("optimize");
  const sdrCanvas = role("canvas-sdr");
  /** Decoded image + derived buffers. Replaced wholesale, never patched. */
  const image = {
    source: null,
    frame: null,
    // Keep a neutral comparison for each uploaded/decode variant, upgrading
    // its pixels whenever the effect requests a higher preview tier.
    // `source` and `frame` are replaced whenever a look slider moves, so using
    // either one for "原图" makes the supposedly untreated side follow the
    // adjustment as well.
    original: null,
    originalEdge: 0,
    originalHistogram: null,

  };
  const sourceListeners = new Set();
  const notifySource = () => { for (const listener of [...sourceListeners]) listener(); };
  const analysis = { current: null, modelGain: null };

  const ctx = {
    toast,
    dom: { stage, frame, viewport, empty, selectButton, emptyTitle, progressText,
      progressBar, uploadOverlay, uploadOverlayText, uploadCancel, hdrStatus,
      badge, fileInput, supportHint, divider, hdrCanvas, originalCanvas,
      mathModeButton, optimizeButton, sdrCanvas },
    image, analysis, sourceListeners,
    notifySource,
    renderer: null,        // WebGPU/WebGL renderer, or null for the CPU path
    modelGain: null,
    modelRequest: 0,
    animationFrame: 0,
    imageGeneration: 0,
    rendererGeneration: 0,
    sourceDomainLabel: "",
    lastCapability: null,
    detail: { active: false, frame: null, centerX: 0, centerY: 0,
      fullWidth: 0, fullHeight: 0, request: 0, pointer: null, x: 0, y: 0 },
    hdrDisplayQuery: window.matchMedia("(dynamic-range: high)"),
    actions: {},
    previewScheduler: null,
    refreshScope: null,
  };
  ctx.isCurrentImage = (epoch) => epoch === ctx.imageGeneration;
  ctx.invalidateImage = () => ++ctx.imageGeneration;
  ctx.isCurrentRenderer = (epoch) => epoch === ctx.rendererGeneration;
  ctx.invalidateRenderer = () => ++ctx.rendererGeneration;
  return ctx;
}
