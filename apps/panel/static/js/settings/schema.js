/* The panel's controls, declared as data.
 *
 * Previously each setting existed three times: as hand-written markup in
 * index.html, as a `$("id").value` read inside `opts()`, and as a line in a
 * 20-statement `sync()` that formatted its display value. Adding a slider meant
 * editing all three, and the three had already drifted --
 * `sync()` formatted controls that `opts()` never sent. One declaration per
 * control now drives the markup, the option object, and the readout, so those
 * cannot disagree.
 *
 * Four controls were removed when the panel became single-image. "并行文件数"
 * and "跳过已是最新的输出" only meant something for a folder pass; "覆盖已存在
 * 的输出" never did anything, because the output directory is emptied before
 * every run; and "导出后校验" is not a preference -- verification is what stops
 * a broken gain map from reaching the disk, so it is always on.
 */

export const ENCODINGS = [
  {
    id: "adaptive", label: "增益图", maxRange: 3,
    hint: "Apple Adaptive HDR：Display P3 SDR 底图 + ISO 21496-1 增益图，最适合系统相册与分享。",
  },
  {
    id: "pq", label: "PQ", maxRange: 4,
    hint: "PQ (HDR10)：BT.2100 / ST 2084 10-bit HEIC，适合 HDR10 电视与显示器。",
  },
  {
    id: "hlg", label: "HLG", maxRange: 2.3,
    hint: "HLG：BT.2100 HLG 10-bit HEIC，适合广播级 HDR 工作流；标准 1000-nit 映射最多约 2.3 stops。",
  },
  {
    id: "ultrahdr", label: "Ultra HDR", maxRange: 4,
    hint: "Google Ultra HDR：向后兼容的 JPEG/R，内含 Display P3 SDR 底图、增益图，以及 Ultra HDR v1 + ISO 21496-1 元数据。",
  },
  {
    id: "avif-pq", label: "AVIF PQ", maxRange: 4,
    hint: "AVIF (PQ)：BT.2100 / ST 2084 10-bit AVIF，与 pq 渲染完全一致，适合 Chrome 与 Android。",
  },
  {
    id: "avif-hlg", label: "AVIF HLG", maxRange: 2.3,
    hint: "AVIF (HLG)：BT.2100 HLG 10-bit AVIF；同样最多约 2.3 stops。",
  },
];

export const encodingById = (id) =>
  ENCODINGS.find((entry) => entry.id === id) || ENCODINGS[0];

const ev = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)} EV`;
const signed = (value) => `${value > 0 ? "+" : ""}${value.toFixed(2)}`;
const percent = (value) => `${Math.round(value * 100)}%`;
const fixed = (digits) => (value) => value.toFixed(digits);

/* `group` selects the container the control renders into; `kind` selects the
 * widget. `key` is both the store key and the name sent to /api/run. */
export const CONTROLS = [
  {
    key: "brightness", kind: "range", group: "tone", label: "整体亮度",
    min: 0, max: 2, step: 0.05, default: 1, format: ev,
    scale: ["0 EV", "+2 EV"],
    help: "在自动曝光基础上偏移整张画面，同时作用于 SDR 底图与 HDR 输出。",
  },
  {
    key: "hdrStrength", kind: "range", group: "tone", label: "HDR 扩展强度",
    min: 0, max: 1, step: 0.05, default: 0.4, format: fixed(2),
    scale: ["自然", "鲜明"],
    help: "控制高光增益与整体通透感。",
  },
  {
    key: "hdrRange", kind: "range", group: "tone", label: "HDR 扩展范围",
    min: 0, max: 3, step: 0.1, default: 2.5, format: fixed(1),
    scale: ["0 stop", "最大余量"],
    help: "高于 SDR 参考白的亮度余量；强度与范围共同决定最终峰值。上限随输出格式变化。",
  },
  {
    key: "expansionStart", kind: "range", group: "region", label: "扩展起点",
    min: 0.18, max: 0.75, step: 0.01, default: 0.25, format: percent,
    scale: ["中间调", "极亮高光"],
    help: "数值越低，越多上部中间调和亮部参与扩展。",
  },
  {
    key: "areaCoverage", kind: "range", group: "region", label: "区域覆盖",
    min: 0, max: 1, step: 0.05, default: 1, format: percent,
    scale: ["局部亮点", "均匀亮部"],
    help: "扩展偏向镜面亮点，还是覆盖更大面积的明亮色调。",
  },
  {
    key: "contrast", kind: "range", group: "advanced", label: "对比度",
    min: 0.8, max: 1.35, step: 0.01, default: 1.08, format: fixed(2),
  },
  {
    key: "vibrance", kind: "range", group: "advanced", label: "鲜艳度",
    min: -0.5, max: 0.5, step: 0.01, default: 0.12, format: signed,
  },
  {
    key: "highlightRecovery", kind: "segmented", group: "tone", label: "高光恢复",
    default: "blend",
    choices: [["blend", "混合"], ["reconstruct", "重建"], ["clip", "裁切"], ["unclip", "不裁切"]],
  },
  {
    key: "quality", kind: "number", group: "quality", label: "编码质量",
    min: 0, max: 100, step: 1, default: 90,
  },
];

export const CONTROLS_BY_KEY = new Map(CONTROLS.map((control) => [control.key, control]));

/** Keys that appear in the object sent to /api/run, /api/command and /api/curve. */
export const OPTION_KEYS = ["encoding", ...CONTROLS.map((control) => control.key)];

export function defaultSettings() {
  const values = { encoding: ENCODINGS[0].id };
  for (const control of CONTROLS) values[control.key] = control.default;
  return values;
}

/** The exact payload the server's option vocabulary expects. */
export function toOptions(state) {
  const options = {};
  for (const key of OPTION_KEYS) options[key] = state[key];
  return options;
}
