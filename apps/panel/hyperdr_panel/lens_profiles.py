"""Find RAW lens correction profiles installed by Lightroom and Camera Raw."""
from __future__ import annotations

import functools
import hashlib
import json
import subprocess
import os
import struct
import threading
import xml.etree.ElementTree as ET
from pathlib import Path

from . import session
from .formats import RAW_INPUT_EXTENSIONS
from .executable import detect_exe
from .raw_profiles import camera_key

CAMERA_NS = "{http://ns.adobe.com/photoshop/1.0/camera-profile}"
_discovery_lock = threading.Lock()


def roots():
    adobe = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Adobe"
    candidates = sorted(adobe.glob("*Lightroom*/Resources/LensProfiles"))
    for variable in ("PROGRAMDATA", "APPDATA", "LOCALAPPDATA"):
        if os.environ.get(variable):
            candidates.append(Path(os.environ[variable]) / "Adobe/CameraRaw/LensProfiles")
    candidates.extend(Path("/Applications").glob("Adobe Lightroom*/Adobe Lightroom*.app/Contents/Resources/LensProfiles"))
    candidates.extend([Path("/Library/Application Support/Adobe/CameraRaw/LensProfiles"),
                       Path.home() / "Library/Application Support/Adobe/CameraRaw/LensProfiles"])
    return candidates


def _tiff_metadata(source):
    """Read standard TIFF/EXIF fields, without interpreting vendor lens IDs."""
    result = {"make": "", "model": "", "lens": "", "focalLength": 0, "aperture": 0}
    try:
        with Path(source).open("rb") as stream:
            header = stream.read(8)
            if len(header) != 8 or header[:2] not in (b"II", b"MM"):
                return result
            endian = "<" if header[:2] == b"II" else ">"
            magic, offset = struct.unpack(endian + "HI", header[2:])
            if magic != 42:
                return result
            pending, seen = [offset], set()
            while pending and len(seen) < 16:
                offset = pending.pop()
                if offset in seen:
                    continue
                seen.add(offset)
                stream.seek(offset)
                count = struct.unpack(endian + "H", stream.read(2))[0]
                if count > 4096:
                    continue
                entries = stream.read(count * 12)
                for index in range(count):
                    entry = entries[index * 12:(index + 1) * 12]
                    tag, kind, size = struct.unpack(endian + "HHI", entry[:8])
                    if tag in (330, 34665) and kind == 4 and size == 1:
                        pending.append(struct.unpack(endian + "I", entry[8:])[0])
                    key = {271: "make", 272: "model", 42036: "lens", 37386: "focalLength", 33437: "aperture"}.get(tag)
                    if not key or size < 1 or size > 4096:
                        continue
                    if kind == 2:
                        if size <= 4:
                            data = entry[8:8 + size]
                        else:
                            stream.seek(struct.unpack(endian + "I", entry[8:])[0])
                            data = stream.read(size)
                        result[key] = data.rstrip(b"\0").decode("utf-8", errors="replace").strip()
                    elif kind == 5 and size == 1:
                        stream.seek(struct.unpack(endian + "I", entry[8:])[0])
                        numerator, denominator = struct.unpack(endian + "II", stream.read(8))
                        result[key] = numerator / denominator if denominator else 0
    except (OSError, ValueError, struct.error):
        pass
    return result


def source_metadata(source):
    executable = detect_exe()
    if executable:
        try:
            completed = subprocess.run([executable, "raw-metadata", str(source)],
                                       capture_output=True, timeout=30, check=True)
            metadata = json.loads(completed.stdout)
            if isinstance(metadata, dict) and metadata.get("make"):
                return metadata
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
    return _tiff_metadata(source)


