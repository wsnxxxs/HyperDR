"""Discover local camera profiles and keep content-addressed session copies."""
from __future__ import annotations

import hashlib
import io
import os
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

from . import session
from .formats import RAW_INPUT_EXTENSIONS

MAX_PROFILE_BYTES = 32 * 1024 * 1024
_CRS = "{http://ns.adobe.com/camera-raw-settings/1.0/}"
_RDF = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"


def look_roots():
    adobe = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Adobe"
    candidates = sorted(adobe.glob("*Lightroom*/Resources/Settings/Adobe/Profiles/Adobe Raw"))
    if os.environ.get("APPDATA"):
        candidates.append(Path(os.environ["APPDATA"]) / "Adobe/CameraRaw/Settings")
    return candidates


def look_metadata(data):
    """Only advertise static color looks; native decoding is authoritative."""
    if len(data) > MAX_PROFILE_BYTES or b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise ValueError("XMP 外观文件无效。")
    root = ET.fromstring(data)
    desc = root.find(".//" + _RDF + "Description")
    if desc is None:
        raise ValueError("XMP 缺少外观描述。")
    def get(name):
        return desc.get(_CRS + name) or desc.findtext(_CRS + name, "")
    if get("PresetType") != "Look" or not get("CameraProfile"):
        raise ValueError("请选择带相机配置的静态 XMP 外观。")
    if get("ProfileGainTableMap") or get("RGBTables") or get("ConvertToGrayscale").lower() in ("true", "1"):
        raise ValueError("暂不支持自适应、RGB 表或黑白 XMP 外观。")
    if get("SupportsSceneReferred").lower() in ("false", "0"):
        raise ValueError("XMP 外观不支持场景参照图像。")
    allowed = {"PresetType", "Cluster", "UUID", "SupportsAmount", "SupportsColor", "SupportsMonochrome",
               "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred",
               "CameraModelRestriction", "Copyright", "ContactInfo", "Version", "ProcessVersion", "ConvertToGrayscale",
               "CameraProfile", "LookTable", "HasSettings", "Name", "ShortName", "SortName", "Group", "Description",
               "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"}
    for key in list(desc.attrib) + [child.tag for child in desc]:
        if key.startswith(_CRS):
            name = key[len(_CRS):]
            if name not in allowed and not name.startswith("Table_"):
                raise ValueError("XMP 外观包含暂不支持的处理：" + name)
    for channel in ("Red", "Green", "Blue"):
        for point in desc.findall(_CRS + "ToneCurvePV2012" + channel + "/" + _RDF + "Seq/" + _RDF + "li"):
            values = [float(value.strip()) for value in (point.text or "").split(",")]
            if len(values) != 2 or values[0] != values[1]:
                raise ValueError("暂不支持独立颜色通道曲线。")
    table = get("LookTable")
    if table and not get("Table_" + table):
        raise ValueError("XMP 外观缺少内嵌颜色表。")
    if not table and desc.find(_CRS + "ToneCurvePV2012") is None:
        raise ValueError("XMP 外观缺少支持的颜色表或曲线。")
    name = desc.findtext(_CRS + "Name/" + _RDF + "Alt/" + _RDF + "li", "")
    return {"rawLookName": name or "XMP", "requiredProfile": get("CameraProfile")}


def discover_looks(session_id, profiles):
    names = {entry["rawProfileName"] for entry in profiles}
    found = {}
    for root in look_roots():
        if not root.is_dir():
            continue
        for path in root.rglob("*.xmp"):
            try:
                if path.stat().st_size > MAX_PROFILE_BYTES:
                    continue
                data = path.read_bytes()
                entry = look_metadata(data)
                if entry["requiredProfile"] not in names:
                    continue
                digest = hashlib.sha256(data).hexdigest()
                directory = session.session_root(session_id) / "raw-looks"
                directory.mkdir(exist_ok=True)
                target = directory / (digest + ".xmp")
                if not target.exists():
                    target.write_bytes(data)
                found[digest] = {"rawLook": digest, **entry}
            except (OSError, ValueError, ET.ParseError):
                continue
    return sorted(found.values(), key=lambda entry: entry["rawLookName"].casefold())


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
    adobe = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Adobe"
    candidates = sorted(adobe.glob("*Lightroom*/Resources/CameraProfiles"))
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
    preferred = {"adobe standard": 0, "camera st": 1}
    entries.sort(key=lambda entry: (preferred.get(entry["rawProfileName"].casefold(), 2),
                                    entry["rawProfileName"].casefold()))
    result = {"isRaw": is_raw, "camera": camera, "entries": entries}
    if is_raw:
        result["looks"] = discover_looks(session_id, entries)
    return result


def resolve(options, session_id):
    options.pop("_raw_profile_path", None)
    options.pop("_raw_look_path", None)
    digest = options.get("rawProfile")
    if not digest:
        if options.get("rawLook"):
            raise ValueError("XMP 外观需要对应的 DCP 相机配置。")
        return
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("DCP 标识无效。")
    target = session.session_root(session_id) / "raw-profiles" / (digest + ".dcp")
    if not target.is_file():
        raise ValueError("此照片的 DCP 已过期，请重新选择。")
    if session.input_path(session_id).suffix.lower() not in RAW_INPUT_EXTENSIONS:
        raise ValueError("DCP 相机配置仅适用于 RAW 照片。")
    options["_raw_profile_path"] = str(target)
    look = options.get("rawLook")
    if look:
        if not isinstance(look, str) or not re.fullmatch(r"[0-9a-f]{64}", look):
            raise ValueError("XMP 外观标识无效。")
        look_path = session.session_root(session_id) / "raw-looks" / (look + ".xmp")
        if not look_path.is_file():
            raise ValueError("此照片的 XMP 外观已过期，请重新选择。")
        metadata = look_metadata(look_path.read_bytes())
        with target.open("rb") as stream:
            profile = tiff_strings(stream, {50936})
        if metadata["requiredProfile"] != profile.get(50936):
            raise ValueError("XMP 外观需要相机配置：" + metadata["requiredProfile"])
        options["_raw_look_path"] = str(look_path)
