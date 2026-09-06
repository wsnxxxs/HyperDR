"""Immutable, session-owned creative LUT files shared by preview and export."""
from __future__ import annotations

import hashlib
import re
from pathlib import Path
from . import session

MAX_LUT_BYTES = 64 * 1024 * 1024


def save(session_id: str, name: str, stream, length: int) -> dict:
    if Path(name).suffix.lower() != ".cube":
        raise ValueError("请选择 .cube 颜色 LUT。")
    if not 0 < length <= MAX_LUT_BYTES:
        raise ValueError("LUT 文件须小于 64 MB。")
    directory = session.session_root(session_id) / "luts"
    data = stream.read(length)
    if len(data) != length:
        raise ValueError("LUT 上传未完成。")
    text = data.decode("utf-8-sig")
    if not re.search(r"^\s*LUT_[13]D_SIZE\s+\d+", text, re.MULTILINE):
        raise ValueError("未找到 .cube LUT 尺寸；RAW 线性化 LUT 不能用于照片调色。")
    digest = hashlib.sha256(data).hexdigest()
    directory.mkdir(exist_ok=True)
    target = directory / (digest + ".cube")
    if not target.exists():
        target.write_bytes(data)
    return {"lutId": digest, "lutName": Path(name.replace("\\", "/")).name[:160]}


def resolve(options: dict, session_id: str) -> None:
    # A client sends an asset ID, never a local filesystem path.
    options.pop("_lut_path", None)
    digest = options.get("lutId")
    if not digest:
        return
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("LUT 标识无效。")
    target = session.session_root(session_id) / "luts" / (digest + ".cube")
    if not target.is_file():
        raise ValueError("此照片的 LUT 已过期，请重新导入。")
    options["_lut_path"] = str(target)
