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

from .concurrency import RAW_DECODE_BUDGET

_LOCK = threading.Lock()
_JOB: dict | None = None
_ACCEPTING = True
_UPLOAD_IN_PROGRESS = False

TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_JOB_TIMEOUT_SECONDS", "3600")))
TERMINATE_GRACE_SECONDS = max(1, int(os.environ.get("HYPERDR_TERMINATE_GRACE_SECONDS", "5")))
# One image cannot legitimately produce more than this; a converter stuck in a
# warning loop can, and its output is held in memory until the job is replaced.
MAX_LOG_CHARS = max(4096, int(os.environ.get("HYPERDR_MAX_JOB_LOG_CHARS", "200000")))
MAX_REPORT_BYTES = max(4096, int(os.environ.get("HYPERDR_MAX_REPORT_BYTES", "4194304")))


class Busy(RuntimeError):
    """A conversion is already running."""


@contextmanager
def upload_slot():
    """Reserve the input for the full streamed-upload replacement."""
    global _UPLOAD_IN_PROGRESS
    with _LOCK:
        if not _ACCEPTING:
            raise Busy("服务正在关闭。")
        if _JOB is not None and not _JOB.get("done"):
            raise Busy("转换进行期间不能更换图片。")
        if _UPLOAD_IN_PROGRESS:
            raise Busy("已有图片正在上传。")
        _UPLOAD_IN_PROGRESS = True
    try:
        yield
    finally:
        with _LOCK:
            _UPLOAD_IN_PROGRESS = False


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


def _pump(job: dict, argv: list[str], cwd: str) -> None:
    proc: subprocess.Popen | None = None
    report = None
    finished = threading.Event()
    try:
        with _LOCK:
            if job.get("cancelled"):
                _append_locked(job, "任务在启动前已取消。\n")
                return
            proc = subprocess.Popen(
                argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
            )
            job["proc"] = proc
        threading.Thread(target=_watch_timeout, args=(job, proc, finished),
                         name="hyperdr-timeout", daemon=True).start()
        for line in proc.stdout:
            with _LOCK:
                _append_locked(job, line)
        proc.wait()

        path = job.get("report_path")
        if path and os.path.isfile(path):
            try:
                if os.path.getsize(path) > MAX_REPORT_BYTES:
                    raise ValueError("report 超过 %d 字节上限" % MAX_REPORT_BYTES)
                with open(path, "r", encoding="utf-8") as handle:
                    report = json.load(handle)
            except Exception as exc:  # noqa: BLE001 - reported, not fatal
                with _LOCK:
                    _append_locked(job, "（读取 report 失败：%s）\n" % exc)
    except Exception as exc:  # noqa: BLE001 - the boundary is the point
        if proc is not None:
            _stop(proc)
        with _LOCK:
            _append_locked(job, "无法运行 HyperDR：%s\n" % exc)
    finally:
        finished.set()
        with _LOCK:
            job["done"] = True
            job["rc"] = proc.returncode if proc is not None else -1
            job["report"] = report
            job["finished_at"] = time.time()


def _pump_pipeline(job: dict, argv: list[str], cwd: str,
                   pre_commands: list[list[str]]) -> None:
    """Run model preparation commands before the final HyperDR command."""
    proc: subprocess.Popen | None = None
    report = None
    commands = list(pre_commands) + [argv]
    try:
        for index, command in enumerate(commands):
            with _LOCK:
                if job.get("cancelled"):
                    _append_locked(job, "job cancelled before pipeline step\n")
                    return
            # The first model pipeline step is HyperDR model-input and can
            # decode a full RAW. Share the same resident-memory budget as live
            # previews so those two paths cannot demosaic concurrently.
            decode_slot = (RAW_DECODE_BUDGET.hold(timeout=1.0)
                           if index == 0 else nullcontext())
            with decode_slot:
                proc = subprocess.Popen(
                    command, cwd=cwd, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                    errors="replace", bufsize=1,
                )
                with _LOCK:
                    job["proc"] = proc
                finished = threading.Event()
                threading.Thread(target=_watch_timeout,
                                 args=(job, proc, finished),
                                 name="hyperdr-timeout", daemon=True).start()
                for line in proc.stdout:
                    with _LOCK:
                        _append_locked(job, line)
                proc.wait()
                finished.set()
            if proc.returncode != 0 or job.get("cancelled"):
                if proc.returncode != 0 and index < len(commands) - 1:
                    with _LOCK:
                        _append_locked(job, "model pipeline step failed; conversion was not started\n")
                break

        path = job.get("report_path")
        if proc is not None and proc.returncode == 0 and path and os.path.isfile(path):
            try:
                if os.path.getsize(path) > MAX_REPORT_BYTES:
                    raise ValueError("report exceeds %d bytes" % MAX_REPORT_BYTES)
                with open(path, "r", encoding="utf-8") as handle:
                    report = json.load(handle)
            except Exception as exc:  # noqa: BLE001 - reported, not fatal
                with _LOCK:
                    _append_locked(job, "(report read failed: %s)\n" % exc)
    except Exception as exc:  # noqa: BLE001 - the boundary is the point
        if proc is not None:
            _stop(proc)
        with _LOCK:
            _append_locked(job, "unable to run HyperDR model pipeline: %s\n" % exc)
    finally:
        with _LOCK:
            job["done"] = True
            job["rc"] = proc.returncode if proc is not None else -1
            job["report"] = report
            job["finished_at"] = time.time()


def start(argv: list[str], cwd: str, report_path: str, session_id: str,
          pre_commands: list[list[str]] | None = None) -> str:
    """Launch a conversion, optionally after model preprocessing commands."""
    global _JOB
    with _LOCK:
        if not _ACCEPTING:
            raise Busy("服务正在关闭。")
        if _UPLOAD_IN_PROGRESS:
            raise Busy("图片上传完成前不能开始转换。")
        if _JOB is not None and not _JOB.get("done"):
            raise Busy("已有转换正在进行。")
        job = {
            "id": uuid.uuid4().hex, "log": "", "dropped": 0, "truncated": False,
            "done": False, "rc": None, "report": None, "report_path": report_path,
            "proc": None, "cancelled": False, "timed_out": False,
            "session_id": session_id, "finished_at": None,
        }
        _JOB = job
    try:
        target = _pump_pipeline if pre_commands else _pump
        args = (job, argv, cwd, pre_commands) if pre_commands else (job, argv, cwd)
        threading.Thread(target=target, args=args, daemon=True).start()
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
        return job["session_id"] if job is not None and not job.get("done") else ""


def is_running() -> bool:
    with _LOCK:
        return _JOB is not None and not _JOB.get("done")


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
