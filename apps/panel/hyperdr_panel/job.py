"""The running conversion, and the log the browser polls.

One image at a time means one converter process at a time. The multi-file
version had to reserve per session *and* per run kind, keep up to 64 finished
jobs so several tabs could each poll their own, and bound a log that a
`--recursive` pass over a folder could grow without limit. A single job needs
none of that: the previous one is replaced when the next starts, and the log of
one image is a few lines.

The log is still served incrementally by character offset rather than in full
on every poll, because a slow decode should not re-send its transcript four
times a second.
"""
from __future__ import annotations

from contextlib import contextmanager, nullcontext
import json
import os
import subprocess
import threading
import time
import uuid
from pathlib import Path

from .concurrency import RAW_DECODE_BUDGET
from .formats import RAW_INPUT_EXTENSIONS

_LOCK = threading.Lock()
_JOB: dict | None = None
_ACCEPTING = True
_UPLOAD_IN_PROGRESS = False
_PREPARING: tuple[str, str] | None = None

TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_JOB_TIMEOUT_SECONDS", "3600")))
TERMINATE_GRACE_SECONDS = max(1, int(os.environ.get("HYPERDR_TERMINATE_GRACE_SECONDS", "5")))
# One image cannot legitimately produce more than this; a converter stuck in a
# warning loop can, and its output is held in memory until the job is replaced.
MAX_LOG_CHARS = max(4096, int(os.environ.get("HYPERDR_MAX_JOB_LOG_CHARS", "200000")))
MAX_REPORT_BYTES = max(4096, int(os.environ.get("HYPERDR_MAX_REPORT_BYTES", "4194304")))


def _uses_raw_model_input(command: list[str]) -> bool:
    """Whether a model-input pipeline command will enter LibRaw."""
    return (len(command) >= 3
            and str(command[1]).lower() == "model-input"
            and Path(command[2]).suffix.lower() in RAW_INPUT_EXTENSIONS)


class Busy(RuntimeError):
    """A conversion is already running.

    `code` is a stable identifier for the browser's string catalogue, so the
    refusal can be shown in the reader's language; the message itself stays the
    fallback for clients that have no catalogue.
    """

    def __init__(self, message: str, code: str = "convert_in_progress") -> None:
        super().__init__(message)
        self.code = code


@contextmanager
def upload_slot():
    """Reserve the input for the full streamed-upload replacement."""
    global _UPLOAD_IN_PROGRESS
    with _LOCK:
        if not _ACCEPTING:
            raise Busy("服务正在关闭。", code="shutting_down")
        if _JOB is not None and not _JOB.get("done"):
            raise Busy("转换进行期间不能更换图片。", code="swap_during_convert")
        if _PREPARING is not None:
            raise Busy("转换准备期间不能更换图片。", code="swap_during_prepare")
        if _UPLOAD_IN_PROGRESS:
            raise Busy("已有图片正在上传。", code="upload_in_progress")
        _UPLOAD_IN_PROGRESS = True
    try:
        yield
    finally:
        with _LOCK:
            _UPLOAD_IN_PROGRESS = False


@contextmanager
def preparation_slot(session_id: str):
    """Reserve the input and output before conversion command preparation.

    Model cache checks and output cleanup happen before the subprocess starts;
    treating that interval as part of the run prevents a second request from
    deleting its files or replacing its RAW underneath it.
    """
    global _PREPARING
    token = uuid.uuid4().hex
    with _LOCK:
        if not _ACCEPTING:
            raise Busy("服务正在关闭。", code="shutting_down")
        if _UPLOAD_IN_PROGRESS:
            raise Busy("图片上传完成前不能开始转换。", code="upload_incomplete")
        if _PREPARING is not None or (_JOB is not None and not _JOB.get("done")):
            raise Busy("已有转换正在进行。", code="convert_in_progress")
        _PREPARING = (token, session_id)
    try:
        yield token
    finally:
        with _LOCK:
            if _PREPARING is not None and _PREPARING[0] == token:
                _PREPARING = None


