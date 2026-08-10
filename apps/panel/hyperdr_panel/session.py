"""One session, one image.

The panel converts a single photograph at a time, so a session holds exactly one
input and produces exactly one output. That is what lets this module be a
handful of path lookups: the previous multi-file version had to track the
running byte total of a directory that grew with every upload *and* with
whatever the converter wrote into a nested output tree, which took a usage
cache, a directory mtime stamp, a per-session lock and an explicit invalidation
hook that `jobs.py` had to remember to call.

Uploading replaces the current input rather than adding to it, matching the
interface, where tapping the preview swaps the photograph.

The browser never supplies a filesystem path. It receives an opaque session id
and every path in here is derived from it and re-checked against the workspace
root, so a crafted id cannot address anything outside.
"""
from __future__ import annotations

import os
import re
import shutil
import time
import uuid
from pathlib import Path

from .config import REPO_ROOT
from .thumbnail import SUPPORTED_EXTENSIONS

WORK_ROOT = Path(os.environ.get("HYPERDR_WORK_ROOT", REPO_ROOT / "hdr-workspace")).resolve()
MAX_UPLOAD_BYTES = int(os.environ.get("HYPERDR_MAX_UPLOAD_MB", "256")) * 1024 * 1024
SESSION_TTL_SECONDS = int(os.environ.get("HYPERDR_SESSION_HOURS", "24")) * 3600

RESULT_EXTENSIONS = frozenset({".avif", ".heic", ".jpg", ".jpeg"})

_SESSION_RE = re.compile(r"^[0-9a-f]{32}$")


# --- paths ----------------------------------------------------------------- #

def create_session() -> str:
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    session_id = uuid.uuid4().hex
    for name in ("input", "output"):
        (WORK_ROOT / session_id / name).mkdir(parents=True, exist_ok=False)
    return session_id


def session_root(session_id: str) -> Path:
    if not _SESSION_RE.fullmatch(session_id or ""):
        raise ValueError("invalid session id")
    root = (WORK_ROOT / session_id).resolve()
    # Re-checked after resolution: a symlinked session directory must not be
    # able to address anything outside the workspace.
    root.relative_to(WORK_ROOT)
    if not root.is_dir():
        raise FileNotFoundError("任务不存在或已过期。")
    os.utime(root, None)  # Touched on use, so cleanup measures idle time.
    return root


def session_dir(session_id: str, kind: str) -> Path:
    if kind not in {"input", "output"}:
        raise ValueError("invalid session directory")
    return session_root(session_id) / kind


# --- upload ---------------------------------------------------------------- #

def _safe_filename(value: str) -> str:
    name = Path(value.replace("\\", "/")).name.strip().rstrip(". ")
    if not name or name in {".", ".."}:
        raise ValueError("文件名无效。")
    suffix = Path(name).suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError("不支持此格式；请选择 ARW、DNG、JPEG、PNG、HEIC、HEIF 或 AVIF。")
    stem = re.sub(r"[^\w\-. ()\u4e00-\u9fff]", "_", Path(name).stem, flags=re.UNICODE)
    stem = stem[:120].strip(". ") or "image"
    return stem + suffix


def _matches_declared_format(path: Path) -> bool:
    """Guard against a renamed file: the header must match the extension."""
    header = path.read_bytes()[:32]
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}:
        return header.startswith(b"\xff\xd8")
    if suffix == ".png":
        return header.startswith(b"\x89PNG\r\n\x1a\n")
    if suffix in {".heic", ".heif", ".avif"}:
        # All three are ISO base media containers; which codec sits inside is
        # the decoder's business, not this guard's.
        return len(header) >= 12 and header[4:8] == b"ftyp"
    if suffix in {".arw", ".dng"}:
        return header.startswith((b"II*\x00", b"MM\x00*"))
    return False


def save_upload(session_id: str, filename: str, stream, length: int) -> tuple[Path, int]:
    """Stream one image in, replacing whatever the session held before.

    Written to a dotted temporary name and renamed into place, so a connection
    that drops halfway cannot leave a truncated file that the converter would
    then try to decode.
    """
    if length <= 0:
        raise ValueError("上传内容为空。")
    if length > MAX_UPLOAD_BYTES:
        raise ValueError("文件超过上传大小限制。")

    root = session_root(session_id)
    inputs = root / "input"
    safe_name = _safe_filename(filename)
    temporary = inputs / f".{uuid.uuid4().hex}{Path(safe_name).suffix}"
    try:
        remaining = length
        with temporary.open("xb") as output:
            while remaining:
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError("上传在完成前中断。")
                output.write(chunk)
                remaining -= len(chunk)
        if not _matches_declared_format(temporary):
            raise ValueError("文件内容与扩展名不匹配。")
        # One image per session: the previous one goes only once the new one is
        # known to be complete and well-formed.
        for existing in inputs.iterdir():
            if existing.is_file() and existing != temporary:
                existing.unlink(missing_ok=True)
        target = inputs / safe_name
        temporary.replace(target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    os.utime(root, None)
    return target, length


def input_path(session_id: str) -> Path:
    """The session's image, or FileNotFoundError if nothing was uploaded."""
    for item in sorted(session_dir(session_id, "input").iterdir()):
        if item.is_file() and item.suffix.lower() in SUPPORTED_EXTENSIONS:
            return item
    raise FileNotFoundError("尚未上传图片。")


# --- results --------------------------------------------------------------- #

def clear_output(session_id: str) -> int:
    """Empty the output directory before a run.

    Without this, changing the encoding from HEIC to AVIF left the previous
    run's file in place under its old extension and `result_path` could return
    the wrong one. Dotted entries are left alone: the converter keeps its own
    bookkeeping there and it is keyed on the input, not on the run.
    """
    folder = session_dir(session_id, "output")
    removed = 0
    # Deepest first, so a directory is only removed once it is empty.
    for item in sorted(folder.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if any(part.startswith(".") for part in item.relative_to(folder).parts):
            continue
        try:
            if item.is_file() or item.is_symlink():
                item.unlink()
                removed += 1
            elif item.is_dir():
                item.rmdir()
        except OSError:
            continue
    return removed


def result_path(session_id: str) -> Path:
    """The converted image, or FileNotFoundError if this run produced none.

    Model inference keeps its thumbnails and gain-grid files in dotted
    subdirectories of ``output``.  Those are intermediate artifacts, not
    downloadable results, so only a file directly under ``output`` can be the
    converted image.
    """
    folder = session_dir(session_id, "output")
    for item in sorted(folder.iterdir(), key=lambda p: str(p).lower()):
        if item.is_file() and item.suffix.lower() in RESULT_EXTENSIONS:
            target = item.resolve()
            target.relative_to(folder.resolve())
            return target
    raise FileNotFoundError("结果文件不存在。")


# --- cleanup --------------------------------------------------------------- #

def cleanup_expired_sessions(now: float | None = None,
                             protected_session_ids: set[str] | None = None) -> int:
    """Remove idle sessions, never one a conversion is still using."""
    if not WORK_ROOT.exists():
        return 0
    cutoff = (now if now is not None else time.time()) - SESSION_TTL_SECONDS
    protected = protected_session_ids or set()
    removed = 0
    for item in WORK_ROOT.iterdir():
        if (not item.is_dir() or not _SESSION_RE.fullmatch(item.name)
                or item.name in protected):
            continue
        try:
            if item.stat().st_mtime < cutoff:
                shutil.rmtree(item)
                removed += 1
        except OSError:
            continue
    return removed