@functools.lru_cache(maxsize=8192)
def _read_profile(path, mtime_ns, size):
    del mtime_ns, size  # Included in the cache key so edited installations refresh.
    root = ET.parse(path).getroot()
    fields = {}
    for element in root.iter():
        for name, value in element.attrib.items():
            if name.startswith(CAMERA_NS):
                fields.setdefault(name[len(CAMERA_NS):], value)
        if element.tag.startswith(CAMERA_NS) and element.text and element.text.strip():
            fields.setdefault(element.tag[len(CAMERA_NS):], element.text.strip())
    fields["_supported"] = False
    parents = {child: parent for parent in root.iter() for child in parent}
    for element in root.iter(CAMERA_NS + "PerspectiveModel"):
        record = parents.get(element)
        values = {}
        for node in element.iter():
            values.update({name[len(CAMERA_NS):]: value for name, value in node.attrib.items()
                           if name.startswith(CAMERA_NS)})
        try:
            explicit = float(values.get("FocalLengthX", 0)) > 0 and float(values.get("FocalLengthY", 0)) > 0
            inferred = (record is not None and float(record.get(CAMERA_NS + "FocalLength", 0)) > 0
                        and float(record.get(CAMERA_NS + "SensorFormatFactor", 0)) > 0)
            if values.get("Version") == "2" and (explicit or inferred):
                fields["_supported"] = True
        except ValueError:
            pass
    return fields


def _lens_keys(value, make):
    key = camera_key(value)
    keys = {key} if key else set()
    maker = camera_key(make)
    if maker and key.startswith(maker) and len(key) > len(maker):
        keys.add(key[len(maker):])
    return keys


def match_profile(metadata, fields):
    if fields.get("CameraRawProfile", "").casefold() != "true":
        return False
    make = camera_key(metadata.get("make", ""))
    profile_make = camera_key(fields.get("Make", ""))
    if not make or make != profile_make:
        return False
    model = camera_key(fields.get("Model", ""))
    source_model = camera_key(metadata.get("model", ""))
    if model and model != make and model not in (source_model, make + source_model):
        return False
    keys = _lens_keys(metadata.get("lens", ""), metadata.get("make", ""))
    return bool(keys and any(keys & _lens_keys(fields.get(name, ""), fields.get("Make", ""))
                             for name in ("Lens", "LensPrettyName")))


def discover(session_id):
    source = session.input_path(session_id)
    stat = source.stat()
    # The profile list and first preview are requested together on photo open.
    # Share their discovery and publish the session copy before either decodes.
    with _discovery_lock:
        return dict(_discover(session_id, str(source), stat.st_mtime_ns, stat.st_size))


@functools.lru_cache(maxsize=64)
def _discover(session_id, source_path, mtime_ns, size):
    del mtime_ns, size
    source = Path(source_path)
    is_raw = source.suffix.lower() in RAW_INPUT_EXTENSIONS
    metadata = source_metadata(source) if is_raw else {}
    result = {"isRaw": is_raw, "camera": " ".join(filter(None, [metadata.get("make"), metadata.get("model")])),
              "lens": metadata.get("lens", ""), "available": False, "profileName": "", "profilePath": ""}
    if not is_raw or not metadata.get("lens") or not metadata.get("focalLength", 0) > 0:
        return result
    matches = []
    for directory in roots():
        if not directory.is_dir():
            continue
        for path in directory.rglob("*.lcp"):
            try:
                stat = path.stat()
                fields = _read_profile(str(path), stat.st_mtime_ns, stat.st_size)
                if fields.get("_supported") and match_profile(metadata, fields):
                    # Prefer camera-specific profiles to generic mount profiles.
                    specific = camera_key(fields.get("Model", "")) not in ("", camera_key(fields.get("Make", "")))
                    matches.append((not specific, str(path), fields))
            except (OSError, ET.ParseError, ValueError):
                continue
    if matches:
        _, path, fields = min(matches, key=lambda item: (item[0], item[1]))
        data = Path(path).read_bytes()
        directory = session.session_root(session_id) / "lens-profiles"
        directory.mkdir(exist_ok=True)
        target = directory / (hashlib.sha256(data).hexdigest() + ".lcp")
        if not target.exists():
            target.write_bytes(data)
        result.update(available=True, profileName=fields.get("ProfileName") or Path(path).stem, profilePath=str(target))
    return result


def resolve(options, session_id):
    options.pop("_lens_profile_path", None)
    if not options.get("lensCorrection", True):
        return
    profile = discover(session_id)
    if profile["isRaw"] and profile["available"]:
        options["_lens_profile_path"] = profile["profilePath"]
