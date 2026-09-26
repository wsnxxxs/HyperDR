import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const read = (path) => fs.readFileSync(new URL(`../../apps/panel/web/${path}`, import.meta.url), "utf8");
const desktop = read("js/ui/phone-workbench.js").replace(/^import .*;\r?\n/gm, "").replace(/^export /gm, "");
const phone = read("phone/app.js");
const flush = () => new Promise(setImmediate);
const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };
const response = (data, status = 200) => ({ ok: status < 400, status, json: async () => data });
function timers() {
  const pending = new Map(); let id = 0;
  return { pending, setTimeout: (fn) => { pending.set(++id, fn); return id; }, clearTimeout: (key) => pending.delete(key),
    fire() { const [key, fn] = pending.entries().next().value; pending.delete(key); fn(); } };
}
function node() {
  return { dataset: {}, options: [], value: "", handlers: {}, attributes: {},
    addEventListener(name, fn) { this.handlers[name] = fn; }, setAttribute(key, value) { this.attributes[key] = value; }, focus() {}, append() {},
    showModal() { this.open = true; }, close() { this.open = false; this.handlers.close?.(); },
    querySelector() { return node(); }, replaceChildren(...children) { this.options = children; } };
}
function desktopPage(fetch, publishResponse) {
  const clock = timers(), nodes = [], storage = new Map(), state = { file: {} };
  let published = 0, reloaded = 0;
  const next = { enabled: true, urls: [], setupUrls: [], tls: {} };
  const ctx = vm.createContext({ ...clock, AbortController, URL, crypto: { randomUUID: () => "desktop" },
    document: { getElementById: node, body: node() }, t: (key) => key, onLocaleChange() {}, setInterval() {},
    el: (tag, attributes = {}) => { const item = Object.assign(node(), { tag, className: attributes.class }); nodes.push(item); return item; }, debounce: (fn) => fn,
    store: { get: () => state, set: (value) => Object.assign(state, value), subscribe() {} }, toOptions: () => ({}),
    sessionStorage: { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: (key) => storage.delete(key) },
    fetch: (url, options) => {
      if (url.endsWith("/publish")) { published++; return publishResponse ? publishResponse(next) : Promise.resolve(response(next)); }
      return fetch(url, options, next);
    }, stage: { reload: async () => { reloaded++; } }, toast() {},
  });
  vm.runInContext(desktop + "\nvar page = mountPhoneWorkbench({stage, toast});", ctx);
  return { ctx, clock, storage, nodes, state, published: () => published, reloaded: () => reloaded };
}
const stalledBody = (_url, { signal }) => Promise.resolve({ ok: true, json: () => new Promise((_resolve, reject) => {
  signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })), { once: true });
}) });

// Headers arrive, but the body never completes. The deadline must still abort it.
{
  const page = desktopPage(stalledBody);
  const pending = vm.runInContext('phoneRequest("connection")', page.ctx);
  const rejected = assert.rejects(pending, (error) => error.code === "timeout");
  await flush(); assert.equal(page.clock.pending.size, 1);
  page.clock.fire(); await rejected;
  assert.equal(page.clock.pending.size, 0);
}
// The server completes connect/disconnect despite losing the response.
{
  let stopped = false;
  const page = desktopPage((url, options, next) => {
    if (url.endsWith("/connect") || url.endsWith("/disconnect")) {
      if (url.endsWith("/disconnect")) stopped = true;
      return stalledBody(url, options);
    }
    return Promise.resolve(stopped ? response({ error: "closed", code: "workbench_owner" }, 409) : response(next));
  });
  const connecting = page.ctx.page.connect();
  await flush(); page.clock.fire(); await connecting;
  assert.equal(page.storage.get("hyperdr.phone.active"), "1");
  assert.equal(page.published(), 1); assert.equal(page.reloaded(), 1);
  const stop = page.nodes.find((item) => item.textContent === "phone.disconnect");
  page.state.phoneUploading = true;
  const stopping = stop.handlers.click();
  await flush(); page.clock.fire(); await stopping;
  assert.equal(page.storage.has("hyperdr.phone.active"), false);
  assert.equal(page.state.phoneUploading, false); assert.equal(stop.hidden, true);
}
// A publish that was already in flight cannot restore state after disconnect.
{
  const late = deferred(); let delay = false;
  const page = desktopPage((_url, _options, next) => Promise.resolve(response(next)),
    (next) => delay ? late.promise : Promise.resolve(response(next)));
  await page.ctx.page.connect(); delay = true;
  const publishing = page.ctx.page.connect(); await flush();
  const stop = page.nodes.find((item) => item.textContent === "phone.disconnect");
  await stop.handlers.click();
  late.resolve(response({ enabled: true, upload: { progress: 0.5 } })); await publishing;
  assert.equal(page.storage.has("hyperdr.phone.active"), false);
  assert.notEqual(page.state.phoneUploading, true); assert.equal(stop.hidden, true);
}

