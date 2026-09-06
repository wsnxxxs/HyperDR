import { store } from "../core/store.js";
import { el, debounce } from "../core/dom.js";
import { toOptions } from "../settings/schema.js";
import { t, onLocaleChange } from "../i18n/index.js";
import qrcode from "../vendor/qrcode.mjs";

export async function phoneRequest(path, body) {
  const response = await fetch(`/api/phone/${path}`, body === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok) throw Object.assign(new Error(data.error || t("phone.failed")), { code: data.code });
  return data;
}

export function mountPhoneWorkbench({ stage, toast }) {
  let owner = sessionStorage.getItem("hyperdr.phone.owner");
  if (!owner) {
    owner = crypto.randomUUID();
    sessionStorage.setItem("hyperdr.phone.owner", owner);
  }
  let active = false, sending = false, applying = false, busy = false;
  let lastSnapshot = null, connection = null, failure = "";
  const button = document.getElementById("phone-connect");
  const title = el("h3");
  const subtitle = el("p", { class: "phone-subtitle" });
  const status = el("p", { class: "phone-status", role: "status" });
  const qr = el("div", { class: "phone-qr" });
  const placeholder = el("div", { class: "phone-placeholder" },
    el("i", { class: "ph ph-qr-code", "aria-hidden": "true" }), el("span"));
  const addresses = el("select", { "aria-label": t("phone.address") });
  const addressLabel = el("label", { class: "phone-address-label" }, el("span"), addresses);
  const link = el("input", { readonly: true, "aria-label": t("phone.link") });
  const copy = el("button", { type: "button", class: "button" });
  const note = el("p");
  const previewTitle = el("h4");
  const start = el("button", { type: "button", class: "button button--primary" });
  const stop = el("button", { type: "button", class: "button" });
  const steps = ["phone.stepNetwork", "phone.stepImport", "phone.stepPreview"].map((key) =>
    el("li", {}, t(key)));
  const pairing = el("div", { class: "phone-pairing" },
    el("div", { class: "phone-code" }, qr, placeholder),
    el("div", { class: "phone-instructions" },
      el("ol", {}, ...steps), addressLabel, el("div", { class: "phone-link" }, link, copy)));
  const privacy = el("p", { class: "phone-privacy" });
  const node = el("div", { class: "phone-settings" },
    el("header", { class: "phone-heading" },
      el("i", { class: "ph ph-device-mobile", "aria-hidden": "true" }),
      el("div", {}, title, subtitle)),
    el("div", { class: "phone-connection" }, status, el("div", { class: "phone-actions" }, start, stop)),
    pairing, el("div", { class: "phone-preview-note" }, previewTitle, note), privacy);
  function renderAddress() {
    link.value = addresses.value;
    qr.replaceChildren();
    placeholder.hidden = Boolean(link.value);
    copy.disabled = !link.value;
    if (!link.value) return;
    const code = qrcode(0, "M");
    code.addData(link.value);
    code.make();
    // The SVG is generated locally from a server-issued URL, with no network service.
    qr.innerHTML = code.createSvgTag({ cellSize: 5, margin: 20, scalable: true });
    qr.querySelector("svg").setAttribute("aria-label", t("phone.scan"));
  }
  addresses.addEventListener("change", renderAddress);
  copy.addEventListener("click", async () => {
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(link.value);
      else { link.select(); document.execCommand("copy"); }
      toast(t("phone.copied"));
    } catch { link.select(); }
  });
  function labels() {
    title.textContent = t("phone.title");
    subtitle.textContent = t("phone.subtitle");
    placeholder.querySelector("span").textContent = t("phone.qrPlaceholder");
    addressLabel.querySelector("span").textContent = t("phone.address");
    addresses.setAttribute("aria-label", t("phone.address"));
    link.setAttribute("aria-label", t("phone.link"));
    link.placeholder = t("phone.linkPlaceholder");
    ["phone.stepNetwork", "phone.stepImport", "phone.stepPreview"].forEach((key, index) => {
      steps[index].textContent = t(key);
    });
    button.querySelector("span").textContent = t(lastSnapshot?.phoneConnected && active ? "phone.connected" : "phone.connect");
    copy.textContent = t("phone.copy");
    copy.disabled = !link.value || busy;
    start.textContent = t(busy ? "phone.starting" : active ? "phone.refresh" : "phone.enable");
    start.hidden = active && Boolean(connection?.urls.length);
    start.disabled = busy;
    stop.textContent = t("phone.disconnect");
    stop.hidden = !active;
    stop.disabled = busy;
    button.disabled = busy;
    addresses.disabled = busy;
    addressLabel.hidden = !active || !connection?.urls.length;
    previewTitle.textContent = t(!active ? "phone.previewTitle" : connection?.secure ? "phone.previewSecure" : "phone.previewSdr");
    note.textContent = t(!active ? "phone.previewHelp" : connection?.secure ? "phone.secureNote" : "phone.httpsNote");
    privacy.textContent = t("phone.private");
    status.textContent = failure || t(busy ? "phone.starting" : !active ? "phone.off" : !connection?.urls.length ? "phone.noNetwork" : lastSnapshot?.upload ? "phone.receiving" : lastSnapshot?.phoneConnected ? "phone.live" : "phone.waiting");
    node.dataset.state = failure ? "error" : active ? "active" : "off";
    button.dataset.connected = String(Boolean(active && lastSnapshot?.phoneConnected));
    qr.querySelector("svg")?.setAttribute("aria-label", t("phone.scan"));
  }
  async function applySnapshot(snapshot) {
    lastSnapshot = snapshot;
    labels();
    if (snapshot.pending && snapshot.current?.sessionId && !applying) {
      applying = true;
      try { await stage.acceptPhonePhoto(snapshot.current); }
      finally { applying = false; }
    } else if (!applying) {
      const remote = snapshot.upload;
      if (remote || store.get().phoneUploading) {
        store.set({ phoneUploading: Boolean(remote), uploading: Boolean(remote), uploadProgress: remote?.progress || 0 });
      }
    }
  }
  async function publish() {
    if (!active || sending || applying || store.get().restoring) return;
    sending = true;
    try {
      const s = store.get();
      const snapshot = await phoneRequest("publish", { owner, current: {
        sessionId: s.sessionId, options: { ...toOptions(s), useModel: Boolean(s.previewOptimized) },
        busy: Boolean(s.starting || s.jobId || s.optimizing || (s.uploading && !s.phoneUploading)),
        status: s.jobId || s.starting ? "exporting" : s.previewError ? "error" : s.previewReady ? "ready" : "updating",
      } });
      failure = "";
      await applySnapshot(snapshot);
    } catch (error) {
      if (error.code === "workbench_owner") {
        active = false;
        sessionStorage.removeItem("hyperdr.phone.active");
        clearConnection();
        toast(error.message, true);
      }
      failure = error.message;
      labels();
    } finally { sending = false; }
  }
  const schedule = debounce(publish, 80);
  store.subscribe((_s, _p, changed) => {
    if (!changed.every((key) => ["viewerZoom", "viewerPanX", "viewerPanY", "comparing", "splitRatio", "maskKey"].includes(key))) schedule();
  });
  function clearConnection() {
    connection = null;
    lastSnapshot = null;
    addresses.replaceChildren();
    renderAddress();
  }
  async function connect() {
    if (busy || (active && connection?.urls.length)) return;
    busy = true;
    failure = "";
    labels();
    try {
      connection = await phoneRequest("connect", { owner });
      active = true;
      sessionStorage.setItem("hyperdr.phone.active", "1");
      addresses.replaceChildren(...connection.urls.map((url) => el("option", { value: url }, new URL(url).host)));
      renderAddress();
      await publish();
      // A photo already on the desktop needs to enter the shared frame cache once.
      if (store.get().file && !lastSnapshot?.frameReady) await stage.reload();
    } catch (error) { failure = error.message; toast(error.message, true); }
    finally { busy = false; labels(); }
  }
  start.addEventListener("click", connect);
  stop.addEventListener("click", async () => {
    busy = true;
    stop.disabled = true;
    button.disabled = true;
    try {
      await phoneRequest("disconnect", { owner });
      active = false;
      sessionStorage.removeItem("hyperdr.phone.active");
      clearConnection();
      failure = "";
      if (store.get().phoneUploading) store.set({ uploading: false, phoneUploading: false });
    } catch (error) { failure = error.message; toast(error.message, true); }
    finally { busy = false; labels(); if (!active) start.focus(); }
  });
  setInterval(() => {
    if (active && (sending || applying)) phoneRequest("heartbeat", { owner }).catch(() => {});
    else publish();
  }, 2000);
  onLocaleChange(labels);
  renderAddress();
  labels();
  return {
    node, connect,
    async restore() { if (sessionStorage.getItem("hyperdr.phone.active") === "1") await connect(); },
  };
}