def _append_locked(job: dict, text: str) -> None:
    """Append to the log, dropping the front if it outgrows its budget.

    `dropped` records where the retained log now begins, so offsets stay
    absolute: a client polling from an offset that has since been discarded is
    moved forward and told the log was truncated, rather than silently handed a
    slice measured from the wrong origin.
    """
    if not text:
        return
    job["log"] += text
    excess = len(job["log"]) - MAX_LOG_CHARS
    if excess > 0:
        job["log"] = job["log"][excess:]
        job["dropped"] += excess
        job["truncated"] = True


def _stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=TERMINATE_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    except OSError:
        pass


def _watch_timeout(job: dict, proc: subprocess.Popen, finished: threading.Event) -> None:
    if finished.wait(TIMEOUT_SECONDS):
        return
    with _LOCK:
        if job.get("done") or job.get("proc") is not proc:
            return
        job["timed_out"] = True
        _append_locked(job, "转换超过执行时限，正在终止。\n")
    _stop(proc)


def _run_step(job: dict, command: list[str], cwd: str, *,
              decode_budget: bool = False) -> subprocess.Popen | None:
    """Run one command to completion, streaming its output into the job log.

    Returns None when the job was cancelled before the process could start.
    The cancellation check and `job["proc"]` share one lock acquisition on
    purpose: `cancel()` reads that slot under the same lock, so a cancel can
    never land in a gap where the process exists but nothing can stop it.
    """
    # HyperDR model-input can decode a full RAW. Share the resident-memory
    # budget with live previews so those two paths cannot demosaic concurrently.
    slot = RAW_DECODE_BUDGET.hold(timeout=1.0) if decode_budget else nullcontext()
    with slot:
        with _LOCK:
            if job.get("cancelled"):
                _append_locked(job, "任务在启动前已取消。\n")
                return None
            proc = subprocess.Popen(
                command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
            )
            job["proc"] = proc
        finished = threading.Event()
        threading.Thread(target=_watch_timeout, args=(job, proc, finished),
                         name="hyperdr-timeout", daemon=True).start()
        try:
            for line in proc.stdout:
                with _LOCK:
                    _append_locked(job, line)
            proc.wait()
        finally:
            # Release the watchdog even if streaming raised, or it sits on the
            # whole timeout before noticing the job is already over.
            finished.set()
    return proc


def _read_report(job: dict, path: str):
    """Return the parsed report, or None after logging why it could not be."""
    try:
        if os.path.getsize(path) > MAX_REPORT_BYTES:
            raise ValueError("report 超过 %d 字节上限" % MAX_REPORT_BYTES)
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:  # noqa: BLE001 - reported, not fatal
        with _LOCK:
            _append_locked(job, "（读取 report 失败：%s）\n" % exc)
        return None


def _pump(job: dict, argv: list[str], cwd: str,
          pre_commands: list[list[str]] | None = None) -> None:
    """Run any model preparation commands, then the conversion itself.

    One function for both shapes deliberately: they had drifted into two copies
    that reported the same failures in different languages into the same
    browser-visible log pane.
    """
    proc: subprocess.Popen | None = None
    report = None
    pre_commands = list(pre_commands or [])
    commands = pre_commands + [argv]
    try:
        for index, command in enumerate(commands):
            proc = _run_step(job, command, cwd,
                             decode_budget=index == 0 and _uses_raw_model_input(command))
            if proc is None:
                return
            if proc.returncode != 0 or job.get("cancelled"):
                if proc.returncode != 0 and index < len(commands) - 1:
                    with _LOCK:
                        _append_locked(job, "模型流程步骤失败，未开始转换。\n")
                break

        path = job.get("report_path")
        # A lone conversion writes a report describing its own failure, so it is
        # worth reading whatever the exit code. A pipeline's report describes
        # only the final step and means nothing if an earlier one broke.
        complete = proc is not None and (not pre_commands or proc.returncode == 0)
        if complete and path and os.path.isfile(path):
            report = _read_report(job, path)
    except Exception as exc:  # noqa: BLE001 - the boundary is the point
        if proc is not None:
            _stop(proc)
        with _LOCK:
            _append_locked(job, "无法运行 HyperDR：%s\n" % exc)
    finally:
        with _LOCK:
            job["done"] = True
            job["rc"] = proc.returncode if proc is not None else -1
            job["report"] = report
            job["finished_at"] = time.time()


