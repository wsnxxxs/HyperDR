/* The preferences overlay: a full-window glass surface with a category rail.
 *
 * The panel had no dialog of any kind before this, and inventing a modal system
 * for one surface would have been the wrong trade. The open/close mechanics are
 * the ones the full-screen preview already uses (a fixed inset-0 layer plus a
 * scroll lock on <html>); what is genuinely new here is the modal part -- Esc,
 * a focus trap, and returning focus to the trigger -- because the preview
 * expander is not modal and had none of it.
 *
 * Every row is built from the PREFS table rather than written into index.html.
 * That keeps scripts/check_panel_roles.py honest: the markup declares one
 * container, `prefs-body`, and no per-row roles that the checker would have to
 * be told to ignore.
 */

import { el, role, setPressed, setText } from "../core/dom.js";
import { store } from "../core/store.js";
import { t, applyStatic, onLocaleChange, currentLocale } from "../i18n/index.js";
import {
  PREFS, PREF_GROUPS, prefs, persistPrefs, resetPrefs,
} from "./prefs-schema.js";

/** Focusable descendants, in tab order, skipping anything currently hidden. */
const focusable = (root) =>
  Array.from(root.querySelectorAll(
    'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])'))
    .filter((node) => node.offsetParent !== null);

export function mountPrefs({ toast }) {
  const openButton = role("prefs-open");
  const panel = role("prefs");
  const closeButton = role("prefs-close");
  const nav = role("prefs-nav");
  const body = role("prefs-body");
  const resetButton = role("prefs-reset");
  const copyButton = role("prefs-copy-diagnostics");

  let activeGroup = PREF_GROUPS[0];
  let lastFocused = null;
  /** Re-label hooks, one per built node, run when the locale changes. */
  const relabels = [];

  /* ── rows ──────────────────────────────────────────────────────────── */

  /** Values a help string interpolates. Read fresh each time so a re-label
   *  after boot picks up what /api/state reported. */
  function helpParams(pref) {
    if (pref.key !== "previewCeiling") return undefined;
    const served = store.get().capabilities?.previewMaxEdge;
    return { max: served ?? "—" };
  }

  /** A preference's label and its optional explanation, sharing the layout the
   *  rail's fields already use so the two surfaces do not drift apart. */
  function fieldShell(pref, control) {
    const labelKey = `prefs.${pref.key}.label`;
    const helpKey = `prefs.${pref.key}.help`;
    const title = el("b", {}, t(labelKey));
    // Not every preference earns an explanation; a help string is only written
    // for the ones whose consequence is not visible in the label.
    const hasHelp = t(helpKey) !== helpKey;
    const hint = hasHelp
      ? el("p", { class: "field-hint prefs-hint" }, t(helpKey, helpParams(pref))) : null;
    relabels.push(() => {
      setText(title, t(labelKey));
      if (hint) setText(hint, t(helpKey, helpParams(pref)));
    });
    return el("div", { class: "field prefs-field" },
      el("span", { class: "field-title" }, title),
      control,
      hint);
  }

  function buildSegmented(pref) {
    const picker = el("div", { class: "segmented segmented--wrap" },
      ...[]);
    picker.setAttribute("role", "group");
    const label = () => t(`prefs.${pref.key}.label`);
    picker.setAttribute("aria-label", label());
    const buttons = pref.choices.map(([value, labelKey]) => {
      const text = labelKey ? t(labelKey) : (pref.labels?.[value] ?? value);
      const button = el("button", { type: "button", "aria-pressed": "false" }, text);
      button.addEventListener("click", () => prefs.set({ [pref.key]: value }));
      picker.append(button);
      relabels.push(() => {
        setText(button, labelKey ? t(labelKey) : (pref.labels?.[value] ?? value));
      });
      return [value, button];
    });
    relabels.push(() => picker.setAttribute("aria-label", label()));
    const apply = (state) => {
      for (const [value, button] of buttons) setPressed(button, value === state[pref.key]);
    };
    return { node: fieldShell(pref, picker), apply };
  }

  function buildToggle(pref) {
    const button = el("button", { class: "chip prefs-toggle", type: "button",
                                  "aria-pressed": "false" });
    const setLabel = () => setText(button, t(`prefs.${pref.key}.label`));
    setLabel();
    relabels.push(setLabel);
    button.addEventListener("click", () => prefs.set({ [pref.key]: !prefs.get()[pref.key] }));
    // The chip carries its own label, so the shell renders only the hint.
    const helpKey = `prefs.${pref.key}.help`;
    const hasHelp = t(helpKey) !== helpKey;
    const hint = hasHelp
      ? el("p", { class: "field-hint prefs-hint" }, t(helpKey, helpParams(pref))) : null;
    if (hint) relabels.push(() => setText(hint, t(helpKey, helpParams(pref))));
    const node = el("div", { class: "field prefs-field prefs-field--toggle" }, button, hint);
    return { node, apply: (state) => setPressed(button, state[pref.key]) };
  }

  const BUILDERS = { segmented: buildSegmented, toggle: buildToggle };

  /* ── diagnostics ───────────────────────────────────────────────────── */

  /** Rows are (labelKey, () => value); the getters re-run on every open so the
   *  page never shows a stale probe. */
  function diagnosticRows() {
    const capabilities = store.get().capabilities;
    const model = capabilities?.model;
    const hdrLine = role("hdr-status")?.textContent?.trim();
    return [
      ["prefs.about.service", () => (capabilities?.ready
        ? t("prefs.about.serviceReady") : t("prefs.about.serviceMissing"))],
      ["prefs.about.model", () => {
        if (!model) return t("prefs.about.unknown");
        if (model.ready) return t("prefs.about.modelReady", { device: model.device || "native" });
        return `${t("prefs.about.modelOff")} · ${model.reason || t("prefs.about.unknown")}`;
      }],
      ["prefs.about.hdr", () => hdrLine || t("prefs.about.unknown")],
      ["prefs.about.transport", () => (window.isSecureContext
        ? t("prefs.about.transportSecure") : t("prefs.about.transportPlain"))],
      ["prefs.about.display", () => (window.matchMedia("(dynamic-range: high)").matches
        ? t("prefs.about.displayHdr") : t("prefs.about.displaySdr"))],
      ["prefs.about.uploadLimit", () => (capabilities?.maxUploadMB
        ? `${capabilities.maxUploadMB} MB` : t("prefs.about.unknown"))],
      ["prefs.about.previewLimit", () => (capabilities?.previewMaxEdge
        ? `${capabilities.previewMaxEdge} px` : t("prefs.about.unknown"))],
      ["prefs.about.inputs", () => (capabilities?.inputExtensions?.join(" ")
        || t("prefs.about.unknown"))],
      ["prefs.about.env", () => `${capabilities?.os || t("prefs.about.unknown")} · `
        + `WebGPU ${navigator.gpu ? "✓" : "✗"} · DPR ${window.devicePixelRatio || 1}`],
    ];
  }

  /** The same rows as plain text, for a bug report. */
  function diagnosticsText() {
    const lines = diagnosticRows().map(([key, value]) => `${t(key)}: ${value()}`);
    lines.push(`locale: ${currentLocale()}`);
    lines.push(`userAgent: ${navigator.userAgent}`);
    lines.push(`prefs: ${JSON.stringify(prefs.get())}`);
    return lines.join("\n");
  }

  /* ── rendering ─────────────────────────────────────────────────────── */

  /** Applies every built row against the current preference state. */
  let applyAll = () => {};

  function render() {
    relabels.length = 0;
    body.replaceChildren();
    const appliers = [];

    for (const group of PREF_GROUPS) {
      const heading = el("h3", { class: "prefs-group-title" }, t(`prefs.group.${group}`));
      relabels.push(() => setText(heading, t(`prefs.group.${group}`)));
      const section = el("section", {
        class: "prefs-group", dataset: { group },
        hidden: group !== activeGroup,
      }, heading);

      if (group === "about") {
        const list = el("dl", { class: "prefs-diagnostics" });
        for (const [key, value] of diagnosticRows()) {
          const term = el("dt", {}, t(key));
          const detail = el("dd", {}, value());
          relabels.push(() => { setText(term, t(key)); setText(detail, value()); });
          list.append(term, detail);
        }
        const note = el("p", { class: "field-hint prefs-hint" }, t("prefs.about.envNote"));
        const licence = el("p", { class: "prefs-licence" }, t("prefs.about.license"));
        relabels.push(() => {
          setText(note, t("prefs.about.envNote"));
          setText(licence, t("prefs.about.license"));
        });
        section.append(list, note, licence);
      } else {
        for (const pref of PREFS.filter((entry) => entry.group === group)) {
          const built = BUILDERS[pref.kind](pref);
          section.append(built.node);
          appliers.push(built.apply);
        }
        // Said once per surface, where the consequence lands, rather than in a
        // README nobody opens: these choices do not travel to the phone.
        if (group === PREF_GROUPS[0]) {
          const scope = el("p", { class: "field-hint prefs-hint prefs-scope" }, t("prefs.scope"));
          relabels.push(() => setText(scope, t("prefs.scope")));
          section.append(scope);
        }
      }
      body.append(section);
    }

    applyAll = (state) => { for (const apply of appliers) apply(state); };
    applyAll(prefs.get());
    renderNav();
  }

  function renderNav() {
    nav.replaceChildren();
    for (const group of PREF_GROUPS) {
      const button = el("button", {
        type: "button", "aria-pressed": String(group === activeGroup),
      }, t(`prefs.group.${group}`));
      button.classList.toggle("is-on", group === activeGroup);
      button.addEventListener("click", () => selectGroup(group));
      relabels.push(() => setText(button, t(`prefs.group.${group}`)));
      nav.append(button);
    }
  }

  function selectGroup(group) {
    activeGroup = group;
    for (const section of body.querySelectorAll(".prefs-group")) {
      section.hidden = section.dataset.group !== group;
    }
    renderNav();
    body.scrollTop = 0;
  }

  /* ── open / close ──────────────────────────────────────────────────── */

  const isOpen = () => !panel.hidden;

  function open() {
    if (isOpen()) return;
    lastFocused = document.activeElement;
    // Diagnostics are probed at open time, so the readouts are never stale.
    render();
    panel.hidden = false;
    document.documentElement.classList.add("prefs-open");
    openButton.setAttribute("aria-expanded", "true");
    (focusable(panel)[0] || closeButton).focus();
  }

  function close() {
    if (!isOpen()) return;
    panel.hidden = true;
    document.documentElement.classList.remove("prefs-open");
    openButton.setAttribute("aria-expanded", "false");
    if (lastFocused instanceof HTMLElement) lastFocused.focus();
    lastFocused = null;
  }

  openButton.addEventListener("click", () => (isOpen() ? close() : open()));
  closeButton.addEventListener("click", close);
  // The scrim is the panel itself; a click that lands on it rather than on the
  // surface inside is a click outside the dialog.
  panel.addEventListener("pointerdown", (event) => {
    if (event.target === panel) close();
  });

  window.addEventListener("keydown", (event) => {
    // Ctrl/Cmd+, is the platform convention and is worth honouring even though
    // this panel is also served to a phone, where no one will press it.
    if (event.key === "," && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      isOpen() ? close() : open();
      return;
    }
    if (!isOpen()) return;
    if (event.key === "Escape") { event.preventDefault(); close(); return; }
    if (event.key !== "Tab") return;
    // Focus trap: without it, Tab walks into the inert rail behind the overlay.
    const nodes = focusable(panel);
    if (nodes.length === 0) return;
    const first = nodes[0];
    const last = nodes[nodes.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  /* ── actions ───────────────────────────────────────────────────────── */

  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(diagnosticsText());
      toast?.(t("prefs.about.copied"));
    } catch (_) {
      toast?.(t("prefs.about.copyFailed"), true);
    }
  });

  // Two-step, like the rail's reset: one click arms, the next commits.
  let armed = false;
  let armedTimer = 0;
  const disarm = () => {
    armed = false;
    clearTimeout(armedTimer);
    setText(resetButton, t("prefs.about.reset"));
  };
  resetButton.addEventListener("click", () => {
    if (!armed) {
      armed = true;
      setText(resetButton, t("prefs.about.resetConfirm"));
      armedTimer = setTimeout(disarm, 4000);
      return;
    }
    disarm();
    resetPrefs();
    render();
    toast?.(t("prefs.about.resetDone"));
  });

  /* ── reactions ─────────────────────────────────────────────────────── */

  prefs.subscribe(() => {
    persistPrefs();
    applyAll(prefs.get());
  });

  onLocaleChange(() => {
    applyStatic();
    for (const relabel of [...relabels]) relabel();
    disarm();
  });

  return { open, close, isOpen };
}
