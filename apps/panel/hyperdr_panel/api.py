"""The panel's internal HTTP API, as plain functions.

Every endpoint used to be a method on the request handler, which meant none of
them could be exercised without a socket: the whole API surface was untested.
Each endpoint here takes a context and a dictionary and returns a `Response`, so
the interesting half -- what a request does -- is testable, and `handler.py` is
left with only the parts that genuinely need a live connection.

These routes are an implementation detail of the bundled browser panel, not a
public integration API. Their paths and payloads may change without
compatibility guarantees.
"""
from __future__ import annotations

import json
import secrets
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from . import job, session
from .command import build_argv
from .concurrency import Busy
from .config import IS_WINDOWS, REPO_ROOT
from .curve import look_curve
from .executable import detect_exe
from .schema import SETTINGS
from .thumbnail import DEFAULT_HIGHLIGHT_RECOVERY, MAX_EDGE, thumbnail_for

# Errors an endpoint may raise for a bad request, as opposed to a bug.
REQUEST_ERRORS = (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError)

#: Validated against the converter's own schema rather than a second list here,
#: so adding a mode to the C++ enum cannot leave the preview rejecting it.
_HIGHLIGHT_RECOVERY_CHOICES = frozenset(SETTINGS["highlight_recovery"]["choices"])

#: What a converted file is served as, by extension.
_RESULT_TYPES = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".avif": "image/avif", ".heic": "image/heic",
}


@dataclass
class Response:
    """What to send back. Exactly one of `payload`, `body` or `file` is set."""

    status: int = 200
    payload: object | None = None
    body: bytes | None = None
    content_type: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    file: Path | None = None
    download: bool = False


@dataclass
class Context:
    """Server state an endpoint may read or extend."""

    # Folders the user picked through the native dialog, by opaque id. Paths are
    # never accepted from the browser: only ids issued here.
    output_selections: dict[str, Path]
    secure_context_expected: bool = False
    # Injected so the native dialog, which only exists on Windows and must run
    # on its own thread, is not a hard dependency of the API.
    choose_output_directory: object = None


def error(message: str, status: int = 400) -> Response:
    return Response(status=status, payload={"error": str(message)})


def _display_command(argv: list[str]) -> str:
    """Format the panel's copyable, human-facing command consistently."""
    return " ".join(f'"{part}"' if " " in part else part for part in argv)


def _first(query: dict, key: str, default: str = "") -> str:
    values = query.get(key) or [default]
    return values[0]


# --- GET ------------------------------------------------------------------- #

def state(context: Context, _query: dict) -> Response:
    exe = detect_exe()
    return Response(payload={
        "ready": bool(exe) and Path(exe).is_file(),
        "os": "windows" if IS_WINDOWS else "posix",
        "nativeOutputPicker": IS_WINDOWS,
        "secureContextExpected": context.secure_context_expected,
        "transportSecure": context.secure_context_expected,
        "hdrPreviewRequiresSecureContext": True,
        "previewMaxEdge": MAX_EDGE,
        "maxUploadMB": session.MAX_UPLOAD_BYTES // (1024 * 1024),
    })


def preview(_context: Context, query: dict) -> Response:
    """The small JPEG the browser builds its live HDR preview from.

    `hr` is the highlight-recovery mode the panel currently has selected. It
    belongs here because it changes the RAW decode, and therefore the preview:
    leaving it out is what made the control look inert.
    """
    highlight_recovery = _first(query, "hr", DEFAULT_HIGHLIGHT_RECOVERY)
    if highlight_recovery not in _HIGHLIGHT_RECOVERY_CHOICES:
        return error("unknown highlight recovery: %s" % highlight_recovery)
    try:
        requested_edge = int(_first(query, "edge", str(MAX_EDGE)))
    except ValueError:
        return error("invalid preview edge")
    if not 320 <= requested_edge <= MAX_EDGE:
        return error("preview edge must be between 320 and %s" % MAX_EDGE)
    try:
        data, dimensions, mime = thumbnail_for(
            session.input_path(_first(query, "id")), highlight_recovery, requested_edge)
    except Busy as exc:
        # Distinct from a missing or broken image: the request was refused, not
        # answered, and a client may retry it.
        return error(exc, status=exc.status)
    except (OSError, ValueError) as exc:
        return error(exc, status=404)
    return Response(body=data, content_type=mime, headers={
        "X-Preview-Width": str(dimensions[0]),
        "X-Preview-Height": str(dimensions[1]),
        "X-Preview-Max-Edge": str(requested_edge),
    })


def job_log(_context: Context, query: dict) -> Response:
    try:
        offset = max(0, int(_first(query, "offset", "0")))
    except ValueError:
        return error("invalid offset")
    result_payload = job.read(_first(query, "id"), offset)
    if result_payload is None:
        return error("unknown job", status=404)
    return Response(payload=result_payload)


