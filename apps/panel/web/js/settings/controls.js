/* Builds every control from `schema.js` and keeps it in step with the store.
 *
 * Each widget writes to the store on input and reads back from it on change, so
 * an encoding clamp, a preset, a group reset and a drag all take the same path.
 * Nothing outside this module touches a control's DOM.
 */

import { el, role, setPressed, setText, clamp } from "../core/dom.js";
import { store } from "../core/store.js";
import { COLOR_GAMUTS, CONTROLS, ENCODINGS, encodingById } from "./schema.js";
import { t, onLocaleChange } from "../i18n/index.js";

/* Widgets are built once and mutated thereafter, so a language change has to
 * be pushed into the nodes that already exist. Each builder registers what it
 * needs re-read here; mountControls runs the list on every locale change. */
const relabels = [];
const relabel = (fn) => { relabels.push(fn); fn(); };

const GROUP_CONTAINERS = {
  tone: "group-tone",
  model: "group-model",
  region: "group-region",
  advanced: "group-advanced",
  quality: "group-quality",
};

const hdrRangeCeiling = () =>
  encodingById(store.get().encoding).maxRange;

const isHdrRange = (key) => key === "hdrRange" || key === "aiHdrRange";

/** A patch of group defaults, with the range slider clamped to the encoding. */
function defaultsFor(keys) {
  const patch = {};
  for (const control of CONTROLS) {
    if (!keys.includes(control.key)) continue;
    patch[control.key] = isHdrRange(control.key)
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
  /* `aria-expanded` on its own says something is open without saying what.
   * The key is unique per control, so it is the id, and the pairing survives
   * a control being added or reordered in schema.js. */
  hintNode.id = `field-hint-${control.key}`;
  const button = el("button", {
    class: "field-help", type: "button", "aria-expanded": "false",
    "aria-controls": hintNode.id,
    "aria-label": t("adjust.help", { label: t(control.label) }),
    title: control.mask ? t("adjust.helpMask") : null,
  }, "?");
  relabel(() => {
    button.setAttribute("aria-label", t("adjust.help", { label: t(control.label) }));
    if (control.mask) button.title = t("adjust.helpMask");
  });
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
    "aria-label": t(control.label),
  });
  const hint = control.help ? el("p", { class: "field-hint", hidden: true }, t(control.help)) : null;
  const help = hint ? helpButton(control, hint) : null;

  const name = help || el("b");
  if (help) help.classList.add("field-label-help");
  const title = el("span", { class: "field-title" }, name);
  relabel(() => {
    setText(name, t(control.label));
    if (hint) setText(hint, t(control.help));
    input.setAttribute("aria-label", t(control.label));
  });

  const scaleStart = el("span");
  const scaleEnd = el("span");
  const scale = control.group === "tone" || ["modelStrength", "aiBrightness", "aiHdrRange"].includes(control.key) ? el("div", { class: "range-scale", "aria-hidden": "true" }, scaleStart, scaleEnd) : null;
  const node = el("div", { class: "field field--range" },
    el("div", { class: "field-head" }, title, readout),
    input, scale,
    hint);

  input.addEventListener("input", () => store.set({ [control.key]: Number(input.value) }));

  /* Double-click returns to the schema default -- the discoverable cousin of
   * the group reset, for the slider you are already touching. Shift+arrow
   * nudges ten steps for the times the track's pixels are too coarse. */
  input.addEventListener("dblclick", () => {
    const value = isHdrRange(control.key)
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
    const max = isHdrRange(control.key) ? hdrRangeCeiling() : control.max;
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
    const max = isHdrRange(control.key) ? encodingById(state.encoding).maxRange : control.max;
    // Assigning `max` reconfigures the control even when the number is
    // unchanged, so it is written only on an actual change.
    const maxText = String(max);
    if (lastMax !== maxText) { lastMax = maxText; input.max = maxText; }
    if (!dragging && input.value !== String(value)) input.value = String(value);
    setText(readout, (control.format || String)(value));
    if (scale) {
      const ends = control.key === "brightness" ? [t("inspector.natural"), t("inspector.bright")]
        : control.key === "hdrStrength" ? [t("inspector.soft"), t("inspector.vivid")]
        : control.group === "model" ? [control.format(control.min), control.format(max)]
        : [t("unit.stops", { value: "0" }), t("unit.stops", { value: String(max) })];
      setText(scaleStart, ends[0]); setText(scaleEnd, ends[1]);
    }
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
    "aria-label": t(control.label),
  });
  const buttons = control.choices.map(([value, labelKey]) => {
    const button = el("button", { type: "button", "aria-pressed": "false" }, t(labelKey));
    button.addEventListener("click", () => store.set({ [control.key]: value }));
    picker.append(button);
    relabel(() => setText(button, t(labelKey)));
    return [value, button];
  });
  const recovery = control.key === "highlightRecovery";
  const hint = control.help ? el("p", { class: "field-hint", hidden: true }, t(control.help)) : null;
  const help = hint && !recovery ? helpButton(control, hint) : null;
  const name = el("b", {}, t(control.label));
  const node = el("div", { class: "field" },
    recovery ? null : el("span", { class: "field-title" }, name, help),
    picker,
    hint);
  relabel(() => {
    setText(name, t(control.label));
    picker.setAttribute("aria-label", t(control.label));
    if (hint) { setText(hint, t(recovery ? "inspector.recoveryNote" : control.help)); hint.hidden = !recovery; }
  });
  return {
    node,
    apply: (state) => {
      if (recovery) {
        const selected = control.choices.find(([id]) => id === state[control.key]);
        setText(role("recovery-summary"), t(selected[1]));
        role("recovery-summary").closest("summary").title = t(control.help);
      }
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
    "aria-label": t(control.label),
  });
  const commit = () => {
    const parsed = Number(input.value);
    if (!Number.isFinite(parsed)) { input.value = String(store.get()[control.key]); return; }
    store.set({ [control.key]: clamp(Math.round(parsed), control.min, control.max) });
  };
  // Keep the command preview and the run payload in sync while a value is
  // typed, not only after the field loses focus. Empty/bad intermediate input
  // is left alone until the browser emits `change`, so editing remains natural.
  input.addEventListener("input", () => {
    if (input.value === "" || input.validity.badInput) return;
    commit();
  });
  input.addEventListener("change", commit);
  const name = el("span", { class: "field-label" }, t(control.label));
  const node = el("label", { class: "field field--inline" }, name, input);
  relabel(() => {
    setText(name, t(control.label));
    input.setAttribute("aria-label", t(control.label));
  });
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

