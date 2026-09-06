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

export const ENCODINGS = [
  {
    id: "adaptive", label: "Adaptive HDR", maxRange: 3,
    hint: "Apple 格式，兼容 SDR 设备与系统相册",
  },
  {
    id: "pq", label: "PQ", maxRange: 4,
    hint: "BT.2100 PQ (10-bit)，适合 HDR 显示设备",
  },
  {
    id: "hlg", label: "HLG", maxRange: 2.3,
    hint: "BT.2100 HLG (10-bit)，广播级 HDR",
  },
  {
    id: "ultrahdr", label: "Ultra HDR", maxRange: 4,
    hint: "Google 格式，向后兼容 JPEG，适合网页与 Android",
  },
  {
    id: "avif-pq", label: "AVIF PQ", maxRange: 4,
    hint: "BT.2100 PQ (10-bit AVIF)，适合现代浏览器",
  },
  {
    id: "avif-hlg", label: "AVIF HLG", maxRange: 2.3,
    hint: "BT.2100 HLG (10-bit AVIF)，高效广播级格式",
  },
];

export const encodingById = (id) =>
  ENCODINGS.find((entry) => entry.id === id) || ENCODINGS[0];

const ev = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)} EV`;
const signed = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)}`;
const percent = (value) => `${Math.round(value * 100)}%`;
const fixed = (digits) => (value) => value.toFixed(digits);
const stops = (digits) => (value) => `${value.toFixed(digits)} 档`;

export const DEFAULT_BRIGHTNESS_EV = 0.6;

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
  {
    key: "brightness", kind: "range", group: "tone", label: "整体亮度",
    min: 0, max: 2, step: 0.05, default: DEFAULT_BRIGHTNESS_EV, format: ev, mask: null,
    help: "画面全局曝光微调",
  },
  {
    key: "hdrStrength", kind: "range", group: "tone", label: "HDR 扩展强度",
    min: 0, max: 1, step: 0.05, default: 0.4, format: fixed(2), mask: "gain",
    help: "高光增益强度与通透感，悬停显示作用区域",
  },
  {
    key: "hdrRange", kind: "range", group: "tone", label: "HDR 扩展范围",
    min: 0, max: 3, step: 0.1, default: 2.5, format: stops(1), mask: "gainFull",
    help: "高光动态余量与峰值上限",
  },
  {
    key: "modelStrength", kind: "range", group: "model", label: "优化强度",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, mask: null,
    help: "AI 模型增益应用程度",
  },
  {
    key: "expansionStart", kind: "range", group: "region", label: "扩展起点",
    min: 0.18, max: 0.75, step: 0.01, default: 0.25, format: percent, mask: "participation",
    help: "触发 HDR 扩展的亮度阈值",
  },
  {
    key: "areaCoverage", kind: "range", group: "region", label: "区域覆盖",
    min: 0, max: 1, step: 0.05, default: 1, format: percent, mask: "coverage",
    help: "控制高光扩展偏向镜面还是大面积区域",
  },
  {
    key: "highlightRecovery", kind: "segmented", group: "advanced", label: "高光恢复",
    default: "blend", mask: null,
    help: "RAW 高光重建算法",
    choices: [["blend", "混合"], ["reconstruct", "重建"], ["clip", "裁切"], ["unclip", "不裁切"]],
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
    key: "contrast", kind: "range", group: "pinned", label: "对比度",
    min: 0.8, max: 1.35, step: 0.01, default: 1.08, format: fixed(2), mask: null,
  },
  {
    key: "vibrance", kind: "range", group: "pinned", label: "鲜艳度",
    min: -0.5, max: 0.5, step: 0.01, default: 0.12, format: signed, mask: null,
  },
  {
    key: "quality", kind: "number", group: "quality", label: "质量",
    min: 0, max: 100, step: 1, default: 90, mask: null,
  },
];

export const CONTROLS_BY_KEY = new Map(CONTROLS.map((control) => [control.key, control]));

/** Keys that appear in the object sent to /api/run and /api/curve. */
export const OPTION_KEYS = ["encoding", ...CONTROLS.map((control) => control.key)];

/** The output format is a workflow choice; image adjustments are per-image. */
export const PERSISTED_OPTION_KEYS = ["encoding"];

export function defaultSettings(encoding = ENCODINGS[0].id) {
  const activeEncoding = encodingById(encoding);
  const values = { encoding: activeEncoding.id };
  for (const control of CONTROLS) values[control.key] = control.default;
  values.hdrRange = Math.min(values.hdrRange, activeEncoding.maxRange);
  return values;
}

/** The exact payload the server's option vocabulary expects. */
export function toOptions(state) {
  const options = {};
  for (const key of OPTION_KEYS) options[key] = state[key];
  return options;
}