def result(_context: Context, query: dict) -> Response:
    """The converted image itself.

    Served inline so the page can show it, and as an attachment when asked --
    which is how a phone saves it, since the native folder picker only ever
    opens on the machine running the service.
    """
    try:
        target = session.result_path(_first(query, "id"))
    except (OSError, ValueError) as exc:
        return error(exc, status=404)
    return Response(
        file=target,
        content_type=_RESULT_TYPES.get(target.suffix.lower(), "application/octet-stream"),
        download=_first(query, "download", "0") == "1",
    )


# --- POST ------------------------------------------------------------------ #

def new_session(_context: Context, _body: dict) -> Response:
    return Response(status=201, payload={"sessionId": session.create_session()})


def command_preview(_context: Context, body: dict) -> Response:
    """Render the exact command line a run would use, without starting one.

    Deriving it from the same builder the runner uses is what keeps the
    displayed command truthful.
    """
    try:
        options = dict(body.get("options") or {})
        options.update({
            "input": "<已上传图片>",
            "output": "<任务输出>",
            "report": "<任务输出>/hyperdr-report.json",
        })
        argv = build_argv("HyperDR", options)
    except REQUEST_ERRORS as exc:
        return error(exc)
    return Response(payload={
        "argv": argv,
        "command": _display_command(argv),
    })


def curve(_context: Context, body: dict) -> Response:
    try:
        exe = detect_exe()
        if not exe:
            raise ValueError("找不到 HyperDR 可执行文件。")
        samples = int(body.get("samples") or 257)
        if not 2 <= samples <= 4096:
            raise ValueError("采样点数必须在 2 到 4096 之间。")
        return Response(payload=look_curve(exe, dict(body.get("options") or {}), samples))
    except Busy as exc:
        return error(exc, status=exc.status)
    except REQUEST_ERRORS as exc:
        return error(exc)


def cancel(_context: Context, body: dict) -> Response:
    return Response(payload={"cancelled": job.cancel(str(body.get("jobId") or ""))})


def select_output(context: Context, _body: dict) -> Response:
    try:
        if context.choose_output_directory is None:
            raise OSError("当前系统暂不支持原生导出文件夹选择。")
        selected = context.choose_output_directory()
        if not selected:
            return Response(payload={"cancelled": True})
        target = Path(selected).resolve()
        if not target.is_dir():
            raise ValueError("所选导出文件夹不存在。")
        selection_id = secrets.token_urlsafe(18)
        context.output_selections[selection_id] = target
        return Response(payload={
            "selectionId": selection_id,
            "path": str(target),
            "name": target.name or str(target),
        })
    except (OSError, ValueError, RuntimeError) as exc:
        return error(exc)


def export(context: Context, body: dict) -> Response:
    """Copy the converted image into the folder the user picked."""
    try:
        session_id = str(body.get("sessionId") or "")
        destination = context.output_selections.get(str(body.get("selectionId") or ""))
        if destination is None or not destination.is_dir():
            raise ValueError("导出文件夹已失效，请重新选择。")
        source = session.result_path(session_id)
        target = (destination / source.name).resolve()
        # Re-checked after resolution: a symlink inside the session must not be
        # able to write outside the chosen folder.
        target.relative_to(destination.resolve())
        shutil.copy2(source, target)
    except REQUEST_ERRORS as exc:
        return error(exc)
    return Response(payload={"path": str(target), "name": target.name})


def run(_context: Context, body: dict) -> Response:
    try:
        session_id = str(body.get("sessionId") or "")
        source = session.input_path(session_id)
        exe = detect_exe()
        if not exe:
            raise ValueError("找不到 HyperDR 可执行文件。")
        output = session.session_dir(session_id, "output")
        # The previous run's product goes before this one starts, so a change of
        # encoding cannot leave a stale file under its old extension, and a run
        # that fails before writing a report cannot be handed its predecessor's.
        session.clear_output(session_id)
        options = dict(body.get("options") or {})
        options["input"] = str(source)
        options["output"] = str(output)
        options["report"] = str(output / ("hyperdr-report-%s.json" % secrets.token_hex(8)))
        argv = build_argv(exe, options)
    except REQUEST_ERRORS as exc:
        return error(exc)

    try:
        job_id = job.start(argv, str(REPO_ROOT), options["report"], session_id)
    except job.Busy as exc:
        return error(exc, status=429)

    # The front-end shows this instead of assembling its own copy. The real
    # executable path is replaced by the product name: it is not the browser's
    # business where the binary lives.
    display = [str(part) for part in argv]
    display[0] = "HyperDR"
    return Response(payload={
        "jobId": job_id,
        "argv": display,
        "command": _display_command(display),
    })


def upload_is_allowed(_session_id: str) -> None:
    """Replacing the image mid-run would change the input under the converter."""
    if job.is_running():
        raise ValueError("转换进行期间不能更换图片。")


GET_ROUTES = {
    "/api/state": state,
    "/api/preview": preview,
    "/api/log": job_log,
    "/api/result": result,
}

POST_ROUTES = {
    "/api/session": new_session,
    "/api/select-output": select_output,
    "/api/export": export,
    "/api/run": run,
    "/api/command": command_preview,
    "/api/curve": curve,
    "/api/cancel": cancel,
}