/* ── encoding select (lives in the output block, wired here with settings) ── */

function mountEncoding({ toast } = {}) {
  const container = role("encoding");
  const hint = role("encoding-hint");
  const buttons = new Map();

  for (const entry of ENCODINGS) {
    const descriptions = { adaptive: "Apple HDR", pq: "HDR10", hlg: "BT.2100", ultrahdr: "Google HDR", "avif-pq": "AVIF · PQ", "avif-hlg": "AVIF · HLG" };
    const button = el("button", { type: "button", "aria-pressed": "false", "aria-label": entry.label },
      el("strong", {}, entry.label), el("small", {}, descriptions[entry.id]));
    button.addEventListener("click", () => {
      const current = store.get().hdrRange;
      const aiCurrent = store.get().aiHdrRange;
      // Clamped here rather than in the slider so the stored value and the
      // command line agree the moment the format changes.
      const clamped = Math.min(current, entry.maxRange);
      const aiClamped = Math.min(aiCurrent, entry.maxRange);
      store.set({ encoding: entry.id, hdrRange: clamped, aiHdrRange: aiClamped });
      // A silent clamp reads as the panel losing the user's setting.
      if (clamped < current || aiClamped < aiCurrent) {
        const shown = clamped < current ? clamped : aiClamped;
        toast?.(t("enc.clamped", { label: entry.label, value: shown.toFixed(1) }));
      }
    });
    buttons.set(entry.id, button);
    container.append(button);
  }

  store.watch("encoding", (id) => {
    const active = encodingById(id);
    for (const [key, button] of buttons) {
      button.setAttribute("aria-pressed", String(key === active.id));
    }
    setText(hint, t(active.hint));
  }, { immediate: true });
  relabel(() => setText(hint, t(encodingById(store.get().encoding).hint)));
}

