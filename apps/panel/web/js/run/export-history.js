import { store } from "../core/store.js";
import { role } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { validatedSettings } from "../settings/schema.js";

export function mountExportHistory({ selectResult }) {
  const group = document.createElement("div");
  group.className = "export-history";
  const label = document.createElement("label");
  const title = document.createElement("span");
  const select = document.createElement("select");
  const restore = document.createElement("button");
  restore.type = "button";
  restore.className = "link-button";
  label.append(title, select);
  group.append(label, restore);
  role("result").after(group);

  function sync(state = store.get()) {
    const entries = state.exports || [];
    group.hidden = entries.length === 0;
    title.textContent = t("workspace.versions");
    restore.textContent = t("workspace.restoreSettings");
    select.replaceChildren(...entries.map((entry) => {
      const option = document.createElement("option");
      option.value = entry.id;
      const time = new Date(entry.createdAt * 1000).toLocaleTimeString(
        document.documentElement.lang, { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      option.textContent = `${time} · ${entry.options.encoding || entry.name} · ${entry.name}`;
      return option;
    }));
    select.value = state.result?.exportId || entries[0]?.id || "";
    restore.disabled = state.uploading || state.restoring || state.optimizing;
  }
  select.addEventListener("change", () => {
    const entry = store.get().exports.find(({ id }) => id === select.value);
    if (entry) selectResult(entry);
  });
  restore.addEventListener("click", () => {
    const entry = store.get().exports.find(({ id }) => id === select.value);
    if (entry) store.set({ ...validatedSettings(entry.options),
      previewOptimized: Boolean(entry.options.useModel) });
  });
  store.watchAny(["exports", "result", "uploading", "restoring", "optimizing"], sync,
    { immediate: true });
  onLocaleChange(() => sync());
}
