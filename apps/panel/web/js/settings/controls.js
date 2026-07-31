/* Builds every control from `schema.js` and keeps it in step with the store.
 *
 * Each widget writes to the store on input and reads back from it on change, so
 * an encoding clamp, a preset, a group reset and a drag all take the same path.
 * Nothing outside this module touches a control's DOM.
 */

import { el, role, setPressed, setText, clamp } from "../core/dom.js";
import { store } from "../core/store.js";
import { CONTROLS, ENCODINGS, encodingById } from "./schema.js";

const GROUP_CONTAINERS = {
  tone: "group-tone",
  region: "group-region",
  advanced: "group-advanced",
  quality: "group-quality",
};

const hdrRangeCeiling = () =>
  encodingById(store.get().encoding).maxRange;

/** A patch of group defaults, with the range slider clamped to the encoding. */
function defaultsFor(keys) {
  const patch = {};
  for (const control of CONTROLS) {
    if (!keys.includes(control.key)) continue;
    patch[control.key] = control.key === "hdrRange"
      ? Math.min(control.default, hdrRangeCeiling())
      : control.default;
  }
  return patch;
}

/* ── mask hover: the stage reads `maskKey` and paints the overlay ────── */

function wireMask(trigger, control) {
  if (!trigger || !control.mask) return;
  trigger.maskMouseHovered = false;
  const show = () => store.set({ maskKey: control.key });
  const hide = () => {
    if (store.get().maskKey === control.key) store.set({ maskKey: null });
  };
  // Mouse users get a transient preview on hover. Touch and keyboard users
  // keep it visible by opening the explanation with the same button.
  trigger.addEventListener("pointerenter", (event) => {
    if (event.pointerType !== "mouse") return;
    trigger.maskMouseHovered = true;
    show();
  });
  trigger.addEventListener("pointerleave", (event) => {
    if (event.pointerType !== "mouse") return;
    trigger.maskMouseHovered = false;
    if (trigger.getAttribute("aria-expanded") !== "true") hide();
  });
  trigger.addEventListener("focus", show);
  trigger.addEventListener("blur", () => {
    if (trigger.getAttribute("aria-expanded") !== "true") hide();
  });
  window.addEventListener("blur", hide);
}

/* ── individual widgets ─────────────────────────────────────────────── */

function helpButton(control, hintNode) {
  const button = el("button", {
    class: "field-help", type: "button", "aria-expanded": "false",
    "aria-label": `查看${control.label}说明`,
    title: control.mask ? "悬停显示预计作用区域；点击查看说明" : null,
  }, "?");
  button.addEventListener("click", () => {
    const open = hintNode.hidden;
    if (store.get().maskKey) store.set({ maskKey: null });
    // Only one explanation at a time: several open at once pushed the sliders
    // off screen on a phone.
    for (const other of document.querySelectorAll(".field-help[aria-expanded='true']")) {
      other.setAttribute("aria-expanded", "false");
      other.nextHint.hidden = true;
    }
    hintNode.hidden = !open;
    button.setAttribute("aria-expanded", String(open));
    const keepMask = open || button.maskMouseHovered === true ||
      button.matches(":focus-visible");
    if (control.mask && keepMask) store.set({ maskKey: control.key });
  });
  button.nextHint = hintNode;
  return button;
}