// Wizard progress follows the server; closing the dialog must keep the session.
{
  let snapshot = { phoneConnected: false };
  const page = desktopPage((_url, _options, next) => Promise.resolve(response(next)),
    () => Promise.resolve(response(snapshot)));
  await page.ctx.page.connect();
  const steps = page.nodes.filter((item) => item.tag === "li");
  const currentStep = () => steps.findIndex((item) => item.attributes["aria-current"] === "step");
  assert.equal(currentStep(), 0);
  snapshot = { phoneConnected: true };
  await page.ctx.page.connect(); assert.equal(currentStep(), 1);
  snapshot.current = { sessionId: "photo", file: { name: "landscape.png" } };
  await page.ctx.page.connect(); assert.equal(currentStep(), 2);
  snapshot.upload = { name: "next.png", progress: 0.4 };
  await page.ctx.page.connect(); assert.equal(currentStep(), 1);
  snapshot = { phoneConnected: false };
  await page.ctx.page.connect(); assert.equal(currentStep(), 0);
  assert.ok(page.nodes.some((item) => item.textContent === "phone.reconnecting"));
  page.ctx.page.open(); page.ctx.page.close(); await flush();
  assert.equal(page.ctx.page.node.open, false);
  assert.equal(page.storage.get("hyperdr.phone.active"), "1");
}

function phonePage(fetch) {
  const clock = timers(), nodes = new Map(), streams = [], handlers = {}, windowHandlers = {};
  class EventSource {
    static CLOSED = 2;
    readyState = 0;
    constructor() { streams.push(this); }
    close() { this.readyState = 2; }
  }
  const document = { hidden: false, addEventListener: (name, fn) => { handlers[name] = fn; } };
  const ctx = vm.createContext({ ...clock, fetch, AbortController, EventSource, document,
    window: { addEventListener: (name, fn) => { windowHandlers[name] = fn; } },
    $: (id) => { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); },
    capabilities: null, snapshot: null, frameRequest: null, endCompare() {}, probeDiagnostics() {},
    notice() {}, connectionState() {}, applySnapshot: (next) => { ctx.snapshot = next; },
  });
  // Execute the real request helper and complete initialization/lifecycle block.
  vm.runInContext(phone.slice(phone.indexOf("async function request("), phone.indexOf("function notice("))
    + phone.slice(phone.indexOf("let events = null;")), ctx);
  return { ctx, clock, streams, nodes, windowHandlers,
    hide() { document.hidden = true; handlers.visibilitychange(); },
    show() { document.hidden = false; handlers.visibilitychange(); } };
}
// Mobile state requests also keep the deadline active until JSON is complete.
{
  const page = phonePage(stalledBody);
  await flush(); page.clock.fire(); await flush();
  page.clock.fire(); await flush();
  assert.equal(page.streams.length, 0); assert.equal(page.clock.pending.size, 1);
  page.hide(); assert.equal(page.clock.pending.size, 0);
}
// An old body may finish after pause/resume; it must not overwrite the new run.
{
  const old = deferred(), fresh = deferred(); let reads = 0, oldSignal;
  const page = phonePage(async (url, { signal }) => {
    if (url === "/api/state") { reads++; if (reads === 1) oldSignal = signal;
      return { ok: true, json: () => reads === 1 ? old.promise : fresh.promise }; }
    return response({ enabled: true });
  });
  await flush(); page.hide(); assert.equal(oldSignal.aborted, true); page.show(); await flush();
  old.resolve({ inputExtensions: ["old"] }); await flush();
  vm.runInContext("initialize()", page.ctx); assert.equal(reads, 2);
  assert.equal(page.streams.length, 0); assert.equal(page.ctx.capabilities, null);
  fresh.resolve({ inputExtensions: ["fresh"] }); await flush();
  assert.equal(page.ctx.capabilities.inputExtensions[0], "fresh"); assert.equal(page.streams.length, 1);
  page.windowHandlers.pagehide(); assert.equal(page.streams[0].readyState, 2);
  page.windowHandlers.pageshow({ persisted: true }); await flush(); assert.equal(page.streams.length, 2);
  page.hide(); assert.equal(page.clock.pending.size, 0);
}
// Retry pauses in the background; a terminal SSE error rechecks authorization.
{
  let failing = true, expired = false;
  const page = phonePage(async (url) => {
    if (failing) throw new TypeError("offline");
    return expired ? response({ error: "expired" }, 403)
      : response(url === "/api/state" ? { inputExtensions: [] } : { enabled: true });
  });
  await flush(); assert.equal(page.clock.pending.size, 1);
  page.hide(); assert.equal(page.clock.pending.size, 0);
  failing = false; page.show(); await flush(); assert.equal(page.streams.length, 1);
  expired = true; page.streams[0].close(); page.streams[0].onerror();
  page.clock.fire(); await flush();
  assert.equal(page.clock.pending.size, 0); assert.equal(page.nodes.get("retry-connection").hidden, false);
  page.hide(); page.show(); await flush(); assert.equal(page.streams.length, 1);
}
console.log("Phone recovery: body deadlines, desktop reconciliation, page lifecycle and retry pass");
