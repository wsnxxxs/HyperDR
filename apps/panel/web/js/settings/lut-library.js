import { api } from "../core/api.js";
import { store } from "../core/store.js";
import { el, role, setText } from "../core/dom.js";
import { t, onLocaleChange } from "../i18n/index.js";

export function mountLutLibrary({ toast }) {
  const panel = role("lut-library"), browse = role("lut-library-open");
  const list = role("lut-library-list"), status = role("lut-library-status");
  const input = role("lut-file"), load = role("lut-load");
  const search = role("lut-library-search"), done = role("lut-library-done");
  const rows = new Map();
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
  browse.addEventListener("click", () => {
    if (store.get().lutLibraryOpen) { close(); return; }
    store.set({ lutLibraryOpen: true });
    search.focus({ preventScroll: true });
    void perform(refresh);
  });
  role("lut-library-close").addEventListener("click", close);
  done.addEventListener("click", close);
  store.watch("lutLibraryOpen", (open) => {
    if (open && !panel.open) panel.showModal();
    if (!open && panel.open) panel.close();
    document.documentElement.classList.toggle("lut-library-open", open);
    browse.setAttribute("aria-expanded", String(open));
  }, { immediate: true });
  panel.addEventListener("close", () => { if (!panel.open) store.set({ lutLibraryOpen: false }); });
  panel.addEventListener("cancel", (event) => { event.preventDefault(); close(); });
  panel.addEventListener("click", (event) => {
    const bounds = panel.getBoundingClientRect();
    if (event.target === panel && (event.clientX < bounds.left || event.clientX > bounds.right
      || event.clientY < bounds.top || event.clientY > bounds.bottom)) close();
  });
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
        for (const file of files) await api.uploadLut(sessionId, file);
      } finally { await refresh(); }
    });
  });

  function render() {
    rows.clear(); list.replaceChildren();
    const query = store.get().lutLibraryQuery.trim().toLocaleLowerCase();
    if (search.value !== store.get().lutLibraryQuery) search.value = store.get().lutLibraryQuery;
    for (const entry of store.get().lutLibraryEntries.filter((entry) => entry.lutName.toLocaleLowerCase().includes(query))) {
      const info = el("div", { class: "lut-library-info", title: entry.lutName },
        el("i", { class: "ph ph-palette lut-look-icon", "aria-hidden": "true" }),
        el("span", { class: "lut-look-copy" }, el("strong", {}, lookName(entry.lutName)), el("small", {}, `${spaceName(entry.lutInput)} → ${spaceName(entry.lutOutput)}`)));
      const remove = el("button", { type: "button", class: "icon-button lut-library-remove", title: t("lut.delete"), "aria-label": t("lut.deleteNamed", { name: entry.lutName }) }, el("i", { class: "ph ph-trash", "aria-hidden": "true" }));
      remove.addEventListener("click", () => void perform(async () => {
        await api.removeLibraryLut(entry.lutId);
        await refresh();
        load.focus();
      }));
      const row = el("div", { class: "lut-library-item" }, info, remove);
      list.append(row);
      rows.set(entry.lutId, { remove });
    }
    sync();
  }
  function sync() {
    const state = store.get();
    const locked = state.lutLibraryBusy || state.uploading || state.restoring || state.optimizing || state.starting || Boolean(state.jobId);
    load.disabled = locked;
    for (const { remove } of rows.values()) {
      remove.disabled = state.lutLibraryBusy;
    }
    setText(role("lut-library-count"), t("lut.count", { count: state.lutLibraryEntries.length }));
    setText(role("lut-library-description"), t("lut.manageHint"));
    setText(status, state.lutLibraryError || (state.lutLibraryBusy ? t("lut.loading")
      : !state.lutLibraryEntries.length ? t("lut.libraryEmpty") : !rows.size ? t("lut.searchEmpty") : ""));
    status.hidden = !status.textContent;
    panel.setAttribute("aria-busy", String(state.lutLibraryBusy));
  }
  store.watchAny(["lutLibraryEntries", "lutLibraryQuery"], render);
  store.watchAny(["lutLibraryBusy", "lutLibraryError", "uploading", "restoring", "optimizing", "starting", "jobId"], sync, { immediate: true });
  onLocaleChange(render);
  void refresh().catch((error) => store.set({ lutLibraryError: error.message || t("lut.libraryFailed") }));

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
