/* Builds every control from `schema.js` and keeps it in step with the store.
 *
 * Each widget writes to the store on input and reads back from it on change, so
 * an encoding clamp and a drag take the same path. Nothing
 * outside this module touches a control's DOM.
 */

import { el, role, setPressed, setText } from "../core/dom.js";
import { CONTROLS, ENCODINGS, encodingById } from "./schema.js";

const GROUP_CONTAINERS = {
  tone: "group-tone",
  region: "group-region",
  quality: "group-quality",
  advanced: "group-advanced",
};

/* ── individual widgets ─────────────────────────────────────────────── */

function helpButton(control, hintNode) {
  const button = el("button", {
    class: "field-help", type: "button", "aria-expanded": "false",
    "aria-label": `查看${control.label}说明`,
  }, "?");
  button.addEventListener("click", () => {
    const open = hintNode.hidden;
    // Only one explanation at a time: several open at once pushed the sliders
    // off screen on a phone.
    for (const other of document.querySelectorAll(".field-help[aria-expanded='true']")) {
      other.setAttribute("aria-expanded", "false");
      other.nextHint.hidden = true;
    }
    hintNode.hidden = !open;
    button.setAttribute("aria-expanded", String(open));
  });
  button.nextHint = hintNode;
  return button;
}

function buildRange(control, store) {
  const readout = el("span", { class: "field-value" });
  const input = el("input", {
    type: "range", min: control.min, max: control.max, step: control.step,
    "aria-label": control.label,
  });
  const hint = control.help ? el("p", { class: "field-hint", hidden: true }, control.help) : null;

  const title = el("span", { class: "field-title" },
    el("b", {}, control.label),
    hint ? helpButton(control, hint) : null);

  const node = el("div", { class: "field field-range" },
    el("div", { class: "field-head" }, title, readout),
    input,
    control.scale
      ? el("div", { class: "field-scale" }, el("span", {}, control.scale[0]), el("span", {}, control.scale[1]))
      : null,
    hint);

  input.addEventListener("input", () => store.set({ [control.key]: Number(input.value) }));

  /* While a thumb is under the pointer the element owns its own `value`: the
   * browser has already moved it to where the finger is. Writing the same
   * number back on the next microtask re-seats the thumb from script, which
   * reads as a stutter whenever the round-trip lands mid-gesture -- and if the
   * store clamped the value, as a visible snap-back. So the writeback is
   * suppressed for the duration of the drag and replayed once on release,
   * which is the only moment a clamp still needs to be shown. */
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
  return { node, apply, watches: [control.key, "encoding"] };
}

function buildSelect(control, store) {
  const select = el("select", { "aria-label": control.label },
    ...control.choices.map(([value, label]) => el("option", { value }, label)));
  select.addEventListener("change", () => store.set({ [control.key]: select.value }));
  const node = el("label", { class: "field" },
    el("span", { class: "field-label" }, control.label), select);
  return {
    node,
    apply: (state) => { if (select.value !== state[control.key]) select.value = state[control.key]; },
    watches: [control.key],
  };
}

function buildSegmented(control, store) {
  const picker = el("div", {
    class: "segmented field-segmented",
    role: "group",
    "aria-label": control.label,
  });
  const buttons = control.choices.map(([value, label]) => {
    const button = el("button", {
      type: "button",
      "aria-pressed": "false",
    }, label);
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

function buildNumber(control, store) {
  const input = el("input", {
    type: "number", min: control.min, max: control.max, step: control.step,
    "aria-label": control.label,
  });
  const commit = () => {
    const parsed = Number(input.value);
    if (!Number.isFinite(parsed)) { input.value = String(store.value(control.key)); return; }
    store.set({ [control.key]: Math.min(control.max, Math.max(control.min, Math.round(parsed))) });
  };
  input.addEventListener("change", commit);
  const node = el("label", { class: "field" },
    el("span", { class: "field-label" }, control.label), input);
  return {
    node,
    apply: (state) => { input.value = String(state[control.key]); },
    watches: [control.key],
  };
}

function buildSwitch(control, store) {
  const button = el("button", { class: "switch", type: "button", role: "switch" },
    el("span", { class: "switch-track", "aria-hidden": "true" }), el("span", {}, control.label));
  button.addEventListener("click", () => {
    const next = !store.value(control.key);
    const patch = { [control.key]: next };
    // Overwrite and skip-existing contradict each other; turning one on has to
    // turn the other off or the command line carries both flags.
    if (next && control.excludes) patch[control.excludes] = false;
    store.set(patch);
  });
  return {
    node: button,
    apply: (state) => setPressed(button, state[control.key], { aria: "aria-checked" }),
    watches: [control.key],
  };
}

const BUILDERS = {
  range: buildRange,
  select: buildSelect,
  segmented: buildSegmented,
  number: buildNumber,
  switch: buildSwitch,
};

/* ── encoding picker & histogram mode ───────────────────────────────── */

function mountEncoding(store) {
  const container = role("encoding");
  const hint = role("encoding-hint");
  const buttons = ENCODINGS.map((entry) => {
    const button = el("button", { type: "button", "aria-pressed": "false" }, entry.label);
    button.addEventListener("click", () => {
      const max = entry.maxRange;
      store.set({
        encoding: entry.id,
        // Clamped here rather than in the slider so the stored value and the
        // command line agree the moment the format changes.
        hdrRange: Math.min(store.value("hdrRange"), max),
      });
    });
    return [entry, button];
  });
  container.append(...buttons.map(([, button]) => button));

  store.watch(["encoding"], (state) => {
    const active = encodingById(state.encoding);
    for (const [entry, button] of buttons) setPressed(button, entry.id === active.id);
    setText(hint, active.hint);
  });
}

function mountHistogramMode(store) {
  const container = role("hist-mode");
  if (!container) return;
  const modes = [["luma", "亮度"], ["rgb", "RGB"]];
  const buttons = modes.map(([id, label]) => {
    const button = el("button", { type: "button", "aria-pressed": "false" }, label);
    button.addEventListener("click", () => store.set({ histMode: id }));
    return [id, button];
  });
  container.append(...buttons.map(([, button]) => button));
  store.watch(["histMode"], (state) => {
    for (const [id, button] of buttons) setPressed(button, id === state.histMode);
  });
}

/* ── entry point ────────────────────────────────────────────────────── */

export function mountControls(store) {
  mountEncoding(store);
  mountHistogramMode(store);

  const containers = new Map(
    Object.entries(GROUP_CONTAINERS).map(([group, name]) => [group, role(name)]));

  for (const control of CONTROLS) {
    const container = containers.get(control.group);
    if (!container) continue;
    const widget = BUILDERS[control.kind](control, store);
    container.append(widget.node);
    store.watch(widget.watches, widget.apply);
  }
}
