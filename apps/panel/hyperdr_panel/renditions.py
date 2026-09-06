"""Immutable exports. A completed manifest publishes a conversion atomically.

Pending and failed runs never replace a successful result. All versions live
inside the photo session and expire with it; decode caches remain independent.
"""
from __future__ import annotations

import json
import re
import shutil
import time
import uuid
from pathlib import Path

from . import session

_ID = re.compile(r"^[0-9a-f]{32}$")


def directory(session_id: str, rendition_id: str) -> Path:
    if not _ID.fullmatch(rendition_id or ""):
        raise ValueError("invalid export id")
    root = session.session_dir(session_id, "output").resolve()
    target = (root / ".exports" / rendition_id).resolve()
    target.relative_to(root)
    return target


def prepare(session_id: str, options: dict) -> tuple[str, Path]:
    rendition_id = uuid.uuid4().hex
    folder = directory(session_id, rendition_id)
    folder.mkdir(parents=True)
    try:
        pending = {"id": rendition_id, "options": options,
                   "sourceDigest": session.input_digest(session_id)}
        (folder / "pending.json").write_text(json.dumps(pending), encoding="utf-8")
    except Exception:
        discard(session_id, rendition_id)
        raise
    return rendition_id, folder


def publish(session_id: str, rendition_id: str, report: dict | None) -> dict:
    folder = directory(session_id, rendition_id)
    files = report.get("files", []) if isinstance(report, dict) else []
    successful = next((entry for entry in files if entry.get("success")), None)
    if successful is None:
        raise ValueError("转换未生成有效的成功报告。")
    # The converter owns the report, but only a direct output is publishable.
    target = Path(successful["output"]).resolve()
    if target.parent != folder or target.suffix.lower() not in session.RESULT_EXTENSIONS:
        raise ValueError("转换报告中的结果路径无效。")
    if not target.is_file() or target.stat().st_size == 0:
        raise ValueError("转换未生成结果文件。")
    pending = folder / "pending.json"
    record = json.loads(pending.read_text(encoding="utf-8"))
    record.update(name=target.name, bytes=target.stat().st_size,
                  createdAt=time.time(), report=report)
    pending.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    pending.replace(folder / "result.json")
    return record


def discard(session_id: str, rendition_id: str) -> None:
    folder = directory(session_id, rendition_id)
    if not (folder / "result.json").exists():
        shutil.rmtree(folder, ignore_errors=True)


def list_for(session_id: str) -> list[dict]:
    root = session.session_dir(session_id, "output") / ".exports"
    if not root.exists():
        return []
    digest = session.input_digest(session_id)
    records = []
    for manifest in root.glob("*/result.json"):
        try:
            record = json.loads(manifest.read_text(encoding="utf-8"))
            if record["sourceDigest"] == digest:
                result_path(session_id, record["id"])
                records.append(record)
        except (OSError, ValueError, KeyError):
            continue
    return sorted(records, key=lambda entry: entry["createdAt"], reverse=True)


def result_path(session_id: str, rendition_id: str = "") -> Path:
    if not rendition_id:
        records = list_for(session_id)
        if not records:
            return session.result_path(session_id)  # Pre-upgrade sessions.
        rendition_id = records[0]["id"]
    folder = directory(session_id, rendition_id)
    record = json.loads((folder / "result.json").read_text(encoding="utf-8"))
    target = (folder / record["name"]).resolve()
    if target.parent != folder or not target.is_file():
        raise FileNotFoundError("结果文件不存在。")
    return target
