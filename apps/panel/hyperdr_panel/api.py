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
from .config import IS_WINDOWS, REPO_ROOT
from .curve import look_curve
from .executable import detect_exe
from .schema import SETTINGS
from .native_preview import DEFAULT_HIGHLIGHT_RECOVERY, MAX_EDGE, preview_for

# Compatibility injection point for older panel tests and embedders. Production
# resolves to the native float-frame provider; it is no longer a JPEG builder.
thumbnail_for = preview_for

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


def _prepare_model_options(raw_options: dict | None, *, preview: bool = False):
    """Apply the model slider to the command before it is built."""
    options = dict(raw_options or {})
    use_model = options.pop("useModel", False)
    if not isinstance(use_model, bool):
        raise ValueError("useModel must be a boolean")
    model_strength = options.pop("modelStrength", 1.0)
    if (isinstance(model_strength, bool)
            or not isinstance(model_strength, (int, float))
            or not math.isfinite(model_strength)
            or not 0 <= model_strength <= 1):
        raise ValueError("modelStrength must be a number in [0, 1]")
    if use_model:
        # hdrStrength is the mathematical-mode control. In model mode it is
        # only the plumbing slot used by the external-gain renderer.
        options["hdrStrength"] = model_strength
        if preview:
            options["external_gain"] = "<任务输出>/.model/model-gain.f32"
            options["external_gain_report"] = "<任务输出>/.model/model-gain.json"
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
        "nativeOutputPicker": IS_WINDOWS,
        "secureContextExpected": context.secure_context_expected,
        "transportSecure": context.secure_context_expected,
        "hdrPreviewRequiresSecureContext": True,
        "previewMaxEdge": MAX_EDGE,
        "maxUploadMB": session.MAX_UPLOAD_BYTES // (1024 * 1024),
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
    try:
        use_model = options.pop("useModel", False)
        if not isinstance(use_model, bool):
            raise ValueError("useModel must be a boolean")
        if use_model:
            strength = options.get("modelStrength", 1.0)
            if (isinstance(strength, bool) or not isinstance(strength, (int, float))
                    or not math.isfinite(strength) or not 0 <= strength <= 1):
                raise ValueError("modelStrength must be a number in [0, 1]")
            options["hdrStrength"] = strength
            model_dir = session.session_dir(
                _first(query, "id"), "output") / ".model-preview"
            options["external_gain"] = model_dir / "model-gain.f32"
            options["external_gain_report"] = model_dir / "model-gain.json"
        options["highlightRecovery"] = highlight_recovery
        provider_argument = options if thumbnail_for is preview_for else highlight_recovery
        generated = thumbnail_for(
            session.input_path(_first(query, "id")), provider_argument, requested_edge)
        if len(generated) == 3:  # pre-v1 injected test provider
            data, dimensions, mime = generated
            return Response(body=data, content_type=mime, headers={
                "X-Preview-Width": str(dimensions[0]),
                "X-Preview-Height": str(dimensions[1]),
                "X-Preview-Max-Edge": str(requested_edge),
            })
        data, metadata = generated
    except Busy as exc:
        # Distinct from a missing or broken image: the request was refused, not
        # answered, and a client may retry it.
        return error(exc, status=exc.status)
    except (OSError, ValueError) as exc:
        return error(exc, status=404)
    return Response(body=data, content_type="application/vnd.hyperdr.preview", headers={
        "X-Preview-Width": str(metadata["width"]),
        "X-Preview-Height": str(metadata["height"]),
        "X-Preview-Max-Edge": str(requested_edge),
        "X-Preview-Status": str(metadata.get("status", "error")),
        "X-Preview-Degradation-Reasons": ",".join(
            metadata.get("degradationReasons") or []),
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


def model_preview(_context: Context, body: dict) -> Response:
    """Generate the spatial model gain only after the user requests it."""
    try:
        session_id = str(body.get("sessionId") or "")
        source = session.input_path(session_id)
        highlight_recovery = str(
            body.get("highlightRecovery") or DEFAULT_HIGHLIGHT_RECOVERY
        )
        if highlight_recovery not in _HIGHLIGHT_RECOVERY_CHOICES:
            raise ValueError("unknown highlight recovery: %s" % highlight_recovery)
        exe = detect_exe()
        if not exe:
            raise ValueError("找不到 HyperDR 可执行文件。")
        config = model.load_config()
        if config is None:
            raise ValueError("模型尚未启用。")
        model_dir = session.session_dir(session_id, "output") / ".model-preview"
        gain, report = model.infer_preview(
            config, source, model_dir, exe, highlight_recovery
        )
        width, height = report["gain_grid_size"]
        return Response(
            body=gain,
            content_type="application/octet-stream",
            headers={
                "X-Gain-Width": str(width),
                "X-Gain-Height": str(height),
                "X-Gain-Max-Stops": str(report["metadata_gain_max_stops"]),
            },
        )
    except (OSError, ValueError, RuntimeError) as exc:
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
        options, use_model = _prepare_model_options(body.get("options"))
        options["input"] = str(source)
        options["output"] = str(output)
        options["report"] = str(output / ("hyperdr-report-%s.json" % secrets.token_hex(8)))
        model_commands = []
        model_config = model.load_config() if use_model else None
        if model_config is not None:
            model_dir = output / ".model"
            model_commands, gain_path, gain_report = model.build_commands(
                model_config, source, model_dir, exe,
                str(options.get("highlightRecovery") or DEFAULT_HIGHLIGHT_RECOVERY),
            )
            options["external_gain"] = str(gain_path)
            options["external_gain_report"] = str(gain_report)
        argv = build_argv(exe, options)
    except REQUEST_ERRORS as exc:
        return error(exc)

    try:
        job_id = job.start(argv, str(REPO_ROOT), options["report"], session_id,
                           pre_commands=model_commands)
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


def upload_is_allowed(_session_id: str):
    """Reserve upload admission until the replacement has been published."""
    return job.upload_slot()


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
    "/api/model-preview": model_preview,
    "/api/cancel": cancel,
}
