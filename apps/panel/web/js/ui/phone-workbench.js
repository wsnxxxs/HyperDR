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
  let qrMode = "connect", requestedSetup = false, generation = 0, heartbeatSending = false;
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
  const prepare = el("button", { type: "button", class: "button button--primary" });
  const setup = el("button", { type: "button", class: "button" });
  const ordinary = el("button", { type: "button", class: "button" });
  const tlsStatus = el("p", { class: "phone-tls-status", role: "status" });
  const diagnosticStatus = el("p", { class: "phone-diagnostic-status" });
  const advancedTitle = el("summary");
  const advancedContent = el("div", { class: "phone-certificate-details" });
  const advanced = el("details", {}, advancedTitle, advancedContent);
  const helpTitle = el("summary");
  const helpText = el("p");
  const troubleshooting = el("details", { class: "phone-troubleshooting" }, helpTitle, helpText);
  const setupMode = el("button", { type: "button", class: "button", "aria-pressed": "false" });
  const connectMode = el("button", { type: "button", class: "button", "aria-pressed": "true" });
  const closeSetup = el("button", { type: "button", class: "button" });
  const modes = el("div", { class: "phone-qr-modes", role: "group" }, setupMode, connectMode, closeSetup);
  const qrCaption = el("p", { class: "phone-qr-caption", role: "status" });
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
    el("div", { class: "phone-preview-note" }, previewTitle, note, tlsStatus, diagnosticStatus,
      el("div", { class: "phone-actions phone-security-actions" }, prepare, setup, ordinary), advanced),
    modes, qrCaption, pairing, troubleshooting, privacy);
  function renderAddress() {
    const next = addresses.value;
    if (link.value === next && qr.childElementCount) return;
    link.value = next;
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
  function updateAddresses() {
    const urls = (qrMode === "setup" ? connection?.setupUrls : connection?.urls) || [];
    const old = addresses.value;
    let oldHost = "";
    try { oldHost = new URL(old).hostname; } catch {}
    if (JSON.stringify([...addresses.options].map((option) => option.value)) !== JSON.stringify(urls)) {
      addresses.replaceChildren(...urls.map((url) => el("option", { value: url }, new URL(url).host)));
      addresses.value = urls.find((url) => url === old) || urls.find((url) => new URL(url).hostname === oldHost) || urls[0] || "";
    }
    renderAddress();
  }
  function updateConnection(next) {
    connection = next;
    if (requestedSetup && next.setupUrls?.length) { qrMode = "setup"; requestedSetup = false; }
    if (qrMode === "setup" && !next.setupUrls?.length) qrMode = "connect";
    updateAddresses(); labels();
  }
  function mode(next) { qrMode = next; updateAddresses(); labels(); }
  setupMode.addEventListener("click", () => mode("setup"));
  connectMode.addEventListener("click", () => mode("connect"));
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
    start.hidden = false;
    start.disabled = busy;
    stop.textContent = t("phone.disconnect");
    stop.hidden = !active;
    stop.disabled = busy;
    button.disabled = busy;
    addresses.disabled = busy;
    addressLabel.hidden = !active || !addresses.options.length;
    previewTitle.textContent = t(!active ? "phone.previewTitle" : connection?.secure ? "phone.previewSecure" : "phone.previewSdr");
    note.textContent = t(!active ? "phone.previewHelp" : connection?.secure ? "phone.secureNote" : "phone.httpsNote");
    privacy.textContent = t("phone.private");
    status.textContent = failure || t(busy ? "phone.starting" : !active ? "phone.off" : !connection?.urls.length ? "phone.noNetwork" : lastSnapshot?.upload ? "phone.receiving" : lastSnapshot?.phoneConnected ? "phone.live" : "phone.waiting");
    node.dataset.state = failure ? "error" : active ? "active" : "off";
    button.dataset.connected = String(Boolean(active && lastSnapshot?.phoneConnected));
    qr.querySelector("svg")?.setAttribute("aria-label", t("phone.scan"));
    const tls = connection?.tls || {};
    const pending = ["preparing", "waiting"].includes(tls.job);
    const diagnostics = connection?.diagnostics ?? null;
    tlsStatus.textContent = !active ? "" : t(tls.job === "waiting" ? "phone.tlsWaiting" : tls.job === "preparing" ? "phone.tlsPreparing" : tls.job === "error" ? "phone.tlsError" : tls.ready ? "phone.tlsReady" : "phone.tlsMissing");
    if (tls.jobError || tls.error) tlsStatus.textContent += ` ${tls.jobError || tls.error}`;
    diagnosticStatus.textContent = !active ? "" : t(!diagnostics ? "phone.checkUnknown" : !diagnostics.transportSecure || !diagnostics.secureContext ? "phone.checkInsecure" : diagnostics.hdr ? "phone.checkReady" : ({ webgpu: "phone.checkWebgpu", display: "phone.checkDisplay", renderer: "phone.checkRenderer", insecure: "phone.checkInsecure" })[diagnostics.reason] || "phone.checkRenderer");
    prepare.textContent = t(tls.job === "error" ? "phone.prepareRetry" : "phone.prepare");
    prepare.hidden = !active || (tls.ready && connection?.secure && !pending && tls.job !== "error");
    prepare.disabled = busy || pending || (!tls.canPrepare && !tls.ready);
    setup.textContent = t(diagnostics?.secureContext && diagnostics?.transportSecure ? "phone.setupAnother" : "phone.setupPhone");
    setup.hidden = !active || !tls.rootAvailable || !connection?.secure;
    setup.disabled = busy || pending;
    ordinary.textContent = t("phone.useOrdinary");
    ordinary.hidden = !active || (!connection?.secure && !pending);
    ordinary.disabled = busy || Boolean(lastSnapshot?.upload);
    advancedTitle.textContent = t("phone.advanced");
    const details = [
      ["phone.certificateName", tls.certificateName], ["phone.fingerprint", tls.fingerprint],
      ["phone.certificateExpiry", tls.expiresAt ? new Date(typeof tls.expiresAt === "number" ? tls.expiresAt * 1000 : tls.expiresAt).toLocaleString() : ""],
      ["phone.certificatePath", tls.certificatePath], ["phone.certificateError", tls.jobError || tls.error],
      ["phone.diagnosticDetail", diagnostics?.detail],
    ];
    const detailKey = JSON.stringify(details);
    if (advancedContent.dataset.key !== detailKey) {
      advancedContent.dataset.key = detailKey;
      advancedContent.replaceChildren(...details.filter(([, value]) => value).map(([key, value]) => el("p", {}, el("strong", {}, t(key)), el("span", {}, String(value)))));
    }
    advanced.hidden = !active;
    helpTitle.textContent = t("phone.troubleshooting"); helpText.textContent = t("phone.troubleshootingHelp");
    modes.hidden = !active;
    setupMode.textContent = t("phone.modeSetup"); connectMode.textContent = t("phone.modeConnect");
    setupMode.hidden = !connection?.setupUrls?.length;
    closeSetup.textContent = t("phone.closeSetup"); closeSetup.hidden = !connection?.setupUrls?.length; closeSetup.disabled = busy;
    setupMode.setAttribute("aria-pressed", String(qrMode === "setup")); connectMode.setAttribute("aria-pressed", String(qrMode === "connect"));
    qrCaption.hidden = !active;
    qrCaption.textContent = t(qrMode === "setup" ? "phone.setupQrHint" : "phone.connectQrHint");
    if (qrMode === "setup") {
      ["phone.stepNetwork", "phone.stepSetup", "phone.stepCheck"].forEach((key, index) => { steps[index].textContent = t(key); });
    }
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
        sessionId: s.sessionId,
        // The phone workbench receives the same option payload the panel sends,
        // and the model travels beside `useModel` there too; otherwise a phone
        // session would restore onto the desktop with no model recorded.
        options: {
          ...toOptions(s),
          useModel: Boolean(s.previewOptimized),
          modelId: s.modelId,
        },
        busy: Boolean(s.starting || s.jobId || s.optimizing || (s.uploading && !s.phoneUploading)),
        status: s.jobId || s.starting ? "exporting" : s.previewError ? "error" : s.previewReady ? "ready" : "updating",
      } });
      failure = "";
      await applySnapshot(snapshot);
      const currentGeneration = generation;
      const nextConnection = await phoneRequest(`connection?owner=${encodeURIComponent(owner)}`);
      if (active && generation === currentGeneration) updateConnection(nextConnection);
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
    generation++;
    connection = null;
    lastSnapshot = null;
    qrMode = "connect"; requestedSetup = false;
    addresses.replaceChildren();
    renderAddress();
  }
  async function connect() {
    if (busy) return;
    if (active) { await publish(); return; }
    busy = true;
    failure = "";
    labels();
    try {
      const next = await phoneRequest("connect", { owner });
      active = true;
      sessionStorage.setItem("hyperdr.phone.active", "1");
      requestedSetup = Boolean(next.setupUrls?.length);
      updateConnection(next);
      await publish();
      // A photo already on the desktop needs to enter the shared frame cache once.
      if (store.get().file && !lastSnapshot?.frameReady) await stage.reload();
    } catch (error) { failure = error.message; toast(error.message, true); }
    finally { busy = false; labels(); }
  }
  async function securityAction(path, extra = {}) {
    if (!active || busy) return;
    busy = true; failure = ""; labels();
    try {
      await phoneRequest(path, { owner, ...extra });
      if (path === "tls/prepare" || path === "setup") requestedSetup = true;
      if (path === "connect" || path === "setup/close") { requestedSetup = false; qrMode = "connect"; }
      // Publish first verifies ownership before adopting the connection response.
      await publish();
    } catch (error) {
      failure = error.message;
      if (error.code === "workbench_owner") { active = false; sessionStorage.removeItem("hyperdr.phone.active"); clearConnection(); }
      toast(error.message, true);
    } finally { busy = false; labels(); }
  }
  prepare.addEventListener("click", () => securityAction(connection?.tls?.ready && !connection?.tls?.canPrepare ? "connect" : "tls/prepare"));
  setup.addEventListener("click", () => securityAction("setup"));
  ordinary.addEventListener("click", () => securityAction("connect", { ordinary: true }));
  closeSetup.addEventListener("click", () => securityAction("setup/close"));
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
    if (active && (sending || applying)) {
      if (!heartbeatSending) {
        heartbeatSending = true;
        phoneRequest("heartbeat", { owner }).catch(() => {}).finally(() => { heartbeatSending = false; });
      }
    }
    else publish();
  }, 2000);
  onLocaleChange(() => { advancedContent.dataset.key = ""; labels(); });
  renderAddress();
  labels();
  return {
    node, connect,
    async restore() { if (sessionStorage.getItem("hyperdr.phone.active") === "1") await connect(); },
  };
}
