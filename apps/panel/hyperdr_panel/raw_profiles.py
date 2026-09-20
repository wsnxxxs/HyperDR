"""Discover local camera profiles and keep content-addressed session copies."""
from __future__ import annotations

import hashlib
import io
import os
import re
import struct
from pathlib import Path

from . import session
from .formats import RAW_INPUT_EXTENSIONS

MAX_PROFILE_BYTES = 32 * 1024 * 1024


def tiff_strings(stream, tags):
    """Read only small ASCII fields in the first classic TIFF/DCP IFD."""
    header = stream.read(8)
    if len(header) != 8 or header[:2] not in (b"II", b"MM"):
        raise ValueError("无法读取 TIFF/DCP 文件头。")
    endian = "<" if header[:2] == b"II" else ">"
    magic, offset = struct.unpack(endian + "HI", header[2:])
    if magic not in (42, 0x4352) or offset < 8:
        raise ValueError("不支持的 TIFF/DCP 文件头。")
    stream.seek(offset)
    count_bytes = stream.read(2)
    if len(count_bytes) != 2:
        raise ValueError("DCP 目录不完整。")
    count = struct.unpack(endian + "H", count_bytes)[0]
    if count > 4096:
        raise ValueError("DCP 目录过大。")
    result = {}
    for _ in range(count):
        entry = stream.read(12)
        if len(entry) != 12:
            raise ValueError("DCP 目录不完整。")
        tag, kind, size = struct.unpack(endian + "HHI", entry[:8])
        if tag not in tags or kind != 2 or not 0 < size <= 4096:
            continue
        resume = stream.tell()
        if size <= 4:
            value = entry[8:8 + size]
        else:
            stream.seek(struct.unpack(endian + "I", entry[8:])[0])
            value = stream.read(size)
            stream.seek(resume)
        if len(value) != size:
            raise ValueError("DCP 文本不完整。")
        result[tag] = value.rstrip(b"\0").decode("utf-8", errors="replace").strip()
    return result


def camera_key(value):
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def source_camera(source):
    try:
        with source.open("rb") as stream:
            fields = tiff_strings(stream, {271, 272})
        make, model = fields.get(271, ""), fields.get(272, "")
        if not model:
            return ""
        return model if camera_key(model).startswith(camera_key(make)) else make + " " + model
    except (OSError, ValueError):
        return ""


def save(session_id, name, stream, length):
    if Path(name).suffix.lower() != ".dcp" or not 0 < length <= MAX_PROFILE_BYTES:
        raise ValueError("请选择小于 32 MB 的 .dcp 相机配置文件。")
    source = session.input_path(session_id)
    if source.suffix.lower() not in RAW_INPUT_EXTENSIONS:
        raise ValueError("DCP 相机配置仅适用于 RAW 照片。")
    data = stream.read(length)
    if len(data) != length:
        raise ValueError("DCP 上传未完成。")
    fields = tiff_strings(io.BytesIO(data), {50708, 50936})
    camera = source_camera(source)
    profile_camera = fields.get(50708, "")
    if not profile_camera:
        raise ValueError("DCP 缺少相机型号。")
    if camera and camera_key(camera) != camera_key(profile_camera):
        raise ValueError("DCP 相机型号不匹配：%s / %s" % (profile_camera, camera))
    digest = hashlib.sha256(data).hexdigest()
    directory = session.session_root(session_id) / "raw-profiles"
    directory.mkdir(exist_ok=True)
    target = directory / (digest + ".dcp")
    if not target.exists():
        target.write_bytes(data)
    return {"rawProfile": digest, "rawProfileName": fields.get(50936) or Path(name).stem,
            "camera": profile_camera}


def roots():
    candidates = [Path(os.environ.get("ProgramFiles", "C:/Program Files")) /
                  "Adobe/Adobe Lightroom Classic/Resources/CameraProfiles"]
    for variable in ("PROGRAMDATA", "APPDATA", "LOCALAPPDATA"):
        if os.environ.get(variable):
            candidates.append(Path(os.environ[variable]) / "Adobe/CameraRaw/CameraProfiles")
    return candidates


def discover(session_id):
    source = session.input_path(session_id)
    is_raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
    camera = source_camera(source) if is_raw else ""
    entries, seen = [], set()
    if camera:
        for root in roots():
            if not root.is_dir():
                continue
            for path in root.rglob("*.dcp"):
                if not any(name in path.stem.casefold() for name in ("adobe standard", "camera st")):
                    continue
                try:
                    with path.open("rb") as stream:
                        fields = tiff_strings(stream, {50708, 50936})
                    if camera_key(fields.get(50708, "")) != camera_key(camera):
                        continue
                    with path.open("rb") as stream:
                        entry = save(session_id, path.name, stream, path.stat().st_size)
                    if entry["rawProfile"] not in seen:
                        entries.append(entry)
                        seen.add(entry["rawProfile"])
                except (OSError, ValueError):
                    continue
    return {"isRaw": is_raw, "camera": camera, "entries": entries}


def resolve(options, session_id):
    options.pop("_raw_profile_path", None)
    digest = options.get("rawProfile")
    if not digest:
        return
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("DCP 标识无效。")
    target = session.session_root(session_id) / "raw-profiles" / (digest + ".dcp")
    if not target.is_file():
        raise ValueError("此照片的 DCP 已过期，请重新选择。")
    options["_raw_profile_path"] = str(target)
