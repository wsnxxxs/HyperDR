/* Starting a conversion, following it, and handing back the result.
 *
 * The result used to be a text link in the settings column and a toast -- the
 * one moment the whole panel exists for, spent on a hyperlink. It is now a
 * block in the control column's foot: the file name and dimensions, the peak
 * actually reached (the report's `rendered_peak`, the number the preview
 * admits it cannot compute), the verification the converter ran on its own
 * output, and one consistent download action.
 *
 * The poll loop is a single awaited function with an explicit exit rather than
 * a `setInterval` whose handle had to be cleared from four branches.
 */

import { api, ApiError } from "../core/api.js";
import { store } from "../core/store.js";
import { t, onLocaleChange } from "../i18n/index.js";
import { role, setText, debounce } from "../core/dom.js";
import { toOptions, OPTION_KEYS } from "../settings/schema.js";

import { mountExportHistory } from "./export-history.js";

const POLL_INTERVAL_MS = 400;
const TRACKING_INTERRUPTED_MS = 15_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const runOptionsFor = (state) => ({
  ...toOptions(state),
  useModel: Boolean(state.previewOptimized),
});

export function mountRunner({ toast }) {
  const runButton = role("run");
  const cancelButton = role("cancel");
  const download = role("download");
  const resultCard = role("result");
  const commandLine = role("command-line");
  const commandCopy = role("command-copy");
  const runProgress = role("run-progress");

  let activeJobId = "";
  let starting = false;
  let trackingInterrupted = false;
  let commandSeq = 0;

  /* ── result card ──────────────────────────────────────────────────── */

  function peakClause(peakLinear) {
    if (!Number.isFinite(peakLinear) || peakLinear <= 1) return "";
    const stops = Math.log2(peakLinear);
    return t("run.peak", { peak: peakLinear.toFixed(2), stops: stops.toFixed(1) });
  }

  function syncResult(state) {
    const result = state.result;
    resultCard.hidden = !result;
    if (!result) return;
    setText(role("result-name"), result.name);
    const meta = [
      result.width && result.height ? `${result.width}×${result.height}` : "",
      peakClause(result.peakLinear),
      result.verified ? t("run.verified") : "",
      Number.isFinite(result.durationS)
        ? t("run.duration", { seconds: result.durationS.toFixed(1) }) : "",
    ].filter(Boolean).join(" · ");
    setText(role("result-meta"), meta);
    const warn = role("result-warn");
    warn.hidden = !result.degradedNote;
    setText(warn, result.degradedNote || "");
    if (download.href !== result.downloadUrl) download.href = result.downloadUrl;
  }

  /* Touching any setting after a run makes the card's file describe settings
   * it was not converted with -- say so instead of letting it pass as current. */
  function isStale(state) {
    return Boolean(state.result)
      && JSON.stringify(runOptionsFor(state)) !== state.result.optionsKey;
  }

  /* The primary button doubles as the way back to a current result: when the
   * card has gone stale it says so by offering to "重新转换". */
  function syncRunLabel() {
    if (activeJobId || starting) return;
    setText(runButton, store.get().encoding === "sdr-jpeg" ? t("workflow.saveJpeg") : isStale(store.get()) ? t("run.again") : t("run.start"));
  }

  function syncStale(state) {
    role("result-stale").hidden = !isStale(state);
    syncRunLabel();
  }

  /* ── command line ─────────────────────────────────────────────────── */

  const refreshCommand = debounce(async () => {
    const details = commandLine.closest("details");
    if (!details.open) return;
    const seq = ++commandSeq;
    try {
      const body = await api.command(runOptionsFor(store.get()));
      if (seq === commandSeq) setText(commandLine, body.command || "");
    } catch (_) {
      if (seq === commandSeq) setText(commandLine, t("out.commandUnavailable"));
    }
  }, 300);
  commandLine.closest("details").addEventListener("toggle", refreshCommand);

  commandCopy.addEventListener("click", async () => {
    const text = commandLine.textContent.trim();
    if (!text) return;
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        // HTTP mode has no async clipboard; fall back to the selection API.
        const area = document.createElement("textarea");
        area.value = text;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.append(area);
        area.select();
        document.execCommand("copy");
        area.remove();
      }
      toast(t("out.commandCopied"));
    } catch (_) {
      toast(t("out.commandCopyFailed"), true);
    }
  });

  /* ── availability ─────────────────────────────────────────────────── */

  function syncRunAvailability(state) {
    runButton.disabled =
      starting || state.restoring || state.uploading || state.optimizing || Boolean(state.jobId)
      || !state.capabilities?.ready || !state.file || !state.previewReady;
  }

  /* ── the run itself ───────────────────────────────────────────────── */

  function setTrackingInterrupted(jobId, interrupted) {
    if (activeJobId !== jobId || trackingInterrupted === interrupted) return;
    trackingInterrupted = interrupted;
    setText(runButton, interrupted ? t("run.interrupted") : t("run.busy"));
    setText(cancelButton, interrupted ? t("run.stopWaiting") : t("run.cancel"));
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
      if (typeof update.text === "string") log = (log + update.text).slice(-200_000);
      // The converter narrates its stages on stdout; the last line is the
      // closest thing a long RAW conversion has to a progress bar.
      const line = lastLine(log, 80);
      if (line) setText(runProgress, line);
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

  const basename = (path) => String(path || "").split(/[\\/]/).filter(Boolean).pop() || t("run.outputFile");

  // Report schema 8. Only the single success file is read; the reasons are
  // joined for display and never inspected, so a new reason needs no change here.
  function summarizeReport(report) {
    const files = report && Array.isArray(report.files) ? report.files : [];
    const file = files.find((entry) => entry && entry.success);
    if (!file) return {};
    let degradedNote = "";
    if (file.decode_degraded) {
      const reasons = Array.isArray(file.decode_degradation_reasons)
        ? file.decode_degradation_reasons.join(t("run.reasonSeparator"))
        : "";
      const actual = `${file.decoded_width}×${file.decoded_height}`;
      const target = `${file.target_width}×${file.target_height}`;
      const wrapped = reasons ? t("run.reasonWrap", { reasons }) : "";
      degradedNote = file.target_dimensions_applied === false
        ? t("run.cropIgnored", { target, actual, reasons: wrapped })
        : t("run.cropMismatch", { actual, target, reasons: wrapped });
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
    runProgress.hidden = true;
    syncRunLabel();
    setText(cancelButton, t("run.cancel"));
    cancelButton.hidden = true;
    cancelButton.disabled = false;
  }

  async function start() {
    const state = store.get();
    if (starting || state.jobId || state.uploading || state.restoring || state.optimizing) return;
    if (!state.capabilities?.ready) { toast(t("run.notReady"), true); return; }
    if (!state.file) { toast(t("run.noFile"), true); return; }

    const runOptions = runOptionsFor(state);
    let started;
    starting = true;
    store.set({ starting: true });
    syncRunAvailability(store.get());
    try {
      started = await api.run(state.sessionId, runOptions);
    } catch (error) {
      toast(error.message, true);
      return;
    } finally {
      starting = false;
      store.set({ starting: false });
      syncRunAvailability(store.get());
    }

    track(started, state);
  }

  async function track(started, state) {
    activeJobId = started.jobId;
    trackingInterrupted = false;
    store.set({ jobId: started.jobId });
    setText(runButton, t("run.busy"));
    setText(runProgress, t("run.starting"));
    runProgress.hidden = false;
    cancelButton.hidden = false;
    cancelButton.disabled = false;

    try {
      const outcome = await followJob(started.jobId);
      if (outcome.abandoned) return;

      if (outcome.cancelled) {
        toast(t("run.cancelled"));
      } else if (outcome.timedOut) {
        toast(t("run.timeout"), true);
      } else if (outcome.rc !== 0) {
        const detail = lastLine(outcome.log);
        toast(detail ? t("run.failedDetail", { detail }) : t("run.failed"), true);
      } else {
        const workspace = await api.workspace(state.sessionId);
        if (activeJobId !== started.jobId) return;
        store.set({ exports: workspace.exports });
        const entry = workspace.exports.find(({ id }) => id === (outcome.exportId || started.exportId));
        if (!entry) throw new Error(t("run.lost"));
        selectResult(entry);
        const note = store.get().result.degradedNote;
        toast(note ? t("run.succeededDegraded", { note }) : t("run.succeeded"), Boolean(note));
      }
    } catch (error) {
      toast(error.message || t("run.lost"), true);
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
      toast(t("run.stoppedWaiting"), true);
      return;
    }
    cancelButton.disabled = true;
    try { await api.cancel(jobId); }
    catch (error) { toast(error.message, true); cancelButton.disabled = false; }
  });

  /* The result card is the single delivery path on every platform. */

  /* ── wiring ───────────────────────────────────────────────────────── */

  store.watchAny(["result"], syncResult, { immediate: true });
  store.watchAny(
    ["restoring", "uploading", "optimizing", "file", "previewReady", "jobId", "capabilities"],
    syncRunAvailability,
    { immediate: true },
  );
  store.watchAny([...OPTION_KEYS, "previewOptimized", "result"], (state, _previous, changed) => {
    syncStale(state);
    if (changed.some((key) => OPTION_KEYS.includes(key) || key === "previewOptimized")) {
      commandSeq++;
      refreshCommand();
    }
  });

  /* The run button and the result card are written imperatively, so a language
   * change has to re-emit them; anything transient (a toast already on screen,
   * a log line already scrolled past) keeps the language it was written in. */
  onLocaleChange(() => {
    syncRunLabel();
    syncResult(store.get());
  });

  function selectResult(entry) {
    const summary = summarizeReport(entry.report);
    store.set({ result: {
      ...summary, name: summary.name || entry.name, exportId: entry.id,
      optionsKey: JSON.stringify(runOptionsFor({
        ...store.get(), ...entry.options, previewOptimized: entry.options.useModel,
      })),
      downloadUrl: api.resultUrl(store.get().sessionId, { download: true, exportId: entry.id }),
    } });
  }
  mountExportHistory({ selectResult });
  return {
    restore(workspace, selectedExport) {
      const entry = workspace.exports.find(({ id }) => id === selectedExport) || workspace.exports[0];
      if (entry) selectResult(entry);
      if (workspace.job && !workspace.job.done) {
        track(workspace.job, store.get());
      }
    },
  };

}
