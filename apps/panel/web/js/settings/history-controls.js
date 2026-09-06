import { store } from "../core/store.js";
import { role, setText } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { OPTION_KEYS } from "./schema.js";
import { createHistory } from "./history.js";

export function mountHistory() {
  const history = createHistory(store, [...OPTION_KEYS, "previewOptimized"]);
  const group = document.createElement("div");
  group.className = "edit-history";
  const undo = document.createElement("button");
  const redo = document.createElement("button");
  for (const button of [undo, redo]) {
    button.type = "button";
    button.className = "link-button";
    group.append(button);
  }
  role("settings-reset").closest(".group-head").after(group);
  const locked = () => {
    const state = store.get();
    return !state.file || state.uploading || state.restoring || state.optimizing;
  };
  const sync = () => {
    undo.disabled = locked() || !history.status().canUndo;
    redo.disabled = locked() || !history.status().canRedo;
    setText(undo, t("edit.undo")); setText(redo, t("edit.redo"));
    undo.title = t("edit.undoHint"); redo.title = t("edit.redoHint");
  };
  history.subscribe(sync);
  store.watchAny(["file", "uploading", "restoring", "optimizing"], sync);
  onLocaleChange(sync);
  undo.addEventListener("click", () => history.undo());
  redo.addEventListener("click", () => history.redo());
  const settings = document.getElementById("settings");
  settings.addEventListener("change", history.flush);
  settings.addEventListener("pointerup", () => queueMicrotask(history.flush));
  document.addEventListener("keydown", (event) => {
    if (locked() || event.altKey || !(event.ctrlKey || event.metaKey)) return;
    const target = event.target;
    if (target.isContentEditable || target.closest("dialog[open]")
        || target.matches('textarea,input:not([type="range"]),select')) return;
    const key = event.key.toLowerCase();
    if (key !== "z" && key !== "y") return;
    event.preventDefault();
    if (key === "y" || event.shiftKey) history.redo(); else history.undo();
  });
  return history;
}
