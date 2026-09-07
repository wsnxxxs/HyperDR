import { api } from "../core/api.js";
import { store } from "../core/store.js";
import { el, role, setText, setPressed } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";

export function mountLutLibrary({ toast }) {
  const panel = role("lut-library"), browse = role("lut-library-open");
  const list = role("lut-library-list"), status = role("lut-library-status");
  const input = role("lut-file"), load = role("lut-load");
  const rows = new Map();
  const spaceName = (id) => ({ srgb: "sRGB", p3: "Display P3", rec709: "Rec.709", hlg: "HLG", pq: "PQ", "slog3-sgamut3cine": "S-Log3" }[id] || id);
  const close = () => { panel.hidden = true; browse.setAttribute("aria-expanded", "false"); browse.focus(); };

  async function refresh() {
    const result = await api.lutLibrary();
    store.set({ lutLibraryEntries: result.entries });
  }
  async function perform(action) {
    if (store.get().lutLibraryBusy) return;
    store.set({ lutLibraryBusy: true, lutLibraryError: "" });
    try { await action(); }
    catch (error) {
      store.set({ lutLibraryError: error.message || t("lut.libraryFailed") });
      toast?.(error.message || t("lut.libraryFailed"));
    } finally { store.set({ lutLibraryBusy: false }); }
  }
  function apply(saved, sessionId) {
    if (store.get().sessionId !== sessionId) return;
    const technical = ["hlg", "pq", "slog3-sgamut3cine"].includes(saved.lutInput);
    store.set({ ...saved, lutStrength: 1, ...(technical ? { previewOptimized: false } : {}) });
  }
  browse.addEventListener("click", () => {
    if (!panel.hidden) { close(); return; }
    panel.hidden = false;
    browse.setAttribute("aria-expanded", "true");
    void perform(refresh);
  });
  role("lut-library-close").addEventListener("click", close);
  panel.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.stopPropagation(); close(); }
  });
  load.addEventListener("click", () => input.click());
  input.addEventListener("change", () => {
    const files = [...(input.files || [])], sessionId = store.get().sessionId;
    input.value = "";
    if (!files.length || !sessionId) return;
    void perform(async () => {
      try {
        for (const [index, file] of files.entries()) {
          const saved = await api.uploadLut(sessionId, file);
          if (index === 0) apply(saved, sessionId);
        }
      } finally { await refresh(); }
    });
  });

  function render() {
    rows.clear(); list.replaceChildren();
    for (const entry of store.get().lutLibraryEntries) {
      const choose = el("button", { type: "button", class: "lut-library-choice", "aria-pressed": "false" },
        el("strong", {}, entry.lutName), el("small", {}, `${spaceName(entry.lutInput)} → ${spaceName(entry.lutOutput)}`));
      choose.addEventListener("click", () => {
        const sessionId = store.get().sessionId;
        void perform(async () => apply(await api.applyLibraryLut(sessionId, entry.lutId), sessionId));
      });
      const remove = el("button", { type: "button", class: "link-button", "aria-label": t("lut.deleteNamed", { name: entry.lutName }) }, t("lut.delete"));
      remove.addEventListener("click", () => void perform(async () => {
        await api.removeLibraryLut(entry.lutId);
        await refresh();
        load.focus();
      }));
      list.append(el("div", { class: "lut-library-item" }, choose, remove));
      rows.set(entry.lutId, { choose, remove });
    }
    sync();
  }
  function sync() {
    const state = store.get();
    const locked = state.lutLibraryBusy || state.uploading || state.restoring || !state.sessionId;
    load.disabled = locked;
    for (const [id, { choose, remove }] of rows) {
      setPressed(choose, id === state.lutId);
      choose.disabled = locked;
      remove.disabled = state.lutLibraryBusy;
    }
    setText(status, state.lutLibraryError || (state.lutLibraryBusy ? t("lut.loading")
      : state.lutLibraryEntries.length ? "" : t("lut.libraryEmpty")));
    panel.setAttribute("aria-busy", String(state.lutLibraryBusy));
  }
  store.watch("lutLibraryEntries", render);
  store.watchAny(["lutLibraryBusy", "lutLibraryError", "sessionId", "uploading", "restoring", "lutId"], sync, { immediate: true });
  onLocaleChange(render);

  return {
    async saveSpaces(state) {
      if (!state.lutLibraryEntries.some((entry) => entry.lutId === state.lutId)) return;
      try {
        const saved = await api.updateLibraryLut(state.lutId, { lutInput: state.lutInput, lutOutput: state.lutOutput });
        store.set({ lutLibraryEntries: store.get().lutLibraryEntries.map((entry) => entry.lutId === saved.lutId ? saved : entry) });
      } catch (error) { toast?.(error.message || t("lut.libraryFailed")); }
    },
  };
}
