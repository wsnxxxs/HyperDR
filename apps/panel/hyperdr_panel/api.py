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
import math
import secrets
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from . import job, model, session
from .command import build_argv
from .concurrency import Busy
from .formats import SUPPORTED_EXTENSIONS
from .config import IS_WINDOWS, REPO_ROOT
from .executable import detect_exe
from .schema import SETTINGS
from .native_preview import (
    DEFAULT_HIGHLIGHT_RECOVERY,
    MAX_EDGE,
    PreviewCancelled,
    preview_for,
)

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
    # Whether the browser transport itself is TLS. A loopback HTTP page inside
    # the desktop WebView is still a trustworthy secure context, but it is not
    # an encrypted transport, and only the transport fact is reported: the page
    # reads its own `window.isSecureContext` for the other half.
    transport_secure: bool = False
    # Injected so the native dialog, which only exists on Windows and must run
    # on its own thread, is not a hard dependency of the API.
    choose_output_directory: object = None
    # Tauri's Windows shell can submit an absolute local path from its native
    # drag/drop event. Browser/LAN servers leave this disabled.
    native_path_input: bool = False


def error(message: str, status: int = 400, code: str = "") -> Response:
    """`code` is a stable identifier the browser can translate.

    The prose stays in the payload either way: an unknown code has to degrade
    to something readable, and non-browser clients never had a catalogue.
    """
    payload: dict[str, str] = {"error": str(message)}
    # An exception may carry its own code (see `coded`), which saves every
    # generic `except ValueError` handler from having to name one.
    code = code or getattr(message, "code", "")
    if code:
        payload["code"] = code
    return Response(status=status, payload=payload)


def coded(exc: Exception, code: str) -> Exception:
    """Tag an exception with a catalogue code. `raise coded(ValueError(...), ...)`."""
    exc.code = code
    return exc


def _display_command(argv: list[str]) -> str:
    """Format the panel's copyable, human-facing command consistently."""
    return " ".join(f'"{part}"' if " " in part else part for part in argv)


def _validated_use_model(value) -> bool:
    if not isinstance(value, bool):
        raise ValueError("useModel must be a boolean")
    return value


def _validated_model_strength(value) -> float:
    # bool is an int subclass, and "true" is not a strength.
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or not 0 <= value <= 1):
        raise ValueError("modelStrength must be a number in [0, 1]")
    return value


def _prepare_model_options(raw_options: dict | None, *, preview: bool = False):
    """Mark a validated model request for the native command builder."""
    options = dict(raw_options or {})
    # This is an internal routing bit, never a browser-controlled switch.
    options.pop("_model_mode", None)
    use_model = _validated_use_model(options.pop("useModel", False))
    model_strength = _validated_model_strength(options.pop("modelStrength", 1.0))
    if use_model:
        # Keep the mode bit in the private command payload. The command builder
        # turns it into `--ai-model embedded`; it is never accepted from the
        # browser as an independent routing switch.
        options["_model_mode"] = True
        # hdrStrength is the shared plumbing slot for model strength. Manual
        # look controls remain in the browser payload for stale-result display,
        # but the native AI command branch deliberately omits them.
        options["hdrStrength"] = model_strength
    return options, use_model


def _first(query: dict, key: str, default: str = "") -> str:
    values = query.get(key) or [default]
    return values[0]


# --- GET ------------------------------------------------------------------- #

def state(context: Context, _query: dict) -> Response:
    exe = detect_exe()
    return Response(payload={
        "ready": bool(exe) and Path(exe).is_file(),
        "os": "windows" if IS_WINDOWS else "posix",
        "nativePathInput": context.native_path_input,
        "transportSecure": context.transport_secure,
        "hdrPreviewRequiresSecureContext": True,
        "previewMaxEdge": MAX_EDGE,
        "maxUploadMB": session.MAX_UPLOAD_BYTES // (1024 * 1024),
        # The browser's file picker and its drop hint are built from this rather
        # than from a hard-coded accept attribute, so a format added to the
        # converter reaches the page by rebuilding, not by editing HTML.
        "inputExtensions": sorted(SUPPORTED_EXTENSIONS),
        "model": model.status(),
    })


