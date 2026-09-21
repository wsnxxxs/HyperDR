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
import { OPTION_KEYS } from "../settings/schema.js";
import { prefs } from "../ui/prefs-schema.js";

import { mountExportHistory } from "./export-history.js";
import { bindSaveAction, canSaveWithoutPrompt } from "./save.js";
import { runOptionsFor, entryKeyFor, exportKeyFor, currentResult } from "./options.js";

const POLL_INTERVAL_MS = 400;
const TRACKING_INTERRUPTED_MS = 15_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Why an export cannot start right now, in words, or "" when it can. The
 *  run button used to go grey for any of seven reasons without naming one.
 *  A running export is not listed: the progress line already says so. */
export function runBlocker(state, { starting = false } = {}) {
  if (starting || state.jobId) return "";
  if (!state.capabilities) return "run.reason.booting";
  if (!state.capabilities.ready) return "run.reason.noConverter";
  if (!state.file) return "run.reason.noPhoto";
  if (state.restoring) return "run.reason.restoring";
  if (state.uploading) return "run.reason.uploading";
  if (state.optimizing) return "run.reason.optimizing";
  if (!state.previewReady) return "run.reason.preview";
  return "";
}

export function mountRunner({ toast }) {
  const runButton = role("run");
  const runNote = role("run-note");
  const cancelButton = role("cancel");
  const saveButton = role("save");
  const saveState = role("save-state");
  const openFolderButton = role("save-open-folder");
  const resultCard = role("result");
  const resultCaption = role("result-caption");
  const commandLine = role("command-line");
  const commandCopy = role("command-copy");
  const runProgress = role("run-progress");

  let activeJobId = "";
  let starting = false;
  let trackingInterrupted = false;
  let commandSeq = 0;
  const refreshSaveAction = bindSaveAction(saveButton, saveState, () => ({
    sessionId: store.get().sessionId,
    exportId: store.get().result?.exportId,
    name: store.get().result?.name,
  }), { openFolderButton });

  /* ── result card ──────────────────────────────────────────────────── */

  function peakClause(peakLinear) {
    if (!Number.isFinite(peakLinear) || peakLinear <= 1) return "";
    const stops = Math.log2(peakLinear);
    return t("run.peak", { peak: peakLinear.toFixed(2), stops: stops.toFixed(1) });
  }

  function syncResult(state) {
    const result = state.result;
    resultCard.hidden = !result;
    refreshSaveAction();
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
  }

  /* Touching any setting after a run makes the card's file describe settings
   * it was not converted with -- say so instead of letting it pass as current. */
  function isStale(state) {
    return Boolean(state.result) && !currentResult(state);
  }

  /* Which of the two actions is the next step. With nothing exported, or the
   * card gone stale, it is exporting; once the edit on screen is exported it
   * is saving, and exporting the same settings again drops to secondary. */
  function syncRunLabel() {
    const state = store.get();
    const exported = Boolean(currentResult(state));
    const stale = isStale(state);
    const secondary = exported && !activeJobId && !starting;
    runButton.classList.toggle("button--secondary", secondary);
    runButton.classList.toggle("button--primary", !secondary);
    saveButton.classList.toggle("button--primary", !stale);
    if (activeJobId || starting) return;
    setText(runButton, exported ? t("run.repeat") : stale ? t("run.again")
      : state.encoding === "sdr-jpeg" ? t("workflow.saveJpeg") : t("run.start"));
  }

  function syncStale(state) {
    const stale = isStale(state);
    role("result-stale").hidden = !stale;
    resultCard.dataset.stale = String(stale);
    setText(resultCaption, stale ? t("run.previousResult") : t("run.result"));
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
    const reason = runBlocker(state, { starting });
    runNote.hidden = !reason;
    setText(runNote, reason ? t(reason) : "");
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
  async function followJob(jobId, startedAt = performance.now()) {
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
      // The converter is mostly silent until it finishes, so the elapsed time
      // is what shows the export is alive; a line it does print rides along.
      // Its closing "ok: <file>" is not news while the job is still running.
      const line = lastLine(log, 80);
      const elapsed = t("run.elapsed", { seconds: Math.max(1, Math.round((performance.now() - startedAt) / 1000)) });
      setText(runProgress, line && !/^ok:/i.test(line) ? `${elapsed} · ${line}` : elapsed);
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
      // A degradation that left the geometry alone (no camera matrix, an SDR
      // fallback) must not read as a size mismatch.
      if (file.target_dimensions_applied === false) {
        degradedNote = t("run.cropIgnored", { target, actual, reasons: wrapped });
      } else if (actual !== target) {
        degradedNote = t("run.cropMismatch", { actual, target, reasons: wrapped });
      } else {
        degradedNote = t("run.decodeDegraded", { reasons: wrapped });
      }
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
    runButton.classList.remove("button--secondary");
    runButton.classList.add("button--primary");
    setText(runButton, t("run.busy"));
    setText(runProgress, t("run.starting"));
    runProgress.hidden = false;
    cancelButton.hidden = false;
    cancelButton.disabled = false;

    try {
      const outcome = await followJob(started.jobId, performance.now());
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
        // "Fixed folder" means the user has already said where exports go, so
        // the finished file goes there without a second click. Every other
        // target needs a choice (a picker, a download prompt) and stays manual.
        if (canSaveWithoutPrompt()) saveButton.click();
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
    ["restoring", "uploading", "optimizing", "file", "previewReady", "jobId", "capabilities", "starting"],
    syncRunAvailability,
    { immediate: true },
  );
  store.watch("savedExports", refreshSaveAction);
  /* An undo, a redo or a slider moved back can return the edit to settings
   * that were already exported. That export is then the current result: the
   * card shows it and its saved state, and the header calls the edit exported
   * instead of asking for a duplicate version. */
  function adoptMatchingExport(state) {
    if (!isStale(state)) return;
    const key = exportKeyFor(state);
    const match = (state.exports || []).find((entry) => entryKeyFor(entry, state) === key);
    if (match) selectResult(match);
  }

  store.watchAny([...OPTION_KEYS, "previewOptimized", "modelId", "sourceDomain", "result"],
    (state, _previous, changed) => {
      if (!changed.includes("result")) adoptMatchingExport(state);
      syncStale(store.get());
      if (changed.some((key) => OPTION_KEYS.includes(key)
          || key === "previewOptimized" || key === "modelId" || key === "sourceDomain")) {
        commandSeq++;
        refreshCommand();
      }
    });

  /* The run button and the result card are written imperatively, so a language
   * change has to re-emit them; anything transient (a toast already on screen,
   * a log line already scrolled past) keeps the language it was written in. */
  onLocaleChange(() => {
    syncStale(store.get());
    syncResult(store.get());
    syncRunAvailability(store.get());
    refreshSaveAction();
  });
  store.watch("capabilities", refreshSaveAction);
  prefs.watch("saveTarget", refreshSaveAction);

  function selectResult(entry) {
    const summary = summarizeReport(entry.report);
    store.set({ result: {
      ...summary, name: summary.name || entry.name, exportId: entry.id,
      optionsKey: entryKeyFor(entry, store.get()),
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
