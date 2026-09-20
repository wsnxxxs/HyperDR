import { el, role } from "../core/dom.js";
import { store } from "../core/store.js";
import { api } from "../core/api.js";
import { t, onLocaleChange } from "../i18n/index.js";

export function mountRawProfiles({ toast } = {}) {
  const select = el("select", { class: "select" });
  const label = el("label", { class: "control-label" }, select);
  const title = el("span");
  label.prepend(title);
  const file = el("input", { type: "file", accept: ".dcp", hidden: true });
  const button = el("button", { type: "button", class: "button" });
  const hint = el("p", { class: "control-help" });
  const section = el("div", { class: "control", hidden: true }, label, button, file, hint);
  role("group-lut").prepend(section);
  let entries = [], camera = "", isRaw = false, busy = false, request = 0;
  function sync() {
    const state = store.get();
    section.hidden = !isRaw;
    title.textContent = t("rawProfile.label");
    button.textContent = t("rawProfile.choose");
    hint.textContent = camera ? t("rawProfile.local") + " · " + camera : t("rawProfile.unknown");
    const choices = [...entries];
    if (state.rawProfile && !choices.some((entry) => entry.rawProfile === state.rawProfile)) {
      choices.push({ rawProfile: state.rawProfile, rawProfileName: state.rawProfileName || "DCP" });
    }
    select.replaceChildren(el("option", { value: "" }, t("rawProfile.default")),
      ...choices.map((entry) => el("option", { value: entry.rawProfile }, entry.rawProfileName)));
    select.value = state.rawProfile || "";
    select.disabled = button.disabled = busy || state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
  }
  function apply(entry) {
    const previous = store.get();
    store.set({ rawProfile: entry?.rawProfile || "", rawProfileName: entry?.rawProfileName || "",
      ...(!previous.rawProfile && entry?.rawProfile ? { brightness: 0 } : {}) });
  }
  select.addEventListener("change", () => apply(entries.find((entry) => entry.rawProfile === select.value)
    || (select.value ? { rawProfile: select.value, rawProfileName: store.get().rawProfileName } : null)));
  button.addEventListener("click", () => file.click());
  file.addEventListener("change", async () => {
    const selected = file.files[0], sessionId = store.get().sessionId;
    file.value = "";
    if (!selected || !sessionId) return;
    busy = true; sync();
    try {
      const entry = await api.uploadRawProfile(sessionId, selected);
      if (store.get().sessionId !== sessionId) return;
      entries = [...entries.filter((item) => item.rawProfile !== entry.rawProfile), entry];
      apply(entry);
    } catch (error) { toast?.(error.message); }
    finally { busy = false; sync(); }
  });
  store.watchAny(["sessionId", "file"], async (state) => {
    const current = ++request;
    entries = []; camera = ""; isRaw = false; sync();
    if (!state.sessionId || !state.file) return;
    try {
      const result = await api.rawProfiles(state.sessionId);
      if (current !== request) return;
      entries = result.entries; camera = result.camera; isRaw = result.isRaw; sync();
    } catch (error) { if (current === request) toast?.(error.message); }
  }, { immediate: true });
  store.watchAny(["rawProfile", "rawProfileName", "uploading", "restoring", "optimizing", "starting", "jobId"], sync);
  onLocaleChange(sync);
}
