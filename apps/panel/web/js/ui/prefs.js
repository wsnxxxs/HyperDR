/* Preferences use the same native dialog lifecycle as the other subviews. */

import { el, role, setPressed, setText } from "../core/dom.js";
import { store } from "../core/store.js";
import { t, applyStatic, onLocaleChange, currentLocale } from "../i18n/index.js";
import {
  PREFS, PREF_GROUPS, prefs, persistPrefs, resetPrefs,
} from "./prefs-schema.js";
import { api } from "../core/api.js";
import { openDialog } from "./dialogs.js";
import {
  availableSaveTargets, browserDirectoryName, chooseSaveFolder,
} from "../run/save.js";

export function mountPrefs({ toast, phoneWorkbench }) {
  const openButton = role("prefs-open");
  const panel = role("prefs");
  const closeButton = role("prefs-close");
  const nav = role("prefs-nav");
  const body = role("prefs-body");
  const resetButton = role("prefs-reset");
  const copyButton = role("prefs-copy-diagnostics");
  const saveHint = el("p", { "data-i18n": "prefs.autoSave" }, t("prefs.autoSave"));
  resetButton.parentElement.prepend(saveHint);

  let activeGroup = PREF_GROUPS[0];
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
    const labelId = `pref-${pref.key}-label`;
    title.id = labelId;
    control.setAttribute("aria-labelledby", labelId);
    if (hint) {
      hint.id = `pref-${pref.key}-help`;
      control.setAttribute("aria-describedby", hint.id);
    }
    return el("div", { class: "field prefs-field" },
      el("div", { class: "prefs-field-copy" },
        el("span", { class: "field-title" }, title), hint), control);
  }

  function buildSegmented(pref) {
    const picker = el("div", { class: "segmented segmented--wrap" },
      ...[]);
    picker.setAttribute("role", "group");
    const label = () => t(`prefs.${pref.key}.label`);
    picker.setAttribute("aria-label", label());
    const choices = pref.key === "saveTarget" ? availableSaveTargets() : pref.choices;
    const buttons = choices.map(([value, labelKey]) => {
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
      const current = choices.some(([value]) => value === state[pref.key])
        ? state[pref.key] : choices[0]?.[0];
      for (const [value, button] of buttons) setPressed(button, value === current);
    };
    return { node: fieldShell(pref, picker), apply };
  }

  function buildExportFolderRow() {
    const title = el("b", {}, t("prefs.exportFolder.label"));
    const value = el("span", { class: "prefs-export-folder-value" }, t("prefs.exportFolder.none"));
    const help = el("p", { class: "field-hint prefs-hint" }, t("prefs.exportFolder.help"));
    const change = el("button", { class: "button", type: "button" }, t("prefs.exportFolder.change"));
    const openFolder = el("button", { class: "button", type: "button" }, t("save.openFolder"));
    const row = el("div", { class: "prefs-field prefs-export-folder" },
      el("div", { class: "prefs-field-copy" },
        el("span", { class: "field-title" }, title), value, help),
      el("div", { class: "prefs-export-folder-actions" }, change, openFolder));
    let folderLabel = "";

    function relabel() {
      setText(title, t("prefs.exportFolder.label"));
      setText(value, folderLabel || t("prefs.exportFolder.none"));
      setText(help, t("prefs.exportFolder.help"));
      setText(change, t("prefs.exportFolder.change"));
      setText(openFolder, t("save.openFolder"));
    }
    relabels.push(relabel);

    async function refresh() {
      const capabilities = store.get().capabilities || {};
      const native = Boolean(capabilities.nativePathOutput && window.__TAURI__?.dialog?.open);
      const browserFolder = !native
        && availableSaveTargets().some(([target]) => target === "fixed");
      row.hidden = !native && !browserFolder;
      openFolder.hidden = !native;
      openFolder.disabled = !capabilities.exportFolderReady;
      folderLabel = native
        ? capabilities.exportFolderLabel || ""
        : await browserDirectoryName();
      relabel();
    }

    change.addEventListener("click", async () => {
      change.disabled = true;
      try {
        const label = await chooseSaveFolder();
        if (label) {
          folderLabel = label;
          toast(t("prefs.exportFolder.saved"));
        }
      } catch (error) {
        if (error?.name !== "AbortError") toast(error?.message || t("save.folderFailed"), true);
      } finally {
        change.disabled = false;
        await refresh();
      }
    });
    openFolder.addEventListener("click", async () => {
      openFolder.disabled = true;
      try {
        await api.openExportFolder();
        toast(t("prefs.exportFolder.opened"));
      } catch (error) {
        toast(error?.message || t("save.folderFailed"), true);
      } finally {
        await refresh();
      }
    });
    void refresh();
    return row;
  }

  function buildToggle(pref) {
    const button = el("button", { class: "prefs-switch", type: "button",
                                  role: "switch", "aria-checked": "false" });
    button.addEventListener("click", () => prefs.set({ [pref.key]: !prefs.get()[pref.key] }));
    const node = fieldShell(pref, button);
    node.classList.add("prefs-field--toggle");
    return { node, apply: (state) => setPressed(button, state[pref.key], { aria: "aria-checked" }) };
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

      if (group === "phone") {
        const launch = el("button", { type: "button", class: "button button--primary" }, t("phone.connect"));
        const hint = el("p", { class: "field-hint prefs-hint" }, t("phone.subtitle"));
        launch.addEventListener("click", () => phoneWorkbench.open());
        relabels.push(() => { setText(launch, t("phone.connect")); setText(hint, t("phone.subtitle")); });
        section.append(hint, launch);
      } else if (group === "about") {
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
          if (pref.key === "saveTarget") section.append(buildExportFolderRow());
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
    selectGroup(activeGroup);
  }

  function renderNav() {
    nav.replaceChildren();
    const icons = { appearance: "palette", preview: "monitor", output: "export",
      adjust: "sliders-horizontal", phone: "device-mobile", about: "info" };
    for (const group of PREF_GROUPS) {
      const label = el("span", {}, t(`prefs.group.${group}`));
      const button = el("button", {
        type: "button", dataset: { group }, "aria-pressed": String(group === activeGroup),
      }, el("i", { class: `ph ph-${icons[group]}`, "aria-hidden": "true" }), label);
      button.classList.toggle("is-on", group === activeGroup);
      button.addEventListener("click", () => selectGroup(group));
      relabels.push(() => setText(label, t(`prefs.group.${group}`)));
      nav.append(button);
    }
  }

  function selectGroup(group) {
    disarm();
    activeGroup = group;
    for (const section of body.querySelectorAll(".prefs-group")) {
      section.hidden = section.dataset.group !== group;
    }
    for (const button of nav.querySelectorAll("button")) {
      setPressed(button, button.dataset.group === group);
    }
    copyButton.hidden = group !== "about";
    resetButton.hidden = group === "phone";
    saveHint.hidden = group === "phone" || group === "about";

    body.scrollTop = 0;
  }

  /* ── open / close ──────────────────────────────────────────────────── */

  const isOpen = () => panel.open;

  function open(group = activeGroup) {
    if (PREF_GROUPS.includes(group)) activeGroup = group;
    if (isOpen()) { selectGroup(activeGroup); return; }
    render();
    openDialog(panel);
  }

  function close() { if (panel.open) panel.close(); }

  openButton.addEventListener("click", () => (isOpen() ? close() : open()));
  closeButton.addEventListener("click", close);
  panel.addEventListener("close", () => {
    disarm();
  });
  const done = el("button", { type: "button", class: "button", "data-i18n": "common.done" }, t("common.done"));
  done.addEventListener("click", close);
  resetButton.parentElement.append(done);

  window.addEventListener("keydown", (event) => {
    if (event.key !== "," || !(event.metaKey || event.ctrlKey)) return;
    // Keep shortcuts inside the active dialog instead of stacking Settings over it.
    const activeDialog = document.querySelector("dialog[open]:not([data-dialog-covered])");
    if (activeDialog && activeDialog !== panel) { event.preventDefault(); return; }
    event.preventDefault();
    isOpen() ? close() : open();
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
    applyStatic(panel);
    for (const relabel of [...relabels]) relabel();
    disarm();
  });

  return { open, close, isOpen };
}
