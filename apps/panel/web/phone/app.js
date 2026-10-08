import { createPhoneApi } from "../js/core/api.js";
import { createPhoneState } from "./state.js";
import { createPhoneConnection, startDiagnosticHeartbeat } from "./connection.js";
import { mountPhoneView } from "./view.js";
import { applyStatic } from "../js/i18n/index.js";

applyStatic();
const api = createPhoneApi({ fetch, setTimeout, clearTimeout, XMLHttpRequest });
const state = createPhoneState();
const setupCheck = new URLSearchParams(location.search).get("check") || "";
startDiagnosticHeartbeat({ state, request: api.request, setInterval, isHidden: () => document.hidden, setupCheck });
const view = mountPhoneView({ state, api, setupCheck });
const connection = createPhoneConnection({ state: state.connection, request: api.request,
  EventSource, setTimeout, clearTimeout, isHidden: () => document.hidden,
  applySnapshot: view.applySnapshot, connectionState: view.connectionState, notice: view.notice,
  onCapabilities: view.capabilities, onRetry: view.retry, onPause: view.pause });
document.getElementById("retry-connection").addEventListener("click", () => connection.initialize(true));
document.addEventListener("visibilitychange", () => {
  if (document.hidden) connection.pause();
  else { view.probeDiagnostics(); connection.initialize(); }
});
window.addEventListener("pagehide", connection.pause);
window.addEventListener("pageshow", (event) => { if (event.persisted) connection.initialize(); });
view.probeDiagnostics();
connection.initialize();
