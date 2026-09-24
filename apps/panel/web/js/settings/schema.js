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

/* `detail` is the second line of the format card: the container, and the one
 * property that separates it from its neighbours. `hint` is the sentence shown
 * under the grid for the selected format. */
export const ENCODINGS = [
  { id: "sdr-jpeg", label: "JPEG", maxRange: 4, hint: "enc.sdr-jpeg.hint", detail: "enc.sdr-jpeg.detail" },
  { id: "sdr-tiff", label: "16-bit TIFF", maxRange: 4, hint: "enc.sdr-tiff.hint", detail: "enc.sdr-tiff.detail" },
  {
    id: "adaptive", label: "Adaptive HDR", maxRange: 3,
    hint: "enc.adaptive.hint", detail: "enc.adaptive.detail",
  },
  {
    id: "pq", label: "PQ", maxRange: 4,
    hint: "enc.pq.hint", detail: "enc.pq.detail",
  },
  {
    id: "hlg", label: "HLG", maxRange: 2.3,
    hint: "enc.hlg.hint", detail: "enc.hlg.detail",
  },
  {
    id: "ultrahdr", label: "Ultra HDR", maxRange: 4,
    hint: "enc.ultrahdr.hint", detail: "enc.ultrahdr.detail",
  },
  {
    id: "avif-pq", label: "AVIF PQ", maxRange: 4,
    hint: "enc.avif-pq.hint", detail: "enc.avif-pq.detail",
  },
  {
    id: "avif-hlg", label: "AVIF HLG", maxRange: 2.3,
    hint: "enc.avif-hlg.hint", detail: "enc.avif-hlg.detail",
  },
];

export const COLOR_GAMUTS = [
  { id: "srgb", label: "sRGB", hint: "out.gamutHint.srgb" },
  { id: "p3", label: "Display P3", hint: "out.gamutHint.p3" },
  { id: "rec2020", label: "Rec.2020", hint: "out.gamutHint.rec2020" },
];

export const encodingById = (id) =>
  ENCODINGS.find((entry) => entry.id === id) || ENCODINGS.find((entry) => entry.id === "adaptive");
export const isSdrEncoding = (id) => id === "sdr-jpeg" || id === "sdr-tiff";
export const effectiveOutputGamut = (encoding, choice = "auto") =>
  choice === "auto" ? (encoding === "sdr-tiff" ? "p3" : "srgb") : choice;
export const outputDescription = (encoding, choice = "auto") => {
  const gamut = effectiveOutputGamut(encoding, choice) === "p3" ? "Display P3" : "sRGB";
  if (encoding === "sdr-jpeg") return `JPEG · ${gamut} · ${t("out.bit8")}`;
  if (encoding === "sdr-tiff") return `TIFF · ${gamut} · ${t("out.bit16")}`;
  if (encoding === "adaptive") return `HEIC · Display P3 ${t("out.gainBase")}`;
  if (encoding === "ultrahdr") return `JPEG · Display P3 ${t("out.gainBase")}`;
  if (encoding === "pq" || encoding === "avif-pq") return `${encoding === "pq" ? "HEIC" : "AVIF"} · Rec.2020 · PQ · ${t("out.bit10")}`;
  return `${encoding === "hlg" ? "HEIC" : "AVIF"} · Rec.2020 · HLG · ${t("out.bit10")}`;
};

const ev = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)} EV`;
const signed = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)}`;
const percent = (value) => `${Math.round(value * 100)}%`;
const fixed = (digits) => (value) => value.toFixed(digits);
const stops = (digits) => (value) => t("unit.stops", { value: value.toFixed(digits) });
const stopsOrAuto = (digits) => (value) =>
  value < 0 ? t("unit.auto") : t("unit.stops", { value: value.toFixed(digits) });
const percentOrAuto = (value) => value < 0 ? t("unit.auto") : `${Math.round(value * 100)}%`;

export const DEFAULT_BRIGHTNESS_EV = 0.6;

/* The model-id contract lives in settings/model-ids.js: it is a set of decisions
 * with no imports, and the compatibility rule it contains is worth testing on
 * its own. It is re-exported here so callers keep one import site. */