/* ── colour and gamut choices (lives in the output block) ──────────────── */

function mountColorGamut() {
  const gamut = role("color-gamut");
  const hint = role("color-hint");
  const current = el("button", { type: "button", "aria-pressed": "false" });
  const limited = el("button", { type: "button", "aria-pressed": "false" });
  gamut.append(current, limited);
  current.addEventListener("click", () => store.set({ clampSrgb: false }));
  limited.addEventListener("click", () => store.set({ clampSrgb: true }));
  const sync = (state) => {
    setText(current, t("editor.currentGamut"));
    setText(limited, t("out.clampSrgb"));
    setPressed(current, !state.clampSrgb);
    setPressed(limited, Boolean(state.clampSrgb));
    const label = COLOR_GAMUTS.find(({ id }) => id === state.colorGamut)?.label || "sRGB";
    setText(hint, state.clampSrgb ? t("editor.limitedHint") : t("editor.currentGamutHint", { gamut: label }));
  };
  store.watchAny(["colorGamut", "clampSrgb"], sync, { immediate: true });
  relabel(() => sync(store.get()));
}

/* ── reset ──────────────────────────────────────────────────────────── */

function mountResets({ toast } = {}) {
  /* "重置全部" covers the image controls, not the output format: the encoding
   * is a workflow decision (where will this file be shown?), not part of the
   * look being dialled in. */
  const button = role("settings-reset");
  const keys = CONTROLS.map((control) => control.key);
  button.textContent = t("adjust.reset");
  button.addEventListener("click", () => {
    store.set({
      ...defaultsFor(keys),
      // Reset returns to the mathematical defaults, but deliberately keeps the
      // current image's inferred gain cached for an instant comparison.
      previewOptimized: false,
    });
    toast?.(t("adjust.resetDone"));
  });
  relabel(() => { button.textContent = t("adjust.reset"); });
}

/* ── entry point ────────────────────────────────────────────────────── */

export function mountControls({ toast } = {}) {
  mountEncoding({ toast });
  mountColorGamut();
  mountResets({ toast });

  const containers = new Map(
    Object.entries(GROUP_CONTAINERS).map(([group, name]) => [group, role(name)]));

  for (const control of CONTROLS) {
    // `pinned` controls seed the store and ride along in the run payload but
    // have no widget; see the note above CONTROLS in schema.js.
    if (control.group === "pinned") continue;
    const container = ["aiContrast", "aiShadows", "aiHighlights", "aiExpansionStart"].includes(control.key)
      ? role("group-model-detail") : containers.get(control.group);
    if (!container) continue;
    const widget = BUILDERS[control.kind](control);
    container.append(widget.node);
    relabels.push(() => widget.apply(store.get()));
    store.watchAny(widget.watches, widget.apply, { immediate: true });
  }

  const manualSubmenu = role("submenu-manual");
  const aiSubmenu = role("submenu-ai");

  store.watch("previewOptimized", (active) => {
    if (manualSubmenu) {
      manualSubmenu.hidden = active;
      manualSubmenu.inert = active;
    }
    if (aiSubmenu) {
      aiSubmenu.hidden = !active;
      aiSubmenu.inert = !active;
    }
  }, { immediate: true });

  const modeNote = role("mode-note");
  const syncModeNote = () => setText(modeNote, store.get().previewOptimized ? t("inspector.aiNote") : t("inspector.manualNote"));
  store.watch("previewOptimized", syncModeNote, { immediate: true });
  relabels.push(syncModeNote);
  for (const group of document.querySelectorAll(".parameter-group")) {
    group.addEventListener("toggle", () => { if (!group.open) store.set({ maskKey: null }); });
  }
  onLocaleChange(() => { for (const fn of [...relabels]) fn(); });
}