def start(argv: list[str], cwd: str, report_path: str, session_id: str,
          pre_commands: list[list[str]] | None = None,
          preparation_token: str | None = None) -> str:
    """Launch a conversion, optionally after model preprocessing commands."""
    global _JOB, _PREPARING
    with _LOCK:
        if not _ACCEPTING:
            raise Busy("服务正在关闭。", code="shutting_down")
        if preparation_token is not None:
            if (_PREPARING is None or _PREPARING[0] != preparation_token
                    or _PREPARING[1] != session_id):
                raise Busy("转换准备凭据已失效。", code="convert_preparing")
            _PREPARING = None
        else:
            if _UPLOAD_IN_PROGRESS:
                raise Busy("图片上传完成前不能开始转换。", code="upload_incomplete")
            if _PREPARING is not None:
                raise Busy("已有转换正在准备。", code="convert_preparing")
            if _JOB is not None and not _JOB.get("done"):
                raise Busy("已有转换正在进行。", code="convert_in_progress")
        job = {
            "id": uuid.uuid4().hex, "log": "", "dropped": 0, "truncated": False,
            "done": False, "rc": None, "report": None, "report_path": report_path,
            "proc": None, "cancelled": False, "timed_out": False,
            "session_id": session_id, "finished_at": None,
        }
        _JOB = job
    try:
        threading.Thread(target=_pump, args=(job, argv, cwd, pre_commands),
                         daemon=True).start()
    except Exception:
        with _LOCK:
            if _JOB is job:
                _JOB = None
        raise
    return job["id"]


def cancel(job_id: str) -> bool:
    """Terminate the running conversion. False if it is not the current job."""
    with _LOCK:
        job = _JOB
        if job is None or job["id"] != job_id or job.get("done"):
            return False
        job["cancelled"] = True
        proc = job.get("proc")
    if proc is not None:
        _stop(proc)
    return True


def read(job_id: str, offset: int) -> dict | None:
    """The log tail from `offset` plus status, or None if this is not the job."""
    with _LOCK:
        job = _JOB
        if job is None or job["id"] != job_id:
            return None
        dropped = job["dropped"]
        total = dropped + len(job["log"])
        requested = offset
        # Below `dropped` the log no longer exists, so the client is moved
        # forward rather than handed a slice from the wrong origin.
        offset = min(max(dropped, offset), total)
        return {
            "text": job["log"][offset - dropped:],
            "offset": total,
            "logStart": dropped,
            "done": job["done"],
            "rc": job["rc"],
            "report": job["report"] if job["done"] else None,
            "sessionId": job["session_id"],
            "cancelled": bool(job["cancelled"]),
            "timedOut": bool(job["timed_out"]),
            "truncated": bool(job["truncated"]) or requested < dropped,
        }


def active_session_id() -> str:
    """The session a conversion is using, so cleanup does not delete its files."""
    with _LOCK:
        job = _JOB
        if job is not None and not job.get("done"):
            return job["session_id"]
        return _PREPARING[1] if _PREPARING is not None else ""


def is_running() -> bool:
    with _LOCK:
        return (_PREPARING is not None or
                (_JOB is not None and not _JOB.get("done")))


def shutdown(wait_seconds: float = 10.0) -> None:
    """Stop admission, terminate the converter, and wait for the pump to finish."""
    global _ACCEPTING
    with _LOCK:
        _ACCEPTING = False
        job = _JOB
        if job is None or job.get("done"):
            return
        job["cancelled"] = True
        proc = job.get("proc")
    if proc is not None:
        _stop(proc)
    deadline = time.monotonic() + max(0.0, wait_seconds)
    while time.monotonic() < deadline:
        with _LOCK:
            if job.get("done"):
                return
        time.sleep(0.05)
