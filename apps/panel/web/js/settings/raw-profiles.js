import { el, role } from "../core/dom.js";
import { store } from "../core/store.js";
import { api } from "../core/api.js";
import { t, onLocaleChange } from "../i18n/index.js";

export function mountRawProfiles({ toast } = {}) {
  const section = role("raw-profile-panel");
  const title = el("h2", { id: "raw-profile-title" });
  const cameraName = el("p", { class: "raw-profile-camera" });
  const select = el("select", { class: "lut-select", "aria-labelledby": "raw-profile-title",
    "aria-describedby": "raw-profile-hint" });
  const file = el("input", { type: "file", accept: ".dcp", hidden: true });
  const button = el("button", { type: "button", class: "link-button raw-profile-import" });
  const hint = el("p", { id: "raw-profile-hint", class: "field-hint", "aria-live": "polite" });
  const lensToggle = el("input", { type: "checkbox", "aria-describedby": "lens-profile-hint" });
  const lensLabel = el("span");
  const lensHint = el("p", { id: "lens-profile-hint", class: "field-hint", "aria-live": "polite" });
  const lensRow = el("label", { class: "lens-profile-toggle" }, lensToggle, lensLabel);
  section.setAttribute("aria-labelledby", "raw-profile-title");
  section.append(el("div", { class: "raw-profile-head" }, title, button), cameraName, select, file, hint, lensRow, lensHint);
  let entries = [], camera = "", isRaw = false, busy = false, request = 0;
  let lens = null;
  function sync() {
    const state = store.get();
    section.hidden = !isRaw;
    title.textContent = t("rawProfile.label");
    button.textContent = t("rawProfile.choose");
    cameraName.textContent = camera;
    cameraName.hidden = !camera;
    hint.textContent = entries.length ? t("rawProfile.local", { count: entries.length })
      : camera ? t("rawProfile.empty") : t("rawProfile.unknown");
    const choices = [...entries];
    if (state.rawProfile && !choices.some((entry) => entry.rawProfile === state.rawProfile)) {
      choices.push({ rawProfile: state.rawProfile, rawProfileName: state.rawProfileName || "DCP" });
    }
    select.replaceChildren(el("option", { value: "" }, t("rawProfile.default")),
      ...choices.map((entry) => el("option", { value: entry.rawProfile }, entry.rawProfileName)));
    select.value = state.rawProfile || "";
    select.disabled = button.disabled = file.disabled = !isRaw || busy || state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    lensToggle.checked = Boolean(lens?.available && state.lensCorrection !== false);
    lensToggle.disabled = select.disabled || !lens?.available;
    lensLabel.textContent = t("lensProfile.label");
    lensHint.textContent = lens?.available
      ? t(lensToggle.checked ? "lensProfile.enabled" : "lensProfile.disabled", { name: lens.profileName })
      : t(lens?.lens ? "lensProfile.unmatched" : "lensProfile.unknown");
  }
  lensToggle.addEventListener("change", () => store.set({ lensCorrection: lensToggle.checked }));
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
    if (!isRaw || !selected || !sessionId) return;
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
    entries = []; camera = ""; isRaw = false; lens = null; sync();
    if (!state.sessionId || !state.file) return;
    try {
      const result = await api.rawProfiles(state.sessionId);
      if (current !== request) return;
      entries = result.entries; camera = result.camera; isRaw = result.isRaw;
      lens = result.lensCorrection;
      store.set({ lensProfileName: lens?.profileName || "" });
      sync();
    } catch (error) { if (current === request) toast?.(error.message); }
  }, { immediate: true });
  store.watchAny(["rawProfile", "rawProfileName", "lensCorrection", "uploading", "restoring", "optimizing", "starting", "jobId"], sync);
  onLocaleChange(sync);
}