def preview(_context: Context, query: dict) -> Response:
    """Native linear-P3 SDR-base and reconstructed-HDR float planes.

    `hr` is the highlight-recovery mode the panel currently has selected. It
    belongs here because it changes the RAW decode, and therefore the preview:
    leaving it out is what made the control look inert.
    """
    try:
        options = json.loads(_first(query, "options", "{}"))
        if not isinstance(options, dict):
            raise ValueError("preview options must be an object")
        # Internal mode routing is re-derived from the validated useModel bit.
        options.pop("_model_mode", None)
        if "external_gain" in options or "external_gain_report" in options:
            raise ValueError("preview paths are server-controlled")
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        return error("invalid preview options: %s" % exc)
    highlight_recovery = str(options.get("highlightRecovery") or
                             _first(query, "hr", DEFAULT_HIGHLIGHT_RECOVERY))
    if highlight_recovery not in _HIGHLIGHT_RECOVERY_CHOICES:
        return error("unknown highlight recovery: %s" % highlight_recovery)
    try:
        requested_edge = int(_first(query, "edge", str(MAX_EDGE)))
    except ValueError:
        return error("invalid preview edge")
    if not 320 <= requested_edge <= MAX_EDGE:
        return error("preview edge must be between 320 and %s" % MAX_EDGE)

    # A missing session is the one preview failure that invalidates the frame
    # already on the stage. Resolve it separately so the browser can
    # distinguish expiry from a transient decoder/model failure.
    try:
        source = session.input_path(_first(query, "id"))
    except (OSError, ValueError) as exc:
        return error(exc, status=404)
    try:
        use_model = _validated_use_model(options.pop("useModel", False))
        if use_model:
            # Read rather than popped: `modelStrength` stays in the options dict
            # because it takes part in the preview cache key. The command
            # builders pop it instead, which is why this is not
            # `_prepare_model_options` -- only the predicates are shared.
            strength = _validated_model_strength(options.get("modelStrength", 1.0))
            options["_model_mode"] = True
            options["hdrStrength"] = strength
            model_state = model.status()
            if not model_state.get("ready"):
                return error(model_state.get("reason", "模型尚未就绪。"), status=409,
                             code="model_not_ready")
        options["highlightRecovery"] = highlight_recovery
        session_id = _first(query, "id")
        source_digest = session.input_digest(session_id)
        # The digest-named directory gives the native cache a stable, already
        # computed content identity without making every slider move read the
        # whole RAW again. Session expiry removes the cache with the image.
        # `input_path` above has already validated the session id. Build this
        # path without a second session lookup so preview admission tests and
        # lightweight API embeddings can replace the input resolver alone.
        decode_cache = (session.WORK_ROOT / session_id / "output" /
                        ".decode-cache")
        data, metadata = preview_for(
            source, options, requested_edge, source_digest, decode_cache)
    except Busy as exc:
        # Distinct from a missing or broken image: the request was refused, not
        # answered, and a client may retry it.
        return error(exc, status=exc.status, code=exc.code)
    except PreviewCancelled as exc:
        # The browser immediately requested a newer slider state. This is a
        # normal lifecycle event, not an invalid image and not a red toast.
        return error(exc, status=499)
    except (OSError, ValueError) as exc:
        return error(exc, status=422)
    # No headers: width, height, status and degradation reasons all travel in
    # the HYPREV1 packet body, which is what the browser actually parses.
    return Response(body=data, content_type="application/vnd.hyperdr.preview")


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


def open_native_path(context: Context, body: dict) -> Response:
    """Publish a local desktop path without copying the image into the session."""
    if not context.native_path_input:
        return error("native path input is unavailable", status=404)
    session_id = str(body.get("sessionId") or "")
    raw_path = body.get("path")
    try:
        with job.upload_slot():
            source, size = session.set_external_input(session_id, raw_path)
    except Busy as exc:
        return error(exc, status=429, code=exc.code)
    except (OSError, ValueError, TypeError) as exc:
        return error(exc)
    # Do not return the source path to the browser. The name and size are enough
    # for the existing panel state and keep the absolute path inside the local
    # desktop bridge/server boundary.
    return Response(status=201, payload={
        "name": source.name,
        "bytes": size,
        "direct": True,
    })