function buildRange(control) {
  const readout = el("span", { class: "field-value" });
  const input = el("input", {
    type: "range", min: control.min, max: control.max, step: control.step,
    "aria-label": control.label,
  });
  const hint = control.help ? el("p", { class: "field-hint", hidden: true }, control.help) : null;
  const help = hint ? helpButton(control, hint) : null;

  const title = el("span", { class: "field-title" },
    el("b", {}, control.label),
    help);

  const node = el("div", { class: "field field--range" },
    el("div", { class: "field-head" }, title, readout),
    input,
    control.scale
      ? el("div", { class: "field-scale" }, el("span", {}, control.scale[0]), el("span", {}, control.scale[1]))
      : null,
    hint);

  input.addEventListener("input", () => store.set({ [control.key]: Number(input.value) }));

  /* Double-click returns to the schema default -- the discoverable cousin of
   * the group reset, for the slider you are already touching. Shift+arrow
   * nudges ten steps for the times the track's pixels are too coarse. */
  input.addEventListener("dblclick", () => {
    const value = control.key === "hdrRange"
      ? Math.min(control.default, hdrRangeCeiling())
      : control.default;
    store.set({ [control.key]: value });
  });
  input.addEventListener("keydown", (event) => {
    if (!event.shiftKey) return;
    const direction = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1 }[event.key];
    if (!direction) return;
    event.preventDefault();
    const current = store.get()[control.key];
    const max = control.key === "hdrRange" ? hdrRangeCeiling() : control.max;
    const next = clamp(current + direction * control.step * 10, control.min, max);
    store.set({ [control.key]: Number(next.toFixed(4)) });
  });

  /* While a thumb is under the pointer the element owns its own `value`: the
   * browser has already moved it to where the finger is. Writing the same
   * number back on the next microtask re-seats the thumb from script, which
   * reads as a stutter whenever the round-trip lands mid-gesture. So the
   * writeback is suppressed for the duration of the drag and replayed once on
   * release, which is the only moment a clamp still needs to be shown. */
  let dragging = false;
  let lastFill = "";
  let lastMax = "";

  input.addEventListener("pointerdown", () => { dragging = true; });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    apply(store.get());
  };
  // The pointer can be released anywhere -- outside the track, outside the
  // window -- so release is watched on the window rather than the input.
  window.addEventListener("pointerup", endDrag);
  window.addEventListener("pointercancel", endDrag);
  window.addEventListener("blur", endDrag);

  const apply = (state) => {
    const value = state[control.key];
    // The encoding clamps the headroom ceiling, so `max` is dynamic.
    const max = control.key === "hdrRange" ? encodingById(state.encoding).maxRange : control.max;
    // Assigning `max` reconfigures the control even when the number is
    // unchanged, so it is written only on an actual change.
    const maxText = String(max);
    if (lastMax !== maxText) { lastMax = maxText; input.max = maxText; }
    if (!dragging && input.value !== String(value)) input.value = String(value);
    setText(readout, (control.format || String)(value));
    const fill = ((value - control.min) / (max - control.min)) * 100;
    const fillText = `${Math.min(100, Math.max(0, fill)).toFixed(1)}%`;
    if (lastFill !== fillText) { lastFill = fillText; input.style.setProperty("--fill", fillText); }
  };
  wireMask(help, control);
  return { node, apply, watches: [control.key, "encoding"] };
}

function buildSegmented(control) {
  const picker = el("div", {
    class: "segmented",
    role: "group",
    "aria-label": control.label,
  });
  const buttons = control.choices.map(([value, label]) => {
    const button = el("button", { type: "button", "aria-pressed": "false" }, label);
    button.addEventListener("click", () => store.set({ [control.key]: value }));
    picker.append(button);
    return [value, button];
  });
  const node = el("div", { class: "field" },
    el("span", { class: "field-label" }, control.label),
    picker);
  return {
    node,
    apply: (state) => {
      for (const [value, button] of buttons) {
        setPressed(button, value === state[control.key]);
      }
    },
    watches: [control.key],
  };
}

function buildNumber(control) {
  const input = el("input", {
    type: "number", min: control.min, max: control.max, step: control.step,
    "aria-label": control.label,
  });
  const commit = () => {
    const parsed = Number(input.value);
    if (!Number.isFinite(parsed)) { input.value = String(store.get()[control.key]); return; }
    store.set({ [control.key]: clamp(Math.round(parsed), control.min, control.max) });
  };
  input.addEventListener("change", commit);
  const node = el("label", { class: "field field--inline" },
    el("span", { class: "field-label" }, control.label), input);
  return {
    node,
    apply: (state) => { input.value = String(state[control.key]); },
    watches: [control.key],
  };
}

const BUILDERS = {
  range: buildRange,
  segmented: buildSegmented,
  number: buildNumber,
};

/* ── encoding select (lives in the dock, wired here with the settings) ── */

function mountEncoding() {
  const container = role("encoding");
  const hint = role("encoding-hint");
  const buttons = new Map();

  for (const entry of ENCODINGS) {
    const button = el("button", { type: "button", "aria-pressed": "false" }, entry.label);
    button.addEventListener("click", () => store.set({
      encoding: entry.id,
      // Clamped here rather than in the slider so the stored value and the
      // command line agree the moment the format changes.
      hdrRange: Math.min(store.get().hdrRange, entry.maxRange),
    }));
    buttons.set(entry.id, button);
    container.append(button);
  }

  store.watch("encoding", (id) => {
    const active = encodingById(id);
    for (const [key, button] of buttons) {
      button.setAttribute("aria-pressed", String(key === active.id));
    }
    setText(hint, active.hint);
  }, { immediate: true });
}

/* ── reset ──────────────────────────────────────────────────────────── */

function mountResets() {
  const wire = (button, keys) =>
    button.addEventListener("click", () => store.set(defaultsFor(keys)));
  /* "重置全部" covers the image controls, not the output format: the encoding
   * is a workflow decision (where will this file be shown?), not part of the
   * look being dialled in. */
  wire(role("settings-reset"), CONTROLS.map((control) => control.key));
}

/* ── entry point ────────────────────────────────────────────────────── */

export function mountControls() {
  mountEncoding();
  mountResets();

  const containers = new Map(
    Object.entries(GROUP_CONTAINERS).map(([group, name]) => [group, role(name)]));

  for (const control of CONTROLS) {
    const container = containers.get(control.group);
    if (!container) continue;
    const widget = BUILDERS[control.kind](control);
    container.append(widget.node);
    store.watchAny(widget.watches, widget.apply, { immediate: true });
  }
}
