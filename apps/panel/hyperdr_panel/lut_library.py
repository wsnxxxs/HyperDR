"""Reusable local LUTs; photo sessions retain their own immutable copies."""
from __future__ import annotations

import json
import re
import shutil
import threading

from . import session

_lock = threading.RLock()
_spaces = {"srgb", "p3", "rec709", "hlg", "pq", "slog3-sgamut3cine"}


def _root():
    # This name is outside the session ID namespace and its expiry cleanup.
    root = session.WORK_ROOT / "lut-library"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _path(digest, suffix):
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("LUT 标识无效。")
    return _root() / (digest + suffix)


def _write(entry):
    target = _path(entry["lutId"], ".json")
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(entry, ensure_ascii=False), encoding="utf-8")
    temporary.replace(target)


def add(session_id, saved):
    with _lock:
        target = _path(saved["lutId"], ".cube")
        if not target.exists():
            shutil.copyfile(session.session_root(session_id) / "luts" / target.name, target)
        metadata = target.with_suffix(".json")
        if metadata.exists():
            return json.loads(metadata.read_text(encoding="utf-8"))
        entry = dict(saved, lutInput="srgb", lutOutput="srgb")
        _write(entry)
        return entry


def entries():
    with _lock:
        result = [json.loads(path.read_text(encoding="utf-8"))
                  for path in _root().glob("*.json") if path.with_suffix(".cube").is_file()]
        return sorted(result, key=lambda entry: entry["lutName"].casefold())


def apply(session_id, digest):
    with _lock:
        source = _path(digest, ".cube")
        entry = json.loads(source.with_suffix(".json").read_text(encoding="utf-8"))
        directory = session.session_root(session_id) / "luts"
        directory.mkdir(exist_ok=True)
        target = directory / source.name
        if not target.exists():
            shutil.copyfile(source, target)
        return entry


def update(digest, options):
    with _lock:
        entry = json.loads(_path(digest, ".json").read_text(encoding="utf-8"))
        for key in ("lutInput", "lutOutput"):
            if options.get(key) not in _spaces:
                raise ValueError("请选择 LUT 的输入和输出空间。")
            entry[key] = options[key]
        _write(entry)
        return entry


def remove(digest):
    with _lock:
        _path(digest, ".json").unlink(missing_ok=True)
        _path(digest, ".cube").unlink(missing_ok=True)
