/* Starting a conversion, following it, and handing back the result.
 *
 * The result used to be a text link in the settings column and a toast -- the
 * one moment the whole panel exists for, spent on a hyperlink. It is now a
 * card in the dock: the file's name and dimensions, the peak the renderer
 * actually reached (the report's `rendered_peak`, the number the preview
 * admits it cannot compute), the verification the converter ran on its own
 * output, and the two ways the file can leave the machine.
 *
 * The poll loop is a single awaited function with an explicit exit rather than
 * a `setInterval` whose handle had to be cleared from four branches.
 */

import { api, ApiError } from "../core/api.js";
import { store } from "../core/store.js";
import { role, setText, debounce } from "../core/dom.js";
import { toOptions, OPTION_KEYS } from "../settings/schema.js";

const POLL_INTERVAL_MS = 400;
const TRACKING_INTERRUPTED_MS = 15_000;
const desktopLayout = window.matchMedia("(min-width: 641px)");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function mountRunner({ toast }) {
  const runButton = role("run");
  const cancelButton = role("cancel");
  const download = role("download");
  const exportButton = role("export");
  const resultCard = role("result");
  const phases = {
    upload: role("phase-upload"),
    convert: role("phase-convert"),
    deliver: role("phase-deliver"),
  };
  const commandLine = role("command-line");

  let activeJobId = "";
  let starting = false;
  let trackingInterrupted = false;
  let commandSeq = 0;

  /* ── phases ───────────────────────────────────────────────────────── */

  function syncPhases(state) {
    phases.upload.dataset.state = state.uploading ? "active" : state.file ? "done" : "";
    phases.convert.dataset.state = state.jobId ? "active" : state.result ? "done" : "";
    phases.deliver.dataset.state = state.result?.delivered ? "done" : state.result ? "active" : "";
  }

  /* ── result card ──────────────────────────────────────────────────── */

  function peakClause(peakLinear) {
    if (!Number.isFinite(peakLinear) || peakLinear <= 1) return "";
    const stops = Math.log2(peakLinear);
    return `实测峰值 ×${peakLinear.toFixed(2)}（+${stops.toFixed(1)} stops）`;
  }

  function syncResult(state) {
    const result = state.result;
    resultCard.hidden = !result;
    if (!result) return;
    setText(role("result-name"), result.name);
    const meta = [
      result.width && result.height ? `${result.width}×${result.height}` : "",
      peakClause(result.peakLinear),
      result.verified ? "已通过自检" : "",
      Number.isFinite(result.durationS) ? `用时 ${result.durationS.toFixed(1)} s` : "",
    ].filter(Boolean).join(" · ");
    setText(role("result-meta"), meta);
    const warn = role("result-warn");
    warn.hidden = !result.degradedNote;
    setText(warn, result.degradedNote || "");
    if (download.href !== result.downloadUrl) download.href = result.downloadUrl;
    exportButton.hidden = !(state.capabilities?.nativeOutputPicker && desktopLayout.matches);
  }

  /* Touching any setting after a run makes the card's file describe settings
   * it was not converted with -- say so instead of letting it pass as current. */
  function syncStale(state) {
    const result = state.result;
    role("result-stale").hidden = !result
      || JSON.stringify(toOptions(state)) === result.optionsKey;
  }

  /* ── command line ─────────────────────────────────────────────────── */

  const refreshCommand = debounce(async () => {
    const details = commandLine.closest("details");
    if (!details.open) return;
    const seq = ++commandSeq;
    try {
      const body = await api.command(toOptions(store.get()));
      if (seq === commandSeq) setText(commandLine, body.command || "");
    } catch (_) {
      if (seq === commandSeq) setText(commandLine, "当前无法生成命令行。");
    }
  }, 300);
  commandLine.closest("details").addEventListener("toggle", refreshCommand);

  /* ── availability ─────────────────────────────────────────────────── */

  function syncRunAvailability(state) {
    runButton.disabled =
      starting || Boolean(state.jobId) || !state.capabilities?.ready || !state.file;
  }

  /* ── the run itself ───────────────────────────────────────────────── */

  function setTrackingInterrupted(jobId, interrupted) {
    if (activeJobId !== jobId || trackingInterrupted === interrupted) return;
    trackingInterrupted = interrupted;
    setText(runButton, interrupted ? "连接中断，正在重试…" : "转换中…");
    setText(cancelButton, interrupted ? "放弃跟踪" : "取消");
    cancelButton.disabled = false;
  }

  /** Resolves with the finished job record, or `{abandoned}` if superseded. */
  async function followJob(jobId) {
    let offset = 0;
    let log = "";
    let transientFailures = 0;
    let disconnectedAt = 0;
    for (;;) {
      await sleep(POLL_INTERVAL_MS * Math.min(1 + transientFailures, 5));
      if (activeJobId !== jobId) return { abandoned: true };
      let update;
      try {
        update = await api.log(jobId, offset);
        if (activeJobId !== jobId) return { abandoned: true };
        transientFailures = 0;
        disconnectedAt = 0;
        setTrackingInterrupted(jobId, false);
      } catch (error) {
        if (error instanceof ApiError && [401, 403, 404].includes(error.status)) throw error;
        if (!disconnectedAt) disconnectedAt = performance.now();
        if (performance.now() - disconnectedAt >= TRACKING_INTERRUPTED_MS) {
          setTrackingInterrupted(jobId, true);
        }
        transientFailures++;
        continue;
      }
      if (update.offset != null) offset = update.offset;
      if (typeof update.text === "string") log += update.text;
      if (update.done) return { ...update, log };
    }
  }

  // The last non-empty line, which is where the converter puts the reason a run
  // failed. Truncated because this goes into a toast, not a log viewer.
  function lastLine(log, limit = 200) {
    const lines = (log || "").split("\n").map((line) => line.trim()).filter(Boolean);
    if (!lines.length) return "";
    const line = lines[lines.length - 1];
    return line.length > limit ? line.slice(0, limit - 1) + "…" : line;
  }

  const basename = (path) => String(path || "").split(/[\\/]/).filter(Boolean).pop() || "输出文件";

  // Report schema 6. Only the single success file is read; the reasons are
  // joined for display and never inspected, so a new reason needs no change here.
  function summarizeReport(report) {
    const files = report && Array.isArray(report.files) ? report.files : [];
    const file = files.find((entry) => entry && entry.success);
    if (!file) return {};
    let degradedNote = "";
    if (file.decode_degraded) {
      const reasons = Array.isArray(file.decode_degradation_reasons)
        ? file.decode_degradation_reasons.join("、")
        : "";
      const actual = `${file.decoded_width}×${file.decoded_height}`;
      const target = `${file.target_width}×${file.target_height}`;
      degradedNote = file.target_dimensions_applied === false
        ? `解码被降级：已忽略记录的 ${target} 裁切，实际输出 ${actual}${reasons ? `（${reasons}）` : ""}`
        : `解码被降级：实际输出 ${actual}，而非 ${target}${reasons ? `（${reasons}）` : ""}`;
    }
    return {
      name: basename(file.output),
      width: file.width,
      height: file.height,
      peakLinear: file.render?.rendered_peak,
      verified: Boolean(file.self_verified),
      durationS: (Number(file.decode_ms) + Number(file.process_ms) + Number(file.encode_ms)) / 1000,
      degradedNote,
    };
  }

  function resetRunningUi(jobId) {
    if (activeJobId !== jobId) return;
    activeJobId = "";
    trackingInterrupted = false;
    store.set({ jobId: null });
    setText(runButton, "开始转换");
    setText(cancelButton, "取消");
    cancelButton.hidden = true;
    cancelButton.disabled = false;
  }

  async function start() {
    const state = store.get();
    if (!state.capabilities?.ready) { toast("转换程序尚未就绪。", true); return; }
    if (!state.file) { toast("请先选择图片。", true); return; }

    const optionsKey = JSON.stringify(toOptions(state));
    let started;
    starting = true;
    syncRunAvailability(store.get());
    try {
      started = await api.run(state.sessionId, toOptions(state));
    } catch (error) {
      toast(error.message, true);
      return;
    } finally {
      starting = false;
      syncRunAvailability(store.get());
    }

    activeJobId = started.jobId;
    trackingInterrupted = false;
    store.set({ jobId: started.jobId, result: null });
    setText(runButton, "转换中…");
    cancelButton.hidden = false;
    cancelButton.disabled = false;

    try {
      const outcome = await followJob(started.jobId);
      if (outcome.abandoned) return;

      if (outcome.cancelled) {
        toast("已取消转换");
      } else if (outcome.timedOut) {
        toast("转换超时已终止", true);
      } else if (outcome.rc !== 0) {
        const detail = lastLine(outcome.log);
        toast(detail ? "转换失败：" + detail : "转换失败，请重试或检查服务日志", true);
      } else {
        const summary = summarizeReport(outcome.report);
        // Cache-busted: the same URL serves a different file after the next run.
        const downloadUrl = `${api.resultUrl(state.sessionId, { download: true })}&t=${Date.now()}`;
        const completedResult = {
          name: summary.name || state.file.name,
          width: summary.width,
          height: summary.height,
          peakLinear: summary.peakLinear,
          verified: summary.verified,
          durationS: summary.durationS,
          degradedNote: summary.degradedNote,
          optionsKey,
          downloadUrl,
          delivered: false,
        };
        store.set({ result: completedResult });
        toast(summary.degradedNote
          ? "转换成功，但" + summary.degradedNote
          : "转换成功", Boolean(summary.degradedNote));
        if (activeJobId === started.jobId && store.get().result === completedResult) {
          await deliver(state.sessionId, completedResult);
        }
      }
    } catch (error) {
      toast(error.message || "转换任务状态已丢失。", true);
    } finally {
      resetRunningUi(started.jobId);
    }
  }

  runButton.addEventListener("click", start);

  cancelButton.addEventListener("click", async () => {
    const jobId = activeJobId;
    if (!jobId) return;
    if (trackingInterrupted) {
      resetRunningUi(jobId);
      toast("已放弃跟踪；服务端任务可能仍在运行。", true);
      return;
    }
    cancelButton.disabled = true;
    try { await api.cancel(jobId); }
    catch (error) { toast(error.message, true); cancelButton.disabled = false; }
  });

  /* ── delivery ─────────────────────────────────────────────────────── */

  function markDelivered(expected = store.get().result) {
    const result = store.get().result;
    if (result && result === expected && !result.delivered) {
      store.set({ result: { ...result, delivered: true } });
    }
  }

  /* The desktop flow: a chosen folder means the file lands there on its own,
   * without a click on the card. The phone flow stays the download link. */
  async function deliver(sessionId, expectedResult) {
    const selectionId = store.get().outputSelectionId;
    if (!selectionId) return;
    try {
      const body = await api.export(sessionId, selectionId);
      if (store.get().result !== expectedResult) return;
      toast(`已导出到 ${body.path}`);
      markDelivered(expectedResult);
    } catch (error) {
      if (store.get().result !== expectedResult) return;
      store.set({ outputSelectionId: "", outputDirectory: "" });
      toast("导出到文件夹失败：" + error.message, true);
    }
  }

  download.addEventListener("click", markDelivered);

  exportButton.addEventListener("click", async () => {
    const state = store.get();
    if (!state.result) return;
    exportButton.disabled = true;
    try {
      let selectionId = state.outputSelectionId;
      if (!selectionId) {
        const picked = await api.selectOutput();
        if (picked.cancelled) return;
        store.set({ outputSelectionId: picked.selectionId, outputDirectory: picked.path });
        selectionId = picked.selectionId;
      }
      try {
        const body = await api.export(state.sessionId, selectionId);
        if (store.get().result !== state.result) return;
        toast(`已导出到 ${body.path}`);
        markDelivered(state.result);
      } catch (error) {
        // A stale selection (process restarted, folder deleted) is a 400:
        // drop it so the next click opens the picker again.
        store.set({ outputSelectionId: "", outputDirectory: "" });
        toast("导出失败：" + error.message + "，请重新选择文件夹。", true);
      }
    } catch (error) {
      toast(error.message, true);
    } finally {
      exportButton.disabled = false;
    }
  });

  /* ── wiring ───────────────────────────────────────────────────────── */

  store.watchAny(["uploading", "file", "jobId", "result"], syncPhases, { immediate: true });
  store.watchAny(["result", "capabilities"], syncResult, { immediate: true });
  store.watchAny(["file", "jobId", "capabilities"], syncRunAvailability, { immediate: true });
  store.watchAny(OPTION_KEYS, (state) => {
    syncStale(state);
    commandSeq++;
    refreshCommand();
  });
  desktopLayout.addEventListener?.("change", () => syncResult(store.get()));
}
