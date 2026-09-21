"""Desktop export-folder preference and safe result copies."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import uuid
from pathlib import Path

from . import renditions, session

_LOCK = threading.Lock()
_COPY_LOCK = threading.Lock()

# Per-save destinations let the result's "open folder" action target the folder
# for that save without returning its path to the browser. The map is process
# local and bounded; preference UI opens the separately remembered folder.
_OPEN_TARGETS: dict[str, Path] = {}
_OPEN_TARGETS_LIMIT = 128


def _settings_file() -> Path:
    if os.name == "nt":
        root = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "HyperDR" / "export-folder.json"


def selected_folder() -> Path | None:
    try:
        data = json.loads(_settings_file().read_text(encoding="utf-8"))
        raw = data.get("path") if isinstance(data, dict) else None
        path = Path(raw) if isinstance(raw, str) else None
        return path if path and path.is_absolute() else None
    except (OSError, ValueError, TypeError):
        return None


def folder_label(path: Path | None) -> str:
    """A short, displayable form of a folder, without returning its full path."""
    if path is None:
        return ""
    parts = path.parts
    visible_parts = parts[1:] if path.anchor else parts
    if not visible_parts:
        drive = path.drive
        return drive if drive and not drive.startswith(os.sep * 2) else "…"
    return f"…{os.sep}{os.sep.join(visible_parts[-2:])}"


def info() -> dict[str, object]:
    path = selected_folder()
    # `ready` is the signal the UI gates on. A label is for reading, and no
    # label is short enough to be trusted as "nothing is configured".
    return {"label": folder_label(path), "ready": bool(path and path.is_dir())}


def _checked_folder(raw_path: object) -> Path:
    """Resolve a folder, refusing everything a save must never write into."""
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise ValueError("请选择一个保存文件夹。")
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        raise ValueError("保存文件夹路径必须是绝对路径。")
    try:
        candidate = candidate.resolve(strict=True)
    except OSError as exc:
        raise ValueError("保存文件夹不存在或无法访问。") from exc
    if not candidate.is_dir():
        raise ValueError("保存位置不是文件夹。")
    try:
        candidate.relative_to(session.WORK_ROOT.resolve())
    except ValueError:
        return candidate
    raise ValueError("保存文件夹不能位于 HyperDR 工作区内。")


def validate_folder(raw_path: object) -> Path:
    """`_checked_folder`, plus a write probe, for the moment a folder is chosen.

    Worth one created file when the person picks the folder, where a clear
    "not writable" beats discovering it at the next export. Not worth one on
    every save: that churns a synced or watched directory, and the exclusive
    creation the copy already does reports the same failure.
    """
    candidate = _checked_folder(raw_path)
    probe = candidate / f".hyperdr-write-check-{uuid.uuid4().hex}"
    try:
        with probe.open("xb"):
            pass
    except OSError as exc:
        raise ValueError("保存文件夹不可写。") from exc
    finally:
        probe.unlink(missing_ok=True)
    return candidate


def set_folder(raw_path: object) -> str:
    path = validate_folder(raw_path)
    target = _settings_file()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.tmp")
    with _LOCK:
        try:
            temporary.write_text(json.dumps({"path": str(path)}), encoding="utf-8")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return folder_label(path)


def _unused_path(folder: Path, filename: str) -> Path:
    name = Path(filename)
    stem, suffix = name.stem, name.suffix
    candidate = folder / filename
    index = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = folder / f"{stem} ({index}){suffix}"
        index += 1
    return candidate


def save_result(session_id: str, export_id: str,
                once: object = None) -> dict[str, str]:
    """Copy one rendition out of the workspace.

    ``once`` is a folder for this save alone -- what "ask every time" chose. It
    is checked exactly like the remembered one and is deliberately not written
    to the settings file, so asking each time cannot quietly redefine the
    fixed-folder preference.
    """
    source = renditions.result_path(session_id, export_id)
    if isinstance(once, str) and once.strip():
        folder = _checked_folder(once)
    else:
        configured = selected_folder()
        if configured is None:
            raise ValueError("请先选择保存文件夹。")
        folder = _checked_folder(str(configured))

    # Exclusive creation protects existing photos and handles a name claimed by
    # another writer between the free-name check and the copy.
    with _COPY_LOCK:
        while True:
            target = _unused_path(folder, source.name)
            try:
                destination = target.open("xb")
                break
            except FileExistsError:
                continue
        try:
            with source.open("rb") as original, destination:
                shutil.copyfileobj(original, destination, length=1024 * 1024)
                destination.flush()
                os.fsync(destination.fileno())
        except BaseException:
            target.unlink(missing_ok=True)
            raise
    open_token = uuid.uuid4().hex
    with _LOCK:
        _OPEN_TARGETS[open_token] = folder
        while len(_OPEN_TARGETS) > _OPEN_TARGETS_LIMIT:
            _OPEN_TARGETS.pop(next(iter(_OPEN_TARGETS)))
    return {"name": target.name, "folderLabel": folder_label(folder),
            "openToken": open_token}


def open_folder(open_token: object = None) -> None:
    """Open one save's destination, or the remembered folder for Preferences."""
    if open_token is None or open_token == "":
        chosen = selected_folder()
    else:
        if not isinstance(open_token, str):
            raise ValueError("保存位置已失效，请重新保存。")
        with _LOCK:
            chosen = _OPEN_TARGETS.get(open_token)
        if chosen is None:
            raise ValueError("保存位置已失效，请重新保存。")
    if chosen is None:
        raise ValueError("请先选择保存文件夹。")
    folder = _checked_folder(str(chosen))
    if os.name == "nt":
        os.startfile(str(folder))  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(folder)])
    else:
        subprocess.Popen(["xdg-open", str(folder)])
