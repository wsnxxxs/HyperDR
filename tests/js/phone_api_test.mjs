import assert from "node:assert/strict";
import { createPhoneApi } from "../../apps/panel/web/js/core/api.js";
import { createPhoneSetup } from "../../apps/panel/web/phone/setup-controller.js";

const response = (body, status = 200) => ({ ok: status < 400, status, json: async () => body });
const flush = () => new Promise(setImmediate);
function clock() {
  const pending = new Map(); let id = 0;
  return { pending, setTimeout(fn) { pending.set(++id, fn); return id; },
    clearTimeout(key) { pending.delete(key); },
    fire() { const [key, fn] = pending.entries().next().value; pending.delete(key); fn(); } };
}

// The shared upload transport must retain the phone's progress/cancel contract.
{
  let xhr, progress;
  class Request {
    upload = {};
    status = 200;
    responseText = "invalid success JSON";
    constructor() { xhr = this; }
    open(method, path) { assert.equal(method, "POST"); assert.equal(path, "/api/upload?id=photo&name=a.jpg"); }
    setRequestHeader(key, value) { assert.equal(key, "Content-Type"); assert.equal(value, "application/octet-stream"); }
    send(file) { assert.equal(file.name, "a.jpg"); }
    abort() { this.onabort(); }
  }
  const api = createPhoneApi({ XMLHttpRequest: Request });
  const task = api.upload("photo", { name: "a.jpg" }, (value) => { progress = value; });
  xhr.upload.onprogress({ lengthComputable: true, loaded: 4, total: 10 });
  assert.equal(progress, 0.4);
  xhr.onload(); assert.equal(await task.promise, undefined);
  const cancelled = api.upload("photo", { name: "a.jpg" });
  const rejection = assert.rejects(cancelled.promise, (e) => e.message === "已取消上传");
  cancelled.abort(); await rejection;
}

// Mobile JSON semantics stay distinct from desktop unwrap, including raw
// network/parse errors, status-bearing HTTP errors and unchanged POST bodies.
{
  let next = response({ error: "successful payload" }), call;
  const api = createPhoneApi({ fetch: async (path, options) => { call = { path, options }; return next; } });
  assert.deepEqual(await api.request("/api/phone/import", { name: "a.jpg" }), { error: "successful payload" });
  assert.deepEqual(call, { path: "/api/phone/import", options: {
    method: "POST", headers: { "Content-Type": "application/json" }, body: '{"name":"a.jpg"}',
  } });
  next = response({}, 409);
  await assert.rejects(api.request("/api/phone/state"), (e) => e.status === 409 && e.message === "请求未完成，请重试。");
  next = response({ error: "server message" }, 403);
  await assert.rejects(api.request("/api/phone/state"), (e) => e.status === 403 && e.message === "server message");
  const error = new SyntaxError("invalid JSON");
  next = { ok: true, json: async () => { throw error; } };
  await assert.rejects(api.request("/api/phone/state"), (e) => e === error);
}
// A timed-out body and a caller cancellation have different error contracts.
{
  const timer = clock();
  const fetch = async (_path, { signal }) => ({ ok: true, json: () => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(Object.assign(new Error("cancelled"), { name: "AbortError" })));
  }) });
  const api = createPhoneApi({ fetch, ...timer });
  const deadline = assert.rejects(api.request("/api/state", undefined, { timeout: 8000 }),
    (e) => e.status === 0 && e.timeout === true && e.message === "请求超时，请重试。");
  await flush(); timer.fire(); await deadline;
  const control = new AbortController();
  const cancelled = assert.rejects(api.request("/api/state", undefined, { timeout: 8000, signal: control.signal }),
    (e) => e.name === "AbortError" && !e.timeout);
  await flush(); control.abort(); await cancelled;
  assert.equal(timer.pending.size, 0);
}
// The setup page keeps successful same-host HTTPS entries in memory, and only
// platform/step in storage, when certificate download access later expires.
{
  const timer = clock(), storage = new Map();
  const payload = { fingerprint: "certificate", rootAvailable: true, httpsUrl: "https://computer:8757/phone?token=entry" };
  let next = response(payload), options, error, resume;
  const api = createPhoneApi({ ...timer, fetch: async (path, init) => {
    assert.equal(path, "/setup/state"); options = init; return next;
  } });
  storage.set("hyperdr-setup:certificate", JSON.stringify({ platform: "android", step: 1 }));
  const setup = createPhoneSetup({ api, storage: { getItem: (k) => storage.get(k), setItem: (k,v) => storage.set(k,v) },
    hostname: "computer", userAgent: "iPhone", stepCounts: { ios: 4, android: 3 },
    onLoading() {}, onState() {}, onRender() {}, onError: (message, canResume) => { error = message; resume = canResume; },
  });
  await setup.load();
  assert.equal(options.cache, "no-store");
  assert.equal(setup.state.platform, "android"); assert.equal(setup.state.step, 1);
  assert.equal(setup.state.entry, payload.httpsUrl);
  setup.next(); assert.equal(setup.state.step, 2);
  await setup.load({ restore: false }); assert.equal(setup.state.step, 2);
  next = response({}, 410); await setup.load({ restore: false });
  assert.equal(resume, true); assert.equal(setup.state.entry, payload.httpsUrl);
  assert.equal(error, "设置入口已过期。手机上已安装的证书仍然有效；重新下载证书需要在电脑上重新开启设置入口。");
  next = response({ ...payload, httpsUrl: "https://other/phone" }); await setup.load({ restore: false });
  assert.equal(setup.state.entry, payload.httpsUrl);
  assert.deepEqual(JSON.parse(storage.get("hyperdr-setup:certificate")), { platform: "android", step: 2 });
  assert.equal(timer.pending.size, 0);
}
console.log("Phone API: JSON/error contracts, deadlines, cancellation and setup recovery pass");
