/* Builds every control from `schema.js` and keeps it in step with the store.
 *
 * Each widget writes to the store on input and reads back from it on change, so
 * an encoding clamp, a preset, a group reset and a drag all take the same path.
 * Nothing outside this module touches a control's DOM.
 */

import { el, role, setPressed, setText, clamp } from "../core/dom.js";
import { store } from "../core/store.js";
import { COLOR_GAMUTS, CONTROLS, ENCODINGS, encodingById, neutralSettings } from "./schema.js";
import { mountLutLibrary } from "./lut-library.js";
import { mountWorkflow } from "./workflow.js";
import { api } from "../core/api.js";
import { t, onLocaleChange } from "../i18n/index.js";

/* Widgets are built once and mutated thereafter, so a language change has to
 * be pushed into the nodes that already exist. Each builder registers what it
 * needs re-read here; mountControls runs the list on every locale change. */
const relabels = [];
const relabel = (fn) => { relabels.push(fn); fn(); };

const GROUP_CONTAINERS = {
  lut: "group-lut",
  tone: "group-tone",
  model: "group-model",
  region: "group-region",
  quality: "group-quality",
};

const hdrRangeCeiling = () =>
  encodingById(store.get().encoding).maxRange;

const isHdrRange = (key) => key === "hdrRange" || key === "aiHdrRange";

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

  input.addEventListener("pointerdown", () => {
    dragging = true;
    store.set({ previewInteracting: true });
  });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    apply(store.get());
    store.set({ previewInteracting: false });
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
  const hint = control.help ? el("p", { class: "field-hint", hidden: true }, t(control.help)) : null;
  const help = hint ? helpButton(control, hint) : null;
  const name = el("b", {}, t(control.label));
  const node = el("div", { class: "field" },
    el("span", { class: "field-title" }, name, help),
    picker,
    hint);
  relabel(() => {
    setText(name, t(control.label));
    picker.setAttribute("aria-label", t(control.label));
    if (hint) setText(hint, t(control.help));
  });
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
    const descriptions = { "sdr-jpeg": "sRGB", adaptive: "Apple HDR", pq: "HDR10", hlg: "BT.2100", ultrahdr: "Google HDR", "avif-pq": "AVIF · PQ", "avif-hlg": "AVIF · HLG" };
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
      button.hidden = (key === "sdr-jpeg") !== (id === "sdr-jpeg");
    }
    container.classList.toggle("out-formats--sdr", id === "sdr-jpeg");
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
    const sdr = state.encoding === "sdr-jpeg";
    gamut.closest("section").hidden = sdr;
    current.disabled = limited.disabled = sdr;
    setText(current, t("editor.currentGamut"));
    setText(limited, t("out.clampSrgb"));
    setPressed(current, !state.clampSrgb && !sdr);
    setPressed(limited, Boolean(state.clampSrgb) || sdr);
    const label = COLOR_GAMUTS.find(({ id }) => id === state.colorGamut)?.label || "sRGB";
    setText(hint, sdr ? t("enc.sdr-jpeg.hint") : state.clampSrgb ? t("editor.limitedHint") : t("editor.currentGamutHint", { gamut: label }));
  };
  store.watchAny(["colorGamut", "clampSrgb", "encoding"], sync, { immediate: true });
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
    const colorOnly = store.get().encoding === "sdr-jpeg";
    const neutral = neutralSettings(store.get().encoding);
    const resetKeys = colorOnly ? ["brightness", "contrast", "vibrance", "lutStrength"] : keys;
    store.set({
      ...Object.fromEntries(resetKeys.map((key) => [key, neutral[key]])),
      lutId: "", lutName: "", lutInput: "srgb", lutOutput: "srgb",
      ...(colorOnly ? {} : { lastHdrOptimized: false }),
      // Reset returns to neutral manual development, but deliberately keeps the
      // current image's inferred gain cached for an instant comparison.
      previewOptimized: false,
    });
    toast?.(t("adjust.resetDone"));
  });
  relabel(() => { button.textContent = t("adjust.reset"); });
}

