import { t } from "../js/i18n/index.js";
export function createPhoneSetup({ api, storage, hostname, userAgent, stepCounts,
  onLoading, onState, onError, onRender }) {
  // The workbench entry from the last successful state check. Kept in page memory
  // only; sessionStorage still stores nothing but the step.
  const model = { payload: null, step: 0, platform: /Android/i.test(userAgent) ? "android" : "ios",
    entry: null, loading: null };
  function stale(message) { onError(message, Boolean(model.entry)); }
  function render(focus = false) {
    model.step = Math.max(0, Math.min(model.step, stepCounts[model.platform] - 1));
    onRender(model, focus); save();
  }
  function save() { if (model.payload) { try { storage.setItem(`hyperdr-setup:${model.payload.fingerprint}`, JSON.stringify({ platform: model.platform, step: model.step })); } catch {} } }
  function verifiedEntry(payload) {
    // Only ever follow an HTTPS entry for the address this page was opened from;
    // never a target assembled from a supplied host.
    try {
      const url = new URL(payload.httpsUrl);
      return url.protocol === "https:" && url.hostname === hostname ? url.href : model.entry;
    } catch { return model.entry; }
  }
  async function runLoad({ restore = true } = {}) {
    onLoading();
    try {
      model.payload = await api.setupState();
      model.entry = verifiedEntry(model.payload);
      onState(model.payload);
      if (restore) {
        try { const saved = JSON.parse(storage.getItem(`hyperdr-setup:${model.payload.fingerprint}`)); if (saved && stepCounts[saved.platform] && Number.isInteger(saved.step)) { model.platform = saved.platform; model.step = saved.step; } } catch {}
      }
      if (!model.payload.rootAvailable) throw new Error(t("phone.mobile.setup.rootMissing"));
    } catch (error) {
      if (error.status === 410) { stale(error.message); return; }
      const message = error.timeout || error.name === "AbortError"
        ? t("phone.mobile.setup.readTimeout")
        : error instanceof TypeError
          ? t("phone.mobile.setup.offline")
          : error.message || t("phone.mobile.setup.loadFailed");
      if (model.entry) stale(t("phone.mobile.setup.staleNote", { message }));
      else onError(message);
    } finally {
      render();
    }
  }
  function load(options) {
    if (model.loading) return model.loading;
    model.loading = runLoad(options).finally(() => { model.loading = null; });
    return model.loading;
  }
  return { state: model, load, render,
    choose(platform) { model.platform = platform; model.step = 0; render(); },
    back() { model.step--; render(true); }, next() { model.step++; render(true); } };
}
