/* The panel's controls, declared as data.
 *
 * One declaration per control drives the widget that gets built, the option
 * object sent to /api/run, the readout's formatting, and -- new in this
 * rewrite -- the mask the stage shows while the control is hovered. Adding a
 * slider means editing this file and nothing else.
 *
 * There is no `scale` field any more: every control's `help` already says in
 * words which way the slider runs, and rendering the two poles under every
 * track as well cost a text row per control -- six rows in a column that has
 * to end above the run button.
 *
 * `mask` names the overlay painted on the photograph while the control is
 * hovered or focused (see preview/mask.js); null means the control has no
 * spatial story to tell (quality, highlight recovery) and hovering shows
 * nothing.
 */

import { t } from "../i18n/index.js";

export const ENCODINGS = [
  { id: "sdr-jpeg", label: "SDR JPEG", maxRange: 4, hint: "enc.sdr-jpeg.hint" },
  {
    id: "adaptive", label: "Adaptive HDR", maxRange: 3,
    hint: "enc.adaptive.hint",
  },
  {
    id: "pq", label: "PQ", maxRange: 4,
    hint: "enc.pq.hint",
  },
  {
    id: "hlg", label: "HLG", maxRange: 2.3,
    hint: "enc.hlg.hint",
  },
  {
    id: "ultrahdr", label: "Ultra HDR", maxRange: 4,
    hint: "enc.ultrahdr.hint",
  },
  {
    id: "avif-pq", label: "AVIF PQ", maxRange: 4,
    hint: "enc.avif-pq.hint",
  },
  {
    id: "avif-hlg", label: "AVIF HLG", maxRange: 2.3,
    hint: "enc.avif-hlg.hint",
  },
];

export const COLOR_GAMUTS = [
  { id: "srgb", label: "sRGB", hint: "out.gamutHint.srgb" },
  { id: "p3", label: "Display P3", hint: "out.gamutHint.p3" },
  { id: "rec2020", label: "Rec.2020", hint: "out.gamutHint.rec2020" },
];

export const encodingById = (id) =>
  ENCODINGS.find((entry) => entry.id === id) || ENCODINGS.find((entry) => entry.id === "adaptive");

const ev = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)} EV`;
const signed = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)}`;
const percent = (value) => `${Math.round(value * 100)}%`;
const fixed = (digits) => (value) => value.toFixed(digits);
const stops = (digits) => (value) => t("unit.stops", { value: value.toFixed(digits) });
const stopsOrAuto = (digits) => (value) =>
  value < 0 ? t("unit.auto") : t("unit.stops", { value: value.toFixed(digits) });
const percentOrAuto = (value) => value < 0 ? t("unit.auto") : `${Math.round(value * 100)}%`;

export const DEFAULT_BRIGHTNESS_EV = 0.6;

/* AI controls are deliberately separate from the mathematical renderer's
 * controls below.  A model gain is a complete rendition, so these values are
 * post-adjustments applied after the model has produced its spatial result;
 * sharing a store key with manual mode would make a hidden AI slider silently
 * change a later manual export. */
export const AI_POST_KEYS = [
  "aiBrightness", "aiContrast", "aiShadows", "aiHighlights",
  "aiHdrRange", "aiExpansionStart",
];

const AI_BRIGHTNESS_DEFAULT = 0;
const AI_CONTRAST_DEFAULT = 1;
const AI_HDR_RANGE_DEFAULT = -1;
const AI_EXPANSION_START_DEFAULT = -1;

/* `group` selects the container the control renders into; `kind` selects the
 * widget. `key` is both the store key and the name sent to /api/run.
 *
 * `group: "pinned"` is a setting with no widget. It still seeds the store, is
 * still read by the renderers, and is still sent to /api/run -- it simply is
 * not adjustable. That is not the same as deleting it: curve-math.js takes
 * `contrast` as an argument and stage/scope/mask all watch it, so a deleted key
 * would reach the tone curve as `undefined`. Pinning keeps the exported image
 * byte-identical (command.py's PANEL_DEFAULTS holds the same values for a
 * browser that omits them) while taking the control off the rail. */
