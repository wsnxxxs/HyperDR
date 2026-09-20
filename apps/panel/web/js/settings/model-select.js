/* Offer CNN for every photo and EXIF-assisted prediction when capture
 * parameters were decoded. Model availability still comes from the executable.
 */

import { store } from "../core/store.js";
import { role, el, setText } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { DEFAULT_MODEL_ID, MODEL_KEY, restoredModelId } from "./model-ids.js";

/** The one-line reason a model is worth choosing, keyed by model id. */
const HELP_KEYS = {
  "research-cnn-v1": "model.help.research-cnn-v1",
  "research-exif-v1": "model.help.research-exif-v1",
};

/** Display names are translated on the client so the English panel reads in
 *  English; the native table's own name is the fallback for an id this build
 *  knows about but this file does not. */
export function modelLabel(id, state = store.get()) {
  const key = `model.${id}`;
  const translated = t(key);
  if (translated !== key) return translated;
  const entry = (state?.capabilities?.model?.models || [])
    .find((model) => model.id === id);
  return entry?.displayName || entry?.id || id || "";
}

/** The capture fields a fallback blamed, in words, for a sentence the user can
 *  act on. The converter reports the field names it uses internally. */
export function fallbackFields(reason) {
  return String(reason || "")
    .replace(/^missing_capture_fields:?/, "")
    .split(":")
    .filter(Boolean)
    .map((field) => t(`field.${field}`))
    .join("、");
}

function helpText(entry) {
  const key = HELP_KEYS[entry.id];
  if (!key) return "";
  const translated = t(key);
  return translated === key ? "" : translated;
}

export function mountModelSelect() {
  const field = role("model-field");
  const select = role("model-select");
  const hint = role("model-hint");
  const note = role("model-note");

  const models = () => (store.get().capabilities?.model?.models || []).filter((entry) =>
    entry.id === "research-cnn-v1"
      || (entry.id === "research-exif-v1" && store.get().hasCaptureMetadata === true));
  const entryFor = (id) => models().find((entry) => entry.id === id) || null;

  function render() {
    reconcile();
    const state = store.get();
    const list = models();
    field.hidden = list.length <= 1;
    select.replaceChildren();
    for (const entry of list) {
      const option = el("option", { value: entry.id }, modelLabel(entry.id, state));
      if (entry.available === false) option.disabled = true;
      select.append(option);
    }
    // The value is written after the options exist; assigning it earlier would
    // be discarded by the first append.
    select.value = state.modelId;
    if (select.value !== state.modelId && list.length) {
      // The stored selection is not in this build's list. The capability watch
      // normally repairs that before this runs; if it has not, showing the
      // first option while the store says something else would make the panel
      // lie about what the next request will name.
      select.value = list[0].id;
      store.set({ [MODEL_KEY]: list[0].id });
    }
    const entry = entryFor(state.modelId);
    setText(hint, entry ? helpText(entry) : "");
    hint.hidden = !hint.textContent;
    select.disabled = Boolean(state.optimizing || state.jobId || state.starting
      || state.uploading || state.restoring || !list.some((entry) => entry.available !== false));
    renderStatus(state);
  }

  /* What actually ran, which is not always what is selected. A fallback keeps
   * model 2 selected: the user asked for the capture-assisted model and the
   * honest report is that this photograph could not feed it, not that their
   * choice was changed for them. */
  function renderStatus(state = store.get()) {
    const identity = state.previewOptimized && state.modelIdentity?.requestedModelId === state.modelId
      ? state.modelIdentity : null;
    if (!identity) {
      note.hidden = true;
      setText(note, "");
      return;
    }
    const fallback = identity.inferenceMode === "pixel_only_fallback";
    note.hidden = !fallback;
    if (fallback) {
      setText(note, t("adjust.modelFallback", {
        fields: fallbackFields(identity.fallbackReason),
        model: modelLabel(identity.effectiveModelId, state),
      }));
      note.title = identity.fallbackReason || "";
      return;
    }
    note.removeAttribute("title");
    setText(note, "");
  }

  // Reconcile restored selections and photo changes against the visible models.
  function reconcile() {
    const state = store.get();
    const list = models().filter((entry) => entry.available !== false);
    if (!list.length) return;
    const ids = new Set(list.map((entry) => entry.id));
    if (ids.has(state.modelId)) return;
    const chosen = [DEFAULT_MODEL_ID, list[0].id]
      .find((candidate) => candidate && ids.has(candidate));
    if (chosen && chosen !== state.modelId) store.set({ [MODEL_KEY]: chosen });
  }

  select.addEventListener("change", () => {
    store.set({ [MODEL_KEY]: select.value });
  });

  store.watch("capabilities", () => { reconcile(); render(); });
  store.watchAny([MODEL_KEY, "hasCaptureMetadata", "optimizing", "jobId", "starting", "uploading", "restoring", "modelIdentity", "previewOptimized"],
    render, { immediate: true });
  // Everything this module writes is language dependent, so a locale change
  // re-emits it rather than leaving the previous language's option names.
  onLocaleChange(render);

  return {
    /** The model a restored configuration should select, given what this build
     *  reports. Exposed so history and export recovery use one rule. */
    restoredId: (saved) => restoredModelId(saved,
      models().filter((entry) => entry.available !== false).map((entry) => entry.id)),
  };
}