function mountLut({ toast } = {}) {
  const library = mountLutLibrary({ toast });
  const remove = role("lut-remove");
  const select = role("lut-select");
  const renderChoices = (state) => {
    select.replaceChildren(el("option", { value: "" }, state.lutLibraryEntries.length ? t("lut.none") : t("lut.empty")));
    const entries = [...state.lutLibraryEntries];
    if (state.lutId && !entries.some((entry) => entry.lutId === state.lutId)) entries.unshift({ lutId: state.lutId, lutName: state.lutName });
    for (const entry of entries) select.append(el("option", { value: entry.lutId }, entry.lutName.replace(/\.cube$/i, "")));
    select.value = state.lutId;
  };
  store.watchAny(["lutLibraryEntries", "lutId", "lutName"], renderChoices, { immediate: true });
  relabel(() => renderChoices(store.get()));
  select.addEventListener("change", async () => {
    const lutId = select.value, sessionId = store.get().sessionId;
    if (!lutId) { store.set({ lutId: "", lutName: "" }); return; }
    store.set({ lutApplying: true });
    try {
      const saved = await api.applyLibraryLut(sessionId, lutId);
      if (store.get().sessionId === sessionId) {
        const technical = ["hlg", "pq", "slog3-sgamut3cine"].includes(saved.lutInput);
        store.set({ ...saved, lutStrength: 1, ...(technical ? { previewOptimized: false } : {}) });
      }
    } catch (error) { toast?.(error.message || t("lut.failed")); }
    finally { store.set({ lutApplying: false }); }
  });
  store.watchAny(["lutApplying", "lutLibraryBusy", "sessionId", "file", "uploading", "restoring"], (state) => {
    select.disabled = state.lutApplying || state.lutLibraryBusy || !state.file || state.uploading || state.restoring;
    if (!state.lutApplying) select.value = state.lutId;
  }, { immediate: true });
  const enabled = role("lut-enabled");
  enabled.addEventListener("change", () => {
    const state = store.get();
    store.set(enabled.checked ? { lutStrength: state.lastLutStrength || 1 }
      : { lastLutStrength: state.lutStrength, lutStrength: 0 });
  });
  const spaces = [["srgb", "sRGB"], ["p3", "Display P3"], ["rec709", "Rec.709 · Gamma 2.4"],
    ["hlg", "HLG · BT.2020"], ["pq", "PQ · BT.2020"], ["slog3-sgamut3cine", "S-Log3 · S-Gamut3.Cine"]];
  for (const [key, labelKey] of [["lutInput", "lut.input"], ["lutOutput", "lut.output"]]) {
    const select = el("select", { class: "lut-select", "aria-label": t(labelKey) });
    for (const [value, label] of spaces) select.append(el("option", { value }, label));
    const label = el("label", { class: "field lut-space" }, el("span", {}, t(labelKey)), select);
    role("lut-spaces").append(label);
    select.addEventListener("change", () => {
      const patch = { [key]: select.value };
      if (key === "lutInput") patch.lutOutput = select.value === "slog3-sgamut3cine" ? "rec709" : select.value;
      if (["hlg", "pq", "slog3-sgamut3cine"].includes(patch.lutInput)) patch.previewOptimized = false;
      store.set(patch);
      void library.saveSpaces(store.get());
    });
    store.watchAny([key, "lutId"], (state) => { select.value = state[key]; select.disabled = !state.lutId; }, { immediate: true });
    relabel(() => { label.firstChild.textContent = t(labelKey); select.setAttribute("aria-label", t(labelKey)); });
  }
  remove.addEventListener("click", () => store.set({ lutId: "", lutName: "" }));
  const sync = (state) => {
    remove.disabled = !state.lutId;
    enabled.disabled = !state.lutId;
    enabled.checked = Boolean(state.lutId && state.lutStrength > 0);
    role("lut-space-summary").closest("details").hidden = !state.lutId;
    const inputLabel = spaces.find(([id]) => id === state.lutInput)?.[1];
    const outputLabel = spaces.find(([id]) => id === state.lutOutput)?.[1];
    setText(role("lut-space-summary"), t("lut.spaceSummary", { input: inputLabel, output: outputLabel }));
    const kind = state.lutInput === "slog3-sgamut3cine" ? "log" : ["hlg", "pq"].includes(state.lutInput) ? "hdr" : "sdr";
    setText(role("lut-hint"), t({ log: "lut.hint.log", hdr: "lut.hint.hdr", sdr: "lut.hint.sdr" }[kind]));
  };
  store.watchAny(["sessionId", "uploading", "restoring", "lutId", "lutName", "lutInput", "lutOutput", "lutStrength"], sync, { immediate: true });
  store.watch("sessionId", () => {
    if (!store.get().restoring) store.set({ lutId: "", lutName: "" });
  });
  store.watch("encoding", (id) => { if (id === "sdr-jpeg") store.set({ previewOptimized: false }); });
  store.watch("encoding", (id) => {
    role("group-region").closest("details").hidden = id === "sdr-jpeg";
  }, { immediate: true });
  relabel(() => sync(store.get()));
}

/* ── entry point ────────────────────────────────────────────────────── */

export function mountControls({ toast } = {}) {
  mountWorkflow();
  mountEncoding({ toast });
  mountColorGamut();
  mountLut({ toast });
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
    if (control.key === "lutStrength") {
      store.watch("lutId", (id) => { widget.node.querySelector("input").disabled = !id; }, { immediate: true });
    }
    if (["hdrStrength", "hdrRange", "expansionStart", "areaCoverage"].includes(control.key)) {
      store.watch("encoding", (id) => { widget.node.hidden = id === "sdr-jpeg"; }, { immediate: true });
    }
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
  const syncModeNote = () => setText(modeNote, store.get().encoding === "sdr-jpeg" ? t("workflow.baseNote") : store.get().previewOptimized ? t("inspector.aiNote") : t("inspector.manualNote"));
  store.watchAny(["previewOptimized", "encoding"], syncModeNote, { immediate: true });
  relabels.push(syncModeNote);
  for (const group of document.querySelectorAll(".parameter-group")) {
    group.addEventListener("toggle", () => { if (!group.open) store.set({ maskKey: null }); });
  }
  onLocaleChange(() => { for (const fn of [...relabels]) fn(); });
}