export const CONTROLS = [
  { key: "lutStrength", kind: "range", group: "lut", label: "lut.strength",
    min: 0, max: 1, step: 0.01, default: 1, format: percent, mask: null, help: "lut.strengthHint" },
  {
    key: "brightness", kind: "range", group: "tone", label: "ctrl.brightness.label",
    min: 0, max: 2, step: 0.05, default: DEFAULT_BRIGHTNESS_EV, format: ev, mask: null,
    help: "ctrl.brightness.help",
  },
  {
    key: "hdrStrength", kind: "range", group: "tone", label: "ctrl.hdrStrength.label",
    min: 0, max: 1, step: 0.05, default: 0.4, format: fixed(2), mask: "gain",
    help: "ctrl.hdrStrength.help",
  },
  {
    key: "hdrRange", kind: "range", group: "tone", label: "ctrl.hdrRange.label",
    min: 0, max: 3, step: 0.1, default: 2.5, format: stops(1), mask: "gainFull",
    help: "ctrl.hdrRange.help",
  },
  {
    key: "modelStrength", kind: "range", group: "model", label: "ctrl.modelStrength.label",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, mask: null,
    help: "ctrl.modelStrength.help",
  },
  {
    key: "aiBrightness", kind: "range", group: "model", label: "ctrl.aiBrightness.label",
    min: -1, max: 1, step: 0.05, default: AI_BRIGHTNESS_DEFAULT, format: ev, mask: null,
    help: "ctrl.aiBrightness.help",
  },
  {
    key: "aiContrast", kind: "range", group: "model", label: "ctrl.aiContrast.label",
    min: 0.8, max: 1.35, step: 0.01, default: AI_CONTRAST_DEFAULT, format: fixed(2), mask: null,
    help: "ctrl.aiContrast.help",
  },
  {
    key: "aiShadows", kind: "range", group: "model", label: "ctrl.aiShadows.label",
    min: -1, max: 1, step: 0.05, default: 0, format: ev, mask: null,
    help: "ctrl.aiShadows.help",
  },
  {
    key: "aiHighlights", kind: "range", group: "model", label: "ctrl.aiHighlights.label",
    min: -1, max: 1, step: 0.05, default: 0, format: ev, mask: null,
    help: "ctrl.aiHighlights.help",
  },
  {
    key: "aiHdrRange", kind: "range", group: "model", label: "ctrl.aiHdrRange.label",
    min: -1, max: 3, step: 0.1, default: AI_HDR_RANGE_DEFAULT, format: stopsOrAuto(1), mask: null,
    help: "ctrl.aiHdrRange.help",
  },
  {
    key: "aiExpansionStart", kind: "range", group: "model", label: "ctrl.aiExpansionStart.label",
    min: -1, max: 0.75, step: 0.01, default: AI_EXPANSION_START_DEFAULT, format: percentOrAuto, mask: null,
    help: "ctrl.aiExpansionStart.help",
  },
  {
    key: "expansionStart", kind: "range", group: "region", label: "ctrl.expansionStart.label",
    min: 0.18, max: 0.75, step: 0.01, default: 0.25, format: percent, mask: "participation",
    help: "ctrl.expansionStart.help",
  },
  {
    key: "areaCoverage", kind: "range", group: "region", label: "ctrl.areaCoverage.label",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, mask: "coverage",
    help: "ctrl.areaCoverage.help",
  },
  {
    // RAW recovery is a decode policy, not an HDR strength control. Keep Blend
    // pinned for preview/export and normalize older saved photo settings to it.
    // Expert overrides remain available through --highlight-recovery.
    key: "highlightRecovery", kind: "segmented", group: "pinned", label: "ctrl.highlightRecovery.label",
    default: "blend", mask: null,
    help: "ctrl.highlightRecovery.help",
    choices: [["blend", "ctrl.highlightRecovery.blend"],
              ["reconstruct", "ctrl.highlightRecovery.reconstruct"],
              ["clip", "ctrl.highlightRecovery.clip"],
              ["unclip", "ctrl.highlightRecovery.unclip"]],
  },
  /* Pinned. Both are general grading, not extended-range work: a photographer
   * who wants a different contrast curve or more saturation reaches for their
   * editor, not for the converter that writes the gain map. They were also the
   * only two controls that never got a `help` string, which is the clearest
   * signal in this file about which knobs were ever meant to be operated. The
   * values still drive the tone curve and the preview; `HyperDR convert
   * --contrast/--vibrance` remains the way to change them, and 查看命令行 shows
   * the line to start from. */
  {
    key: "contrast", kind: "range", group: "pinned", label: "ctrl.contrast.label",
    min: 0.8, max: 1.35, step: 0.01, default: 1.08, format: fixed(2), mask: null,
  },
  {
    key: "vibrance", kind: "range", group: "pinned", label: "ctrl.vibrance.label",
    min: -0.5, max: 0.5, step: 0.01, default: 0.12, format: signed, mask: null,
  },
  {
    key: "quality", kind: "range", group: "quality", label: "ctrl.quality.label",
    min: 0, max: 100, step: 1, default: 90, mask: null,
  },
];

