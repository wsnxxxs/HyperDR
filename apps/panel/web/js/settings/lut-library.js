import { api } from "../core/api.js";
import { store } from "../core/store.js";
import { el, role, setText, setPressed } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";

export function mountLutLibrary({ toast }) {
  const panel = role("lut-library"), browse = role("lut-library-open");
  const list = role("lut-library-list"), status = role("lut-library-status");
  const input = role("lut-file"), load = role("lut-load");
  const search = role("lut-library-search"), done = role("lut-library-done");
  const rail = panel.parentElement;
  const rows = new Map();
  let railScroll = 0;
  const lookName = (name) => name.replace(/\.cube$/i, "");
  const spaceName = (id) => ({ srgb: "sRGB", p3: "Display P3", rec709: "Rec.709", hlg: "HLG", pq: "PQ", "slog3-sgamut3cine": "S-Log3" }[id] || id);
  const close = () => { store.set({ lutLibraryOpen: false }); browse.focus(); };

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
    if (store.get().lutLibraryOpen) { close(); return; }
    store.set({ lutLibraryOpen: true });
    search.focus({ preventScroll: true });
    void perform(refresh);
  });
  role("lut-library-close").addEventListener("click", close);
  done.addEventListener("click", () => {
    close();
    if (!store.get().file) { role("open-photo").click(); return; }
    const lut = role("lut-panel");
    lut.open = true;
    lut.scrollIntoView({ block: "nearest" });
    role("lut-enabled").focus({ preventScroll: true });
  });
  store.watch("lutLibraryOpen", (open) => {
    if (open) railScroll = rail.scrollTop;
    panel.hidden = !open;
    rail.dataset.libraryOpen = String(open);
    browse.setAttribute("aria-expanded", String(open));
    rail.scrollTop = open ? 0 : railScroll;
  }, { immediate: true });
  panel.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); }
  });
  search.addEventListener("input", () => store.set({ lutLibraryQuery: search.value }));
  load.addEventListener("click", () => input.click());
  input.addEventListener("change", () => {
    const files = [...(input.files || [])], currentSession = store.get().sessionId;
    input.value = "";
    if (!files.length) return;
    void perform(async () => {
      const sessionId = currentSession || (await api.newSession()).sessionId;
      store.set({ lutLibraryQuery: "" });
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
    const query = store.get().lutLibraryQuery.trim().toLocaleLowerCase();
    if (search.value !== store.get().lutLibraryQuery) search.value = store.get().lutLibraryQuery;
    for (const entry of store.get().lutLibraryEntries.filter((entry) => entry.lutName.toLocaleLowerCase().includes(query))) {
      const selected = el("span", { class: "lut-library-selected", hidden: true }, t("lut.selected"));
      const choose = el("button", { type: "button", class: "lut-library-choice", "aria-pressed": "false", title: entry.lutName },
        el("i", { class: "ph ph-palette lut-look-icon", "aria-hidden": "true" }),
        el("span", { class: "lut-look-copy" }, el("strong", {}, lookName(entry.lutName)), el("small", {}, `${spaceName(entry.lutInput)} → ${spaceName(entry.lutOutput)}`)), selected);
      choose.addEventListener("click", () => {
        const sessionId = store.get().sessionId;
        void perform(async () => apply(await api.applyLibraryLut(sessionId, entry.lutId), sessionId));
      });
      const remove = el("button", { type: "button", class: "icon-button lut-library-remove", title: t("lut.delete"), "aria-label": t("lut.deleteNamed", { name: entry.lutName }) }, el("i", { class: "ph ph-trash", "aria-hidden": "true" }));
      remove.addEventListener("click", () => void perform(async () => {
        await api.removeLibraryLut(entry.lutId);
        await refresh();
        load.focus();
      }));
      const row = el("div", { class: "lut-library-item" }, choose, remove);
      list.append(row);
      rows.set(entry.lutId, { choose, remove, selected, row });
    }
    sync();
  }
  function sync() {
    const state = store.get();
    const locked = state.lutLibraryBusy || state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    load.disabled = locked;
    done.disabled = state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    for (const [id, { choose, remove, selected, row }] of rows) {
      setPressed(choose, id === state.lutId);
      choose.disabled = locked || !state.file;
      remove.disabled = state.lutLibraryBusy;
      selected.hidden = id !== state.lutId;
      row.classList.toggle("is-selected", id === state.lutId);
    }
    setText(role("lut-library-count"), t("lut.count", { count: state.lutLibraryEntries.length }));
    setText(role("lut-library-description"), state.file ? t("lut.previewHint") : t("lut.choosePhoto"));
    setText(role("lut-library-current"), state.lutName ? lookName(state.lutName) : t("lut.none"));
    setText(done, state.file ? t("lut.done") : t("editor.open"));
    setText(status, state.lutLibraryError || (state.lutLibraryBusy ? t("lut.loading")
      : !state.lutLibraryEntries.length ? t("lut.libraryEmpty") : !rows.size ? t("lut.searchEmpty") : ""));
    status.hidden = !status.textContent;
    panel.setAttribute("aria-busy", String(state.lutLibraryBusy));
  }
  store.watchAny(["lutLibraryEntries", "lutLibraryQuery"], render);
  store.watchAny(["lutLibraryBusy", "lutLibraryError", "sessionId", "file", "uploading", "restoring", "optimizing", "starting", "jobId", "lutId", "lutName"], sync, { immediate: true });
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
