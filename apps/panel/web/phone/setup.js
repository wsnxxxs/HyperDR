import { t, applyStatic } from "../js/i18n/index.js";
import { createPhoneApi } from "../js/core/api.js";
import { createPhoneSetup } from "./setup-controller.js";

applyStatic();
const $ = (id) => document.getElementById(id);
const routes = (...labels) => `<div class="route" aria-label="${t("phone.mobile.setup.route")}">${labels.map((label) => `<span>${label}</span>`).join("")}</div>`;
const steps = {
  ios: [
    [t("phone.mobile.setup.downloadTitle"), `<p>${t("phone.mobile.setup.iosDownloadHelp")}</p><a class="download" href="/setup/root.mobileconfig">${t("phone.mobile.setup.downloadProfile")}</a><a class="download" href="/setup/root.crt">${t("phone.mobile.setup.downloadAlternative")}</a><p>${t("phone.mobile.setup.profileHelp")}</p>`],
    [t("phone.mobile.setup.iosInstallTitle"), `<p>${t("phone.mobile.setup.iosInstallHelp")}</p>` + routes(t("phone.mobile.setup.iosProfileRoute"), t("phone.mobile.setup.iosManagementRoute"), t("phone.mobile.setup.iosInstallRoute")) + `<p>${t("phone.mobile.setup.iosInstallReturn")}</p>`],
    [t("phone.mobile.setup.iosTrustTitle"), `<p>${t("phone.mobile.setup.iosTrustHelp")}</p>` + routes(t("phone.mobile.setup.iosAboutRoute"), t("phone.mobile.setup.iosTrustRoute"), t("phone.mobile.setup.iosFullTrustRoute")) + `<p class="callout">${t("phone.mobile.setup.iosTrustCallout")}</p>`],
    [t("phone.mobile.setup.checkTitle"), `<p>${t("phone.mobile.setup.iosCheckHelp")}</p><a class="download primary" data-entry href="/setup/continue">${t("phone.mobile.setup.enter")}</a><p>${t("phone.mobile.setup.iosCheckNote")}</p>`],
  ],
  android: [
    [t("phone.mobile.setup.downloadTitle"), `<p>${t("phone.mobile.setup.androidDownloadHelp")}</p><a class="download" href="/setup/root.crt">${t("phone.mobile.setup.downloadRoot")}</a><p>${t("phone.mobile.setup.androidDownloadNote")}</p>`],
    [t("phone.mobile.setup.androidInstallTitle"), `<p>${t("phone.mobile.setup.androidInstallHelp")}</p>` + routes(t("phone.mobile.setup.androidSearchRoute"), t("phone.mobile.setup.androidCaRoute"), t("phone.mobile.setup.androidInstallRoute")) + `<p class="callout">${t("phone.mobile.setup.androidInstallCallout")}</p><p>${t("phone.mobile.setup.androidFileHelp")}</p>`],
    [t("phone.mobile.setup.checkTitle"), `<p>${t("phone.mobile.setup.androidCheckHelp")}</p><a class="download primary" data-entry href="/setup/continue">${t("phone.mobile.setup.enter")}</a><p>${t("phone.mobile.setup.androidCheckNote")}</p>`],
  ],
};
function applyEntry(model) {
  for (const link of document.querySelectorAll("[data-entry], #continue-link")) link.href = model.entry || "/setup/continue";
  if (model.entry) $("resume").href = model.entry;
}
function render(model, focus = false) {
  const list = steps[model.platform];
  for (const name of ["ios", "android"]) $(name).setAttribute("aria-pressed", String(model.platform === name));
  $("progress").textContent = t("phone.mobile.setup.progress", { step: model.step + 1, count: list.length });
  $("step-title").textContent = list[model.step][0]; $("step-content").innerHTML = list[model.step][1];
  $("back").disabled = model.step === 0; $("next").hidden = model.step === list.length - 1;
  for (const link of document.querySelectorAll('[href^="/setup/root."]')) {
    if (!model.payload?.rootAvailable) { link.removeAttribute("href"); link.setAttribute("aria-disabled", "true"); link.textContent = t("phone.mobile.setup.downloadUnavailable"); }
  }
  applyEntry(model);
  if (focus) $("step-title").focus();
}
function showError(message, resume = false) {
  // An expired certificate download access says nothing about the trust
  // already installed on this phone, or about the preview connection.
  $("error").textContent = message;
  $("error").hidden = false;
  $("reload").hidden = false;
  $("resume").hidden = !resume;
  $("resume-note").hidden = !resume;
}
const setup = createPhoneSetup({ api: createPhoneApi({ fetch, setTimeout, clearTimeout }),
  storage: sessionStorage, hostname: location.hostname, userAgent: navigator.userAgent,
  stepCounts: { ios: steps.ios.length, android: steps.android.length },
  onLoading() {
    $("error").hidden = true; $("reload").hidden = true;
    $("resume").hidden = true; $("resume-note").hidden = true;
  },
  onState(state) {
    $("computer").textContent = state.computer;
    $("certificate-name").textContent = state.certificateName;
    $("fingerprint").textContent = state.fingerprint;
    const expiry = typeof state.expiresAt === "number" ? new Date(state.expiresAt * 1000) : new Date(state.expiresAt);
    $("expiry").textContent = t("phone.mobile.setup.expiry", { expiry: Number.isNaN(expiry.valueOf()) ? state.expiresAt : expiry.toLocaleDateString() });
  }, onError: showError, onRender: render,
});
for (const name of ["ios", "android"]) $(name).addEventListener("click", () => setup.choose(name));
$("back").addEventListener("click", setup.back);
$("next").addEventListener("click", setup.next);
$("reload").addEventListener("click", () => setup.load({ restore: false }));
// Returning from the Settings app must refresh the entry without losing the
// step the person is on.
document.addEventListener("visibilitychange", () => { if (!document.hidden) setup.load({ restore: false }); });
window.addEventListener("pageshow", (event) => { if (event.persisted) setup.load({ restore: false }); });
setup.render(); setup.load();
