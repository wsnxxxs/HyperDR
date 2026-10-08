import { t } from "../js/i18n/index.js";
import { decodePreview } from "../js/preview/packet.js";
import { assessPhoneHdr } from "../js/preview/phone-diagnostics.js";
import { createSdrGpuRenderer } from "../js/preview/sdr-gpu.js";
import { renderSdr } from "../js/preview/cpu.js";
import { bindSaveAction } from "../js/run/save.js";

export function mountPhoneView({ state, api }) {
  const { connection, photo, view, diagnostics } = state;
  const request = api.request;
  const $ = (id) => document.getElementById(id);
  const setupCheck = new URLSearchParams(location.search).get("check") || "";
  let canvas = $("photo");
  function notice(message = "") { $("notice").textContent = message; $("notice").hidden = !message; }
  function connectionState(connected) {
    connection.online = connected;
    $("connection").dataset.online = String(connected && Boolean(connection.snapshot?.enabled && connection.snapshot?.desktopConnected));
    $("connection").querySelector("span").textContent = connection.snapshot && !connection.snapshot.enabled ? t("phone.off") : !connected ? t("phone.mobile.reconnecting") : connection.snapshot?.desktopConnected ? t("phone.mobile.connected") : t("phone.mobile.waiting");
    availability();
  }
  function availability() {
    const ready = connection.online && connection.snapshot?.enabled && connection.snapshot.desktopConnected && connection.capabilities?.ready;
    const busy = photo.transfer || connection.snapshot?.upload || connection.snapshot?.pending || connection.snapshot?.current?.busy;
    $("pick-photos").disabled = !ready || Boolean(busy);
    $("pick-label").textContent = connection.snapshot?.current?.file ? t("phone.mobile.changePhoto") : t("stage.select");
    $("import-hint").textContent = connection.snapshot && !connection.snapshot.enabled ? t("phone.mobile.reopenHint")
      : !connection.online ? t("phone.mobile.recoverHint")
      : !connection.snapshot?.desktopConnected ? t("phone.mobile.openHint")
      : !connection.capabilities?.ready ? t("phone.mobile.serviceHint")
      : connection.snapshot?.current?.busy ? t("phone.mobile.processingHint")
      : t("phone.mobile.importHint");
  }
  function syncExports(entries) {
    const key = entries.map((e) => `${e.sessionId}/${e.id}`).join("|");
    if ($("export-list").dataset.key === key) return;
    $("export-list").dataset.key = key;
    $("exports").hidden = !entries.length;
    $("export-count").textContent = t("phone.mobile.exportCount", { count: entries.length });
    $("export-list").replaceChildren(...entries.map((entry) => {
      const card = document.createElement("article"); card.className = "export-card";
      const mark = document.createElement("span"); mark.className = "export-mark"; mark.textContent = "↙";
      const info = document.createElement("div");
      const title = document.createElement("h3"); title.textContent = entry.name;
      const meta = document.createElement("p"); meta.textContent = `${(entry.bytes / 1048576).toFixed(1)} MB · ${new Date(entry.createdAt * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
      const saveState = document.createElement("p");
      saveState.className = "save-state phone-save-state";
      saveState.setAttribute("role", "status");
      saveState.setAttribute("aria-live", "polite");
      saveState.hidden = true;
      const save = document.createElement("button");
      save.type = "button";
      save.className = "phone-save-button";
      bindSaveAction(save, saveState, () => ({
        sessionId: entry.sessionId, exportId: entry.id, name: entry.name,
      }), { downloadKey: "save.button.phone" });
      info.append(title, meta, saveState); card.append(mark, info, save); return card;
    }));
  }
  function applySnapshot(next) {
    connection.snapshot = next;
    $("computer").textContent = next.computer;
    const current = next.current || {};
    const hasPhoto = Boolean(current.file);
    $("welcome").hidden = hasPhoto;
    $("photo-workspace").hidden = !hasPhoto;
    $("workflow").hidden = hasPhoto;
    $("filename").textContent = current.file?.name || "";
    const id = `${current.sessionId || ""}/${current.options?.highlightRecovery || ""}`;
    if (id !== photo.photoId) {
      photo.photoId = id; photo.frame = null; photo.original = null; photo.displayedVersion = 0;
      view.comparing = false; draw();
      canvas.style.visibility = "hidden";
      $("compare").disabled = true;
      resetView();
    }
    $("viewer-state").textContent = next.pending ? t("phone.mobile.handoff")
      : current.status === "exporting" ? t("phone.mobile.exporting")
      : current.status === "error" ? t("phone.mobile.previewFailed")
      : next.frameReady && photo.displayedVersion === next.frameVersion ? t("phone.mobile.synced")
      : t("phone.mobile.updating");
    if (next.upload && !photo.transfer) showTransfer(next.upload.name, next.upload.progress);
    else if (!photo.transfer) $("transfer").hidden = true;
    syncExports(next.completed || []);
    connectionState(true);
    if (!next.frameReady) photo.frameRequest?.abort();
    else if (photo.displayedVersion !== next.frameVersion) loadFrame();
  }
  function newCanvas() {
    const next = document.createElement("canvas"); next.id = "photo";
    next.setAttribute("aria-label", t("phone.mobile.effectPreview"));
    canvas.replaceWith(next); canvas = next;
  }
  const diagnosticMessages = {
    insecure: [t("phone.mobile.diagnostic.insecureTitle"), t("phone.mobile.diagnostic.insecureHelp")],
    webgpu: [t("phone.mobile.diagnostic.webgpuTitle"), t("phone.mobile.diagnostic.webgpuHelp")],
    display: [t("phone.mobile.diagnostic.displayTitle"), t("phone.mobile.diagnostic.displayHelp")],
    renderer: [t("phone.mobile.diagnostic.rendererTitle"), t("phone.mobile.diagnostic.rendererHelp")],
    ready: [t("phone.mobile.diagnostic.readyTitle"), t("phone.mobile.diagnostic.readyHelp")],
  };
  function publishDiagnostics(result) {
    diagnostics.lastDiagnostic = result;
    const [title, description] = diagnosticMessages[result.reason];
    $("diagnostic-title").textContent = title;
    $("diagnostic-description").textContent = description;
    $("diagnostics").dataset.hdr = String(result.hdr);
    $("diagnostic-detail").textContent = t("phone.mobile.diagnostic.summary", {
      secure: result.secureContext ? t("phone.mobile.yes") : t("phone.mobile.no"),
      webgpu: result.webgpu ? t("phone.mobile.available") : t("phone.mobile.unavailable"),
      hdr: result.displayHdr ? t("phone.mobile.yes") : t("phone.mobile.no"),
      detail: result.detail || t("phone.mobile.diagnostic.skipped"),
    });
    request("/api/phone/diagnostics", { ...result, setupCheck }).then(() => {
      $("diagnostic-report").textContent = t("phone.mobile.diagnostic.reported");
    }).catch((error) => { $("diagnostic-report").textContent = t("phone.mobile.diagnostic.reportFailed", { message: error.message }); });
  }
  setInterval(() => {
    if (!document.hidden && connection.online && diagnostics.lastDiagnostic) {
      request("/api/phone/diagnostics", { ...diagnostics.lastDiagnostic, setupCheck }).catch(() => {});
    }
  }, 20000);
  function probeDiagnostics() {
    if (diagnostics.diagnosticRun) return diagnostics.diagnosticRun;
    $("retry-diagnostics").disabled = true;
    diagnostics.diagnosticRun = (async () => {
      try {
        const probe = document.createElement("canvas"); probe.width = 2; probe.height = 2;
        const { result, renderer: testRenderer } = await assessPhoneHdr(probe);
        testRenderer?.destroy(); publishDiagnostics(result);
      } catch (error) {
        // A capability check that fails must still leave the page usable.
        publishDiagnostics({ secureContext: Boolean(window.isSecureContext), webgpu: Boolean(navigator.gpu),
          displayHdr: false, hdr: false, reason: "renderer", detail: String(error.message || error) });
      }
    })().finally(() => { diagnostics.diagnosticRun = null; $("retry-diagnostics").disabled = false; });
    return diagnostics.diagnosticRun;
  }
  async function refreshDiagnostics() {
    await probeDiagnostics();
    if (!view.renderer) return;
    if (photo.rendering) { view.rendererRefreshPending = true; return; }
    view.rendererRefreshPending = false;
    rendererLost();
  }
  $("retry-diagnostics").addEventListener("click", refreshDiagnostics);
  try { matchMedia("(dynamic-range: high)").addEventListener("change", refreshDiagnostics); } catch {}
  async function initRenderer() {
    if (view.renderer) return;
    if (diagnostics.diagnosticRun) await diagnostics.diagnosticRun;
    let candidate = null;
    try {
      const assessment = await assessPhoneHdr(canvas, () => { if (candidate && view.renderer === candidate) rendererLost(); });
      candidate = assessment.renderer;
      publishDiagnostics(assessment.result);
    } catch (error) {
      publishDiagnostics({ secureContext: Boolean(window.isSecureContext), webgpu: Boolean(navigator.gpu),
        displayHdr: false, hdr: false, reason: "renderer", detail: String(error.message || error) });
    }
    view.renderer = candidate;
    if (!view.renderer) newCanvas();
    if (!view.renderer) {
      try { view.renderer = createSdrGpuRenderer(canvas, () => rendererLost()); }
      catch { newCanvas(); view.renderer = { kind: "cpu", upload() {}, destroy() {}, draw(_unused, params) { renderSdr(canvas, { frame: photo.frame, original: params.original }); } }; }
    }
    const hdr = view.renderer.kind === "hdr";
    $("render-badge").textContent = hdr ? t("phone.mobile.trueHdr") : t("phone.mobile.sdr");
    $("render-badge").dataset.hdr = String(hdr);
    $("preview-note").textContent = hdr ? t("phone.mobile.previewNote")
      : !window.isSecureContext ? t("phone.mobile.insecurePreviewNote")
      : t("phone.mobile.sdrPreviewNote");
  }
  function rendererLost() {
    const previous = view.renderer; view.renderer = null;
    previous?.destroy(); newCanvas(); photo.displayedVersion = 0;
    if (connection.snapshot?.frameReady) loadFrame();
  }
  async function loadFrame() {
    if (photo.rendering || !connection.snapshot?.frameReady || !connection.online) return;
    const id = photo.photoId, version = connection.snapshot.frameVersion;
    photo.rendering = true; photo.frameRequest = new AbortController();
    let retry = false;
    try {
      const response = await api.frame(photo.frameRequest.signal);
      if (!response.ok) { if (response.status === 409) return; throw new Error(t("phone.mobile.frameFailed")); }
      const data = await response.arrayBuffer();
      if (id !== photo.photoId || !connection.snapshot.frameReady || version !== connection.snapshot.frameVersion || Number(response.headers.get("X-Frame-Version")) !== version) { retry = true; return; }
      const next = decodePreview(data);
      if (!photo.original) {
        const source = await api.original(photo.frameRequest.signal);
        if (!source.ok) throw new Error(t("phone.mobile.originalPending"));
        const originalData = decodePreview(await source.arrayBuffer());
        if (id !== photo.photoId) { retry = true; return; }
        photo.original = originalData;
        $("original-photo").width = photo.original.width; $("original-photo").height = photo.original.height;
        renderSdr($("original-photo"), { frame: photo.original, original: true });
      }
      await initRenderer();
      if (id !== photo.photoId || version !== connection.snapshot.frameVersion) { retry = true; return; }
      photo.frame = next;
      canvas.width = photo.frame.width; canvas.height = photo.frame.height;
      view.renderer.upload(photo.frame); draw(); canvas.style.visibility = "visible";
      photo.displayedVersion = version;
      $("compare").disabled = false;
      $("viewer-state").textContent = connection.snapshot.current.status === "exporting" ? t("phone.mobile.exporting") : t("phone.mobile.synced");
      transform();
    } catch (error) {
      if (error.name !== "AbortError") $("viewer-state").textContent = error.message;
    } finally {
      photo.rendering = false; photo.frameRequest = null;
      if (view.rendererRefreshPending) { view.rendererRefreshPending = false; rendererLost(); }
      else if (retry && connection.snapshot?.frameReady) loadFrame();
    }
  }
  function draw() {
    canvas.hidden = view.comparing;
    $("original-photo").hidden = !view.comparing;
    if (photo.frame && !view.comparing) view.renderer?.draw(null, { original: false });
  }
  function transform() {
    const box = $("canvas-wrap").getBoundingClientRect();
    view.panX = Math.max(-box.width * (view.zoom - 1) / 2, Math.min(box.width * (view.zoom - 1) / 2, view.panX));
    view.panY = Math.max(-box.height * (view.zoom - 1) / 2, Math.min(box.height * (view.zoom - 1) / 2, view.panY));
    canvas.style.transform = `translate(${view.panX}px, ${view.panY}px) scale(${view.zoom})`;
    $("original-photo").style.transform = canvas.style.transform;
  }
  function resetView() { view.zoom = 1; view.panX = view.panY = 0; transform(); }
  $("compare").addEventListener("pointerdown", (event) => {
    event.preventDefault(); $("compare").setPointerCapture(event.pointerId); view.comparing = true; draw();
  });
  const endCompare = () => { view.comparing = false; draw(); };
  for (const event of ["pointerup", "pointercancel", "lostpointercapture", "blur"]) $("compare").addEventListener(event, endCompare);
  $("compare").addEventListener("contextmenu", (event) => event.preventDefault());
  $("compare").addEventListener("keydown", (event) => { if ([" ", "Enter"].includes(event.key)) { event.preventDefault(); view.comparing = true; draw(); } });
  $("compare").addEventListener("keyup", endCompare);
  $("fullscreen").addEventListener("click", () => {
    const expanded = document.body.classList.toggle("fullscreen");
    $("fullscreen").setAttribute("aria-label", expanded ? t("phone.mobile.exitFullscreen") : t("phone.mobile.fullscreen"));
    $("fullscreen").setAttribute("aria-pressed", String(expanded)); resetView();
  });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") { document.body.classList.remove("fullscreen"); resetView(); } });
  const surface = $("canvas-wrap");
  surface.addEventListener("pointerdown", (event) => {
    if (!photo.frame) return;
    surface.setPointerCapture(event.pointerId); view.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    view.gesture = { points: [...view.pointers.values()], zoom: view.zoom, panX: view.panX, panY: view.panY };
  });
  surface.addEventListener("pointermove", (event) => {
    if (!view.pointers.has(event.pointerId) || !view.gesture) return;
    view.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    const points = [...view.pointers.values()];
    if (points.length === 2 && view.gesture.points.length === 2) {
      const distance = (p) => Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
      view.zoom = Math.max(1, Math.min(4, view.gesture.zoom * distance(points) / Math.max(1, distance(view.gesture.points))));
    } else if (points.length === 1 && view.gesture.points.length === 1) {
      view.panX = view.gesture.panX + points[0].x - view.gesture.points[0].x;
      view.panY = view.gesture.panY + points[0].y - view.gesture.points[0].y;
    }
    transform();
  });
  for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) surface.addEventListener(event, (e) => {
    view.pointers.delete(e.pointerId); view.gesture = { points: [...view.pointers.values()], zoom: view.zoom, panX: view.panX, panY: view.panY };
  });
  surface.addEventListener("dblclick", () => { view.zoom = view.zoom === 1 ? 2 : 1; view.panX = view.panY = 0; transform(); });
  window.addEventListener("resize", transform);

  function showTransfer(name, progress, cancellable = true) {
    $("transfer").hidden = false; $("transfer-name").textContent = name;
    $("transfer-title").textContent = progress >= 1 ? t("phone.mobile.preparingPhoto") : t("phone.mobile.transferring");
    $("upload-progress").value = progress; $("upload-percent").textContent = `${Math.round(progress * 100)}%`;
    $("cancel-upload").hidden = !cancellable;
  }
  async function upload(file) {
    if (!file || photo.transfer) return;
    const extension = "." + file.name.split(".").pop().toLowerCase();
    if (!connection.capabilities.inputExtensions.includes(extension)) { notice(t("phone.mobile.unsupported")); return; }
    if (!file.size || file.size > connection.capabilities.maxUploadMB * 1048576) { notice(t("phone.mobile.sizeLimit", { size: connection.capabilities.maxUploadMB })); return; }
    const task = { cancelled: false, sid: null, xhr: null, progress: Promise.resolve() };
    photo.transfer = task; notice(); showTransfer(file.name, 0); availability();
    try {
      const result = await request("/api/phone/import", { name: file.name }); task.sid = result.sessionId;
      if (task.cancelled) return;
      let lastProgress = 0;
    const transfer = api.upload(task.sid, file, (progress) => {
      showTransfer(file.name, progress);
      if (Date.now() - lastProgress > 500) {
        lastProgress = Date.now();
        task.progress = task.progress.then(() => request("/api/phone/upload", { sessionId: task.sid, progress })).catch(() => {});
      }
    });
    task.xhr = transfer;
    await transfer.promise;
    await task.progress;
      if (!task.cancelled) applySnapshot(await request("/api/phone/upload", { sessionId: task.sid, complete: true }));
    } catch (error) { if (!task.cancelled) notice(error.message); task.cancelled = true; }
    finally {
      await task.progress;
      if (task.cancelled && task.sid) await request("/api/phone/upload", { sessionId: task.sid, cancel: true }).catch(() => {});
      photo.transfer = null; $("transfer").hidden = true; availability();
    }
  }
  $("cancel-upload").addEventListener("click", async () => {
    if (photo.transfer) { photo.transfer.cancelled = true; photo.transfer.xhr?.abort(); }
    else if (connection.snapshot?.upload) {
      try { applySnapshot(await request("/api/phone/upload", { sessionId: connection.snapshot.upload.sessionId, cancel: true })); }
      catch (error) { notice(error.message); }
    }
  });
  $("pick-photos").addEventListener("click", () => $("photos-input").click());
  $("photos-input").addEventListener("change", (event) => { upload(event.target.files[0]); event.target.value = ""; });

  return { applySnapshot, connectionState, notice, probeDiagnostics,
    pause() { endCompare(); photo.frameRequest?.abort(); },
    capabilities(next) { $("photos-input").accept = ["image/*", ...next.inputExtensions].join(","); },
    retry(visible) { $("retry-connection").hidden = !visible; } };
}