export const CONTROLS_BY_KEY = new Map(CONTROLS.map((control) => [control.key, control]));

/** Keys that appear in the object sent to /api/run. */
export const OPTION_KEYS = [
  "encoding", "colorGamut", "clampSrgb", "lutId", "lutName", "lutInput", "lutOutput", ...CONTROLS.map((control) => control.key),
];

/** Output and colour choices are workflow settings; image adjustments are per-image. */
export const PERSISTED_OPTION_KEYS = ["encoding", "colorGamut", "clampSrgb"];

export function defaultSettings(encoding = "adaptive") {
  const activeEncoding = encodingById(encoding);
  const values = {
    encoding: activeEncoding.id,
    colorGamut: COLOR_GAMUTS[0].id,
    clampSrgb: false,
    lutId: "", lutName: "", lutInput: "srgb", lutOutput: "srgb",
  };
  for (const control of CONTROLS) values[control.key] = control.default;
  values.hdrRange = Math.min(values.hdrRange, activeEncoding.maxRange);
  values.aiHdrRange = Math.min(values.aiHdrRange, activeEncoding.maxRange);
  return values;
}

/** The exact payload the server's option vocabulary expects. */
export function toOptions(state) {
  const options = {};
  for (const key of OPTION_KEYS) options[key] = state[key];
  return options;
}

/** Validate both device preferences and a recovered photo through one adapter. */
export function validatedSettings(saved, base = defaultSettings()) {
  const values = { ...base };
  if (!saved || typeof saved !== "object") return values;
  if (ENCODINGS.some(({ id }) => id === saved.encoding)) values.encoding = saved.encoding;
  if (COLOR_GAMUTS.some(({ id }) => id === saved.colorGamut)) values.colorGamut = saved.colorGamut;
  if (typeof saved.clampSrgb === "boolean") values.clampSrgb = saved.clampSrgb;
  if (typeof saved.lutId === "string" && /^[0-9a-f]{64}$/.test(saved.lutId)) {
    values.lutId = saved.lutId;
    values.lutName = typeof saved.lutName === "string" ? saved.lutName.slice(0, 160) : "";
  }
  for (const key of ["lutInput", "lutOutput"]) {
    if (["srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine"].includes(saved[key])) values[key] = saved[key];
  }
  for (const control of CONTROLS) {
    if (control.group === "pinned") { values[control.key] = control.default; continue; }
    const value = saved[control.key];
    if (control.choices) {
      if (control.choices.some(([id]) => id === value)) values[control.key] = value;
    } else if (Number.isFinite(value)) {
      const max = ["hdrRange", "aiHdrRange"].includes(control.key)
        ? encodingById(values.encoding).maxRange : control.max;
      values[control.key] = Math.min(max, Math.max(control.min, value));
    }
  }
  const ceiling = encodingById(values.encoding).maxRange;
  values.hdrRange = Math.min(values.hdrRange, ceiling);
  values.aiHdrRange = Math.min(values.aiHdrRange, ceiling);
  return values;
}
