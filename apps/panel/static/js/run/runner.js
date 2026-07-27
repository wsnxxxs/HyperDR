/* Starting a conversion, following it, and handing back the result.
 *
 * The poll loop is a single awaited function with an explicit exit rather than
 * a `setInterval` whose handle had to be cleared from four branches -- the old
 * version leaked an interval whenever a run was cancelled while a fetch was
 * already in flight.
 *
 * There are two ways to get the file out, because there have to be: the native
 * folder dialog opens on the machine running the service, so it is useless from
 * a phone. The desktop copies straight into a chosen folder; everything else
 * downloads. Both are offered whenever both are possible.
 */

import { api } from "../core/api.js";
import { role, setText } from "../core/dom.js";
import { toOptions } from "../settings/schema.js";

const POLL_INTERVAL_MS = 400;
const MAX_CONSECUTIVE_POLL_FAILURES = 8;
const desktopLayout = window.matchMedia("(min-width: 641px)");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function mountRunner(store, { toast }) {
  const runButton = role("run");
  const cancelButton = role("cancel");
  const pickButton = role("pick-output");
  const pickLabel = role("pick-output-label");
  const download = role("download");
  const progress = role("run-progress");

  let activeJobId = "";
  let isRunning = false;

  function setProgress(message = "") {
    setText(progress, message);
    progress.hidden = !message;
  }

  function syncRunAvailability() {
    runButton.disabled =
      isRunning || !store.value("ready") || !store.value("file");
  }

  function setRunning(running) {
    isRunning = running;
    syncRunAvailability();
    setText(runButton, running ? "转换中…" : "开始转换");
    cancelButton.hidden = !running;
    cancelButton.disabled = false;
    if (!running) {
      activeJobId = "";
      setProgress();
    }
  }

  /** Resolves with the finished job record, or `{abandoned}` if superseded. */
  // The converter's stderr used to be polled and dropped on the floor, so a
  // warning it printed could not reach the user at all. Accumulate it instead
  // and hand it back with the final status: per-poll toasts would turn an
  // ordinary run into a stack of notifications, so the log is only surfaced
  // when something went wrong.
  async function followJob(jobId) {
    let offset = 0;
    let log = "";
    let pollFailures = 0;
    for (;;) {
      await sleep(POLL_INTERVAL_MS);
      if (activeJobId !== jobId) return { abandoned: true };
      let update;
      try {
        update = await api.log(jobId, offset);
        pollFailures = 0;
      } catch (error) {
        pollFailures++;
        if (pollFailures >= MAX_CONSECUTIVE_POLL_FAILURES) {
          return { pollFailed: true, error, log };
        }
        continue;  // A single dropped poll is not a failed job.
      }
      if (update.offset != null) offset = update.offset;
      if (typeof update.text === "string") {
        log += update.text;
        const line = lastLine(log);
        if (line) setProgress(line);
      }
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

  // Report schema 6. `target_dimensions_applied` is the only field branched on;
  // the reasons are joined for display and never inspected, so a new reason
  // needs no change here. Returns a clause, like deliver(), so the caller emits
  // one toast with a single "转换成功".
  function degradationClause(report) {
    const files = report && Array.isArray(report.files) ? report.files : [];
    const degraded = files.filter((file) => file && file.success && file.decode_degraded);
    if (!degraded.length) return "";
    if (degraded.length > 1) {
      return `但 ${degraded.length} 个文件的解码被降级，详见 report`;
    }
    const file = degraded[0];
    const reasons = Array.isArray(file.decode_degradation_reasons)
      ? file.decode_degradation_reasons.join("、")
      : "";
    const actual = `${file.decoded_width}×${file.decoded_height}`;
    const target = `${file.target_width}×${file.target_height}`;
    const detail = file.target_dimensions_applied === false
      ? `已忽略记录的 ${target} 裁切，实际输出 ${actual}`
      : `实际输出 ${actual}，而非 ${target}`;
    return `但解码被降级：${detail}${reasons ? `（${reasons}）` : ""}`;
  }

  // Returns the outcome clause only, never the "转换成功" prefix: the caller may
  // have a degradation warning to lead with, and both halves claiming the
  // conversion succeeded read as two separate results rather than one.
  async function deliver() {
    const sessionId = store.value("sessionId");
    // Cache-busted: the same URL serves a different file after the next run.
    store.set({ resultUrl: `/api/result?id=${sessionId}&download=1&t=${Date.now()}` });

    const selectionId = store.value("outputSelectionId");
    if (!selectionId) {
      return { clause: "可保存到设备", isError: false };
    }
    try {
      const body = await api.export(sessionId, selectionId);
      return { clause: `已导出到 ${body.path}`, isError: false };
    } catch (error) {
      return {
        clause: "导出到文件夹失败：" + error.message,
        isError: true,
      };
    }
  }

  async function start() {
    if (!store.value("ready")) { toast("转换程序尚未就绪。", true); return; }
    if (!store.value("file")) { toast("请先选择图片。", true); return; }

    setRunning(true);
    setProgress("正在启动转换…");
    store.set({ resultUrl: "" });

    let started;
    try {
      started = await api.run(store.value("sessionId"), toOptions(store.get()), false);
    } catch (error) {
      toast(error.message, true);
      setRunning(false);
      return;
    }

    activeJobId = started.jobId;
    setProgress("转换已启动，等待处理日志…");

    const result = await followJob(started.jobId);
    if (result.abandoned) return;

    if (result.pollFailed) {
      toast("无法继续读取转换进度：" + result.error.message, true);
    } else if (result.cancelled) {
      toast("已取消转换");
    } else if (result.timedOut) {
      toast("转换超时已终止", true);
    } else if (result.rc !== 0) {
      const detail = lastLine(result.log);
      toast(detail ? "转换失败：" + detail : "转换失败，请重试或检查服务日志", true);
    } else {
      const warning = degradationClause(result.report);
      const delivery = await deliver();
      const clauses = [warning, delivery.clause].filter(Boolean);
      toast("转换成功，" + clauses.join("；"),
            Boolean(warning) || delivery.isError);
    }

    setRunning(false);
  }

  runButton.addEventListener("click", start);

  cancelButton.addEventListener("click", async () => {
    if (!activeJobId) return;
    cancelButton.disabled = true;
    try { await api.cancel(activeJobId); }
    catch (error) { toast(error.message, true); cancelButton.disabled = false; }
  });

  pickButton.addEventListener("click", async () => {
    const previous = pickLabel.textContent;
    pickButton.disabled = true;
    setText(pickLabel, "正在选择…");
    try {
      const body = await api.selectOutput();
      if (body.cancelled) { setText(pickLabel, previous); return; }
      store.set({ outputSelectionId: body.selectionId, outputDirectory: body.path });
      setText(pickLabel, "导出 · " + (body.name || body.path));
      pickButton.title = "导出到 " + body.path;
    } catch (error) {
      setText(pickLabel, previous);
      toast(error.message, true);
    } finally {
      pickButton.disabled = false;
    }
  });

  // The folder button is only useful where the dialog can actually appear.
  store.watch(["nativePicker"], (state) => {
    pickButton.hidden = !(state.nativePicker && desktopLayout.matches);
  });

  // The primary action should only look actionable when the workflow can
  // actually proceed: the service is ready and a source image is loaded.
  store.watch(["ready", "file"], syncRunAvailability);

  store.watch(["resultUrl"], (state) => {
    download.hidden = !state.resultUrl;
    if (state.resultUrl) download.href = state.resultUrl;
  });

  // A new image invalidates the previous result.
  store.watch(["file"], () => store.set({ resultUrl: "" }));
}