export {
  DEFAULT_MODEL_ID, MODEL_KEY, availableModelIds, restoredModelId,
} from "./model-ids.js";
import { DEFAULT_MODEL_ID, MODEL_KEY, restoredModelId } from "./model-ids.js";

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
 * `unit: "percent"` says the readout multiplies by 100, so a typed 25 means
 * 0.25; `auto: true` says a negative value is the "automatic" setting, which
 * the typed field accepts as the word itself.
 *
 * `group: "pinned"` is a setting with no widget. It still seeds the store, is
 * still read by the renderers, and is still sent to /api/run -- it simply is
 * not adjustable. That is not the same as deleting it: curve-math.js takes
 * `contrast` as an argument and stage/scope/mask all watch it, so a deleted key
 * would reach the tone curve as `undefined`. Pinned controls use neutral values (command.py's PANEL_DEFAULTS agrees),
 * so hidden contrast and vibrance do not add an unrequested grade. */
export const CONTROLS = [
  { key: "lutStrength", kind: "range", group: "lut", label: "lut.strength",
    min: 0, max: 1, step: 0.01, default: 1, format: percent, unit: "percent", mask: null, help: "lut.strengthHint" },
  {
    key: "brightness", kind: "range", group: "tone", label: "ctrl.brightness.label",
    min: -2, max: 2, step: 0.05, default: DEFAULT_BRIGHTNESS_EV, format: ev, mask: null,
    help: "ctrl.brightness.help",
  },
  {
    key: "hdrStrength", kind: "range", group: "tone", label: "ctrl.hdrStrength.label",
    min: 0, max: 1, step: 0.05, default: 0.4, format: percent, unit: "percent", mask: "gain",
    help: "ctrl.hdrStrength.help",
  },
  {
    key: "hdrRange", kind: "range", group: "tone", label: "ctrl.hdrRange.label",
    min: 0, max: 3, step: 0.1, default: 2.5, format: stops(1), mask: "gainFull",
    help: "ctrl.hdrRange.help",
  },
  {
    key: "modelStrength", kind: "range", group: "model", label: "ctrl.modelStrength.label",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, unit: "percent", mask: null,
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
    min: -1, max: 3, step: 0.1, default: AI_HDR_RANGE_DEFAULT, format: stopsOrAuto(1), auto: true, mask: null,
    help: "ctrl.aiHdrRange.help",
  },
  {
    key: "aiExpansionStart", kind: "range", group: "model", label: "ctrl.aiExpansionStart.label",
    min: -1, max: 0.75, step: 0.01, default: AI_EXPANSION_START_DEFAULT, format: percentOrAuto,
    unit: "percent", auto: true, mask: null,
    help: "ctrl.aiExpansionStart.help",
  },
  {
    key: "expansionStart", kind: "range", group: "region", label: "ctrl.expansionStart.label",
    min: 0.18, max: 0.75, step: 0.01, default: 0.25, format: percent, unit: "percent", mask: "participation",
    help: "ctrl.expansionStart.help",
  },
  {
    key: "areaCoverage", kind: "range", group: "region", label: "ctrl.areaCoverage.label",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, unit: "percent", mask: "coverage",
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
    min: 0.8, max: 1.35, step: 0.01, default: 1, format: fixed(2), mask: null,
  },
  {
    key: "vibrance", kind: "range", group: "pinned", label: "ctrl.vibrance.label",
    min: -0.5, max: 0.5, step: 0.01, default: 0, format: signed, mask: null,
  },
  {
    key: "quality", kind: "range", group: "quality", label: "ctrl.quality.label",
    min: 0, max: 100, step: 1, default: 90, mask: null,
  },
];

export const CONTROLS_BY_KEY = new Map(CONTROLS.map((control) => [control.key, control]));

/** Keys that appear in the object sent to /api/run. */
export const OPTION_KEYS = [
  "encoding", "hevcPreset", "colorGamut", "outputGamut", "clampSrgb", "rawProfile", "rawProfileName", "rawLook", "rawLookName", "lensCorrection", "lensProfileName", "lutId", "lutName", "lutInput", "lutOutput", MODEL_KEY, ...CONTROLS.map((control) => control.key),
];

/** Output, colour and model choices are workflow settings; image adjustments
 *  are per-image. The model is here because it is the same kind of decision as
 *  the output format -- "how should this be processed" rather than "how should
 *  it look" -- and because persisting it is what keeps a refresh from quietly
 *  re-pointing the next export at a different algorithm. */
export const PERSISTED_OPTION_KEYS = ["encoding", "hevcPreset", "colorGamut", "outputGamut", "clampSrgb", MODEL_KEY];

/* The decoder reports single-HDR and authored SDR+HDR photographs separately. */
export const HDR_SOURCE_DOMAIN = "display-referred-hdr";
export const DUAL_SOURCE_DOMAIN = "dual-rendition";
export const isHdrSource = (domain) =>
  domain === HDR_SOURCE_DOMAIN || domain === DUAL_SOURCE_DOMAIN;

/* An HDR photograph's own rendering, expressed in the manual controls. The
 * controls describe a change to the picture, so for an HDR source zero change
 * is: no exposure offset, the full strength of its own highlights, and a range
 * ceiling that does not cut into them (the format's maximum; the renderer never
 * extends past what the file declares). Strength and range are the two
 * controls whose identity sits at the top of the slider rather than at zero. */
function sourceIdentity(values, encoding, unadjusted) {
  if (!unadjusted) return values;
  return { ...values, ...unadjusted,
    hdrRange: Math.min(unadjusted.hdrRange, encodingById(encoding).maxRange),
    contrast: 1, vibrance: 0 };
}

/** What a newly opened photo starts from. An SDR or RAW photo gets the modest
 *  enhancement preset; an HDR photo opens as itself. */
export function defaultSettings(encoding = "adaptive", sourceDomain = "", unadjusted = null) {
  const activeEncoding = encodingById(encoding);
  const values = {
    encoding: activeEncoding.id,
    hevcPreset: "slow",
    colorGamut: COLOR_GAMUTS[0].id,
    outputGamut: "auto",
    clampSrgb: false,
    rawProfile: "", rawProfileName: "", rawLook: "", rawLookName: "", lensCorrection: true, lensProfileName: "",
    lutId: "", lutName: "", lutInput: "srgb", lutOutput: "srgb",
    [MODEL_KEY]: DEFAULT_MODEL_ID,
  };
  for (const control of CONTROLS) values[control.key] = control.default;
  if (isSdrEncoding(activeEncoding.id)) values.brightness = 0;
  values.hdrRange = Math.min(values.hdrRange, activeEncoding.maxRange);
  values.aiHdrRange = Math.min(values.aiHdrRange, activeEncoding.maxRange);
  return isHdrSource(sourceDomain) ? sourceIdentity(values, activeEncoding.id, unadjusted) : values;
}

/** No creative adjustment; RAW still receives its fixed base development, and
 *  an HDR photo keeps its own highlights rather than being flattened to SDR. */
export function neutralSettings(encoding = "adaptive", sourceDomain = "", unadjusted = null) {
  const neutral = { ...defaultSettings(encoding), brightness: 0, hdrStrength: 0, hdrRange: 0,
    contrast: 1, vibrance: 0, areaCoverage: 0, lutStrength: 0 };
  return sourceIdentity(neutral, encoding, unadjusted);
}

/** The request behind the "original" comparison, made before the photo's
 *  domain is known. Its SDR base is the untouched development for every
 *  domain -- HDR strength and range never move an SDR or RAW base -- and for an
 *  HDR photo the whole frame is the photograph itself. */
export function referenceSettings(encoding = "adaptive") {
  // Before decoding, ask the renderer for full available headroom. The returned
  // packet supplies the input's authoritative unadjusted control values.
  return { ...neutralSettings(encoding), hdrStrength: 1,
    hdrRange: encodingById(encoding).maxRange };
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
  values[MODEL_KEY] = restoredModelId(saved);
  if (ENCODINGS.some(({ id }) => id === saved.encoding)) values.encoding = saved.encoding;
  if (["slow", "medium"].includes(saved.hevcPreset)) values.hevcPreset = saved.hevcPreset;
  if (COLOR_GAMUTS.some(({ id }) => id === saved.colorGamut)) values.colorGamut = saved.colorGamut;
  if (["auto", "srgb", "p3"].includes(saved.outputGamut)) values.outputGamut = saved.outputGamut;
  if (typeof saved.lensCorrection === "boolean") values.lensCorrection = saved.lensCorrection;
  if (typeof saved.lensProfileName === "string") values.lensProfileName = saved.lensProfileName.slice(0, 160);
  if (typeof saved.clampSrgb === "boolean") values.clampSrgb = saved.clampSrgb;
  if (typeof saved.rawProfile === "string" && /^[0-9a-f]{64}$/.test(saved.rawProfile)) {
    values.rawProfile = saved.rawProfile;
    values.rawProfileName = typeof saved.rawProfileName === "string" ? saved.rawProfileName.slice(0, 160) : "";
  }
  if (values.rawProfile && typeof saved.rawLook === "string" && /^[0-9a-f]{64}$/.test(saved.rawLook)) {
    values.rawLook = saved.rawLook;
    values.rawLookName = typeof saved.rawLookName === "string" ? saved.rawLookName.slice(0, 160) : "";
  }
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
