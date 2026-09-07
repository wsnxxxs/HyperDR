import { store } from "../core/store.js";
import { role, setPressed, setText } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";

// Encoding remains the single source of truth for the workflow, including
// restored exports and undo. Switching does not change the shared grade.
export function workflowPatch(state, colorOnly) {
  if ((state.encoding === "sdr-jpeg") === colorOnly) return {};
  if (colorOnly) return {
    lastHdrEncoding: state.encoding, lastHdrOptimized: state.previewOptimized,
    encoding: "sdr-jpeg", previewOptimized: false, maskKey: null,
  };
  return {
    encoding: state.lastHdrEncoding || "adaptive", maskKey: null,
    previewOptimized: Boolean(state.lastHdrOptimized && state.modelGainReady
      && !(state.lutId && ["hlg", "pq", "slog3-sgamut3cine"].includes(state.lutInput))),
  };
}

export function mountWorkflow() {
  const color = role("workflow-color"), hdr = role("workflow-hdr");
  const lut = role("lut-panel");
  const settings = lut.parentElement;
  const intro = settings.querySelector(".adjustment-intro");
  color.addEventListener("click", () => store.set(workflowPatch(store.get(), true)));
  hdr.addEventListener("click", () => store.set(workflowPatch(store.get(), false)));
  function sync(state) {
    const sdr = state.encoding === "sdr-jpeg";
    document.documentElement.dataset.workflow = sdr ? "color" : "hdr";
    setPressed(color, sdr); setPressed(hdr, !sdr);
    color.disabled = hdr.disabled = state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    setText(role("workflow-hint"), sdr ? t("workflow.colorHint") : t("workflow.hdrHint"));
    if (sdr && settings.firstElementChild !== lut) {
      settings.insertBefore(lut, intro);
      lut.open = true;
    } else if (!sdr && settings.lastElementChild !== lut) settings.append(lut);
  }
  store.watchAny(["encoding", "uploading", "restoring", "optimizing", "starting", "jobId"], sync, { immediate: true });
  store.watch("sessionId", () => store.set({ lastHdrOptimized: false }));
  onLocaleChange(() => sync(store.get()));
}