def command_preview(_context: Context, body: dict) -> Response:
    """Render the exact command line a run would use, without starting one.

    Deriving it from the same builder the runner uses is what keeps the
    displayed command truthful.
    """
    try:
        options, _ = _prepare_model_options(body.get("options"), preview=True)
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


def model_preview(_context: Context, body: dict) -> Response:
    """Probe the native model on the button's existing API call.

    The endpoint keeps its legacy raw-grid response shape so the browser
    interaction stays unchanged, but the bytes now come from the native
    ``model-gain --ai-model embedded`` packet and never touch a session file.
    """
    try:
        session_id = str(body.get("sessionId") or "")
        source = session.input_path(session_id)
        highlight_recovery = str(
            body.get("highlightRecovery") or DEFAULT_HIGHLIGHT_RECOVERY
        )
        if highlight_recovery not in _HIGHLIGHT_RECOVERY_CHOICES:
            raise ValueError("unknown highlight recovery: %s" % highlight_recovery)
        model_state = model.status()
        if not model_state.get("ready"):
            raise coded(
                ValueError(model_state.get("reason", "模型尚未就绪。")),
                "model_not_ready")
        gain, report = model.native_model_gain(source, highlight_recovery)
        width, height = report["width"], report["height"]
        return Response(
            body=gain,
            content_type="application/octet-stream",
            headers={
                "X-Gain-Width": str(width),
                "X-Gain-Height": str(height),
                "X-Gain-Max-Stops": str(report["max_stops"]),
            },
        )
    except Busy as exc:
        return error(exc, status=exc.status, code=exc.code)
    except (OSError, ValueError, RuntimeError) as exc:
        return error(exc)


def cancel(_context: Context, body: dict) -> Response:
    return Response(payload={"cancelled": job.cancel(str(body.get("jobId") or ""))})


def select_output(context: Context, _body: dict) -> Response:
    try:
        if context.choose_output_directory is None:
            raise coded(OSError("当前系统暂不支持原生导出文件夹选择。"),
                        "output_unsupported")
        selected = context.choose_output_directory()
        if not selected:
            return Response(payload={"cancelled": True})
        target = Path(selected).resolve()
        if not target.is_dir():
            raise coded(ValueError("所选导出文件夹不存在。"), "output_missing")
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
            raise coded(ValueError("导出文件夹已失效，请重新选择。"), "output_stale")
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
    session_id = str(body.get("sessionId") or "")
    try:
        with job.preparation_slot(session_id) as preparation_token:
            source = session.input_path(session_id)
            exe = detect_exe()
            if not exe:
                raise coded(ValueError("找不到 HyperDR 可执行文件。"),
                            "executable_missing")
            output = session.session_dir(session_id, "output")
            # The previous run's product goes before this one starts, so a change of
            # encoding cannot leave a stale file under its old extension, and a run
            # that fails before writing a report cannot be handed its predecessor's.
            session.clear_output(session_id)
            options, use_model = _prepare_model_options(body.get("options"))
            options["input"] = str(source)
            options["output"] = str(output)
            options["report"] = str(
                output / ("hyperdr-report-%s.json" % secrets.token_hex(8)))
            if use_model:
                model_state = model.status()
                if not model_state.get("ready"):
                    raise coded(
                ValueError(model_state.get("reason", "模型尚未就绪。")),
                "model_not_ready")
            argv = build_argv(exe, options)
            job_id = job.start(
                argv, str(REPO_ROOT), options["report"], session_id,
                preparation_token=preparation_token)
    except job.Busy as exc:
        return error(exc, status=429, code=exc.code)
    except REQUEST_ERRORS as exc:
        return error(exc)

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


GET_ROUTES = {
    "/api/state": state,
    "/api/preview": preview,
    "/api/log": job_log,
    "/api/result": result,
}

POST_ROUTES = {
    "/api/session": new_session,
    "/api/native-input": open_native_path,
    "/api/select-output": select_output,
    "/api/export": export,
    "/api/run": run,
    "/api/command": command_preview,
    "/api/model-preview": model_preview,
    "/api/cancel": cancel,
}
