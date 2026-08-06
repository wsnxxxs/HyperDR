"""Strict Phase A Apple/ISO gain-map label decoding.

This module deliberately keeps the wire representation (signed rationals and
flags) next to the canonical representation.  The old training pipeline used
an sRGB approximation and a normalized float16 target; those values remain
available for v1 reproduction but are never used by this module.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
import re
import struct
from pathlib import Path
from typing import Iterable

import numpy as np


class PhaseALabelError(ValueError):
    """Raised when a label is incomplete, contradictory, or unsupported."""


@dataclass(frozen=True)
class Rational:
    numerator: int
    denominator: int

    def __post_init__(self) -> None:
        if self.denominator <= 0:
            raise PhaseALabelError("rational denominator must be positive")
        if not -(2**31) <= self.numerator < 2**31:
            raise PhaseALabelError("rational numerator does not fit signed int32")

    @property
    def value(self) -> float:
        return self.numerator / self.denominator

    def as_dict(self) -> dict[str, int]:
        return {"numerator": self.numerator, "denominator": self.denominator}


@dataclass(frozen=True)
class IsoGainMapMetadata:
    minimum_version: int
    writer_version: int
    flags: int
    use_base_color_space: bool
    backward_direction: bool
    common_denominator: bool
    base_headroom: Rational
    alternate_headroom: Rational
    gain_min: Rational
    gain_max: Rational
    gamma: Rational
    base_offset: Rational
    alternate_offset: Rational

    @property
    def gain_min_value(self) -> float:
        return self.gain_min.value

    @property
    def gain_max_value(self) -> float:
        return self.gain_max.value

    @property
    def gamma_value(self) -> float:
        return self.gamma.value

    def as_dict(self) -> dict[str, object]:
        return {
            "minimum_version": self.minimum_version,
            "writer_version": self.writer_version,
            "flags": self.flags,
            "use_base_color_space": self.use_base_color_space,
            "backward_direction": self.backward_direction,
            "common_denominator": self.common_denominator,
            "base_headroom": self.base_headroom.as_dict(),
            "alternate_headroom": self.alternate_headroom.as_dict(),
            "gain_min": self.gain_min.as_dict(),
            "gain_max": self.gain_max.as_dict(),
            "gamma": self.gamma.as_dict(),
            "base_offset": self.base_offset.as_dict(),
            "alternate_offset": self.alternate_offset.as_dict(),
        }


LABEL_CONTRACT_ID = "hyperdr.apple-gain-label/v2"
LABEL_CONTRACT_VERSION = 2
FORMULA_VERSION = "phase-a-iso21496-v0-rec709-2026-08"


def _u16(data: bytes, pos: int) -> tuple[int, int]:
    if pos + 2 > len(data):
        raise PhaseALabelError("truncated tmap payload")
    return int.from_bytes(data[pos : pos + 2], "big"), pos + 2


def _u32(data: bytes, pos: int) -> tuple[int, int]:
    if pos + 4 > len(data):
        raise PhaseALabelError("truncated tmap payload")
    return int.from_bytes(data[pos : pos + 4], "big"), pos + 4


def _s32(data: bytes, pos: int) -> tuple[int, int]:
    value, pos = _u32(data, pos)
    return (value - 2**32 if value & 2**31 else value), pos


def _rational(data: bytes, pos: int, *, signed: bool = True) -> tuple[Rational, int]:
    numerator, pos = _s32(data, pos) if signed else _u32(data, pos)
    denominator, pos = _u32(data, pos)
    return Rational(numerator, denominator), pos


def _validate_metadata(metadata: IsoGainMapMetadata) -> IsoGainMapMetadata:
    if metadata.minimum_version != 0 or metadata.writer_version != 0:
        raise PhaseALabelError("only ISO 21496-1 v0 writer metadata is supported")
    if metadata.flags & 0x80:
        raise PhaseALabelError("multichannel gain maps are not supported in Phase A")
    if metadata.backward_direction:
        raise PhaseALabelError("backward-direction gain maps are not supported in Phase A")
    if metadata.flags & ~(0x80 | 0x40 | 0x08 | 0x04):
        raise PhaseALabelError("reserved gain-map flags are set")
    values = (
        metadata.base_headroom.value,
        metadata.alternate_headroom.value,
        metadata.gain_min.value,
        metadata.gain_max.value,
        metadata.gamma.value,
        metadata.base_offset.value,
        metadata.alternate_offset.value,
    )
    if not all(math.isfinite(value) for value in values):
        raise PhaseALabelError("non-finite gain-map metadata")
    if metadata.base_headroom.value < 0 or metadata.alternate_headroom.value < 0:
        raise PhaseALabelError("negative HDR headroom")
    if metadata.gain_max.value < metadata.gain_min.value:
        raise PhaseALabelError("gain_max is smaller than gain_min")
    if abs(metadata.gain_max.value - metadata.alternate_headroom.value) > 1.0e-6:
        raise PhaseALabelError("gain_max conflicts with alternate headroom")
    if abs(metadata.gain_min.value) > 64 or abs(metadata.gain_max.value) > 64:
        raise PhaseALabelError("gain range is outside the Phase A safety bound")
    if metadata.gamma.value <= 0 or metadata.gamma.value > 64:
        raise PhaseALabelError("gamma is outside the Phase A safety bound")
    if abs(metadata.base_offset.value) > 64 or abs(metadata.alternate_offset.value) > 64:
        raise PhaseALabelError("gain-map offset is outside the Phase A safety bound")
    return metadata


def parse_tmap_payload(payload: bytes | bytearray | memoryview) -> IsoGainMapMetadata:
    """Parse the Apple/ISO single-channel ToneMapImage payload."""
    data = bytes(payload)
    if len(data) < 6:
        raise PhaseALabelError("truncated tmap payload")
    tone_map_version = data[0]
    if tone_map_version != 0:
        raise PhaseALabelError(f"unsupported ToneMapImage version {tone_map_version}")
    minimum_version = int.from_bytes(data[1:3], "big")
    writer_version = int.from_bytes(data[3:5], "big")
    flags = data[5]
    pos = 6
    common = bool(flags & 0x08)
    if common:
        denominator, pos = _u32(data, pos)
        if denominator == 0:
            raise PhaseALabelError("zero common denominator")
        base_n, pos = _u32(data, pos)
        alt_n, pos = _u32(data, pos)
        base_headroom = Rational(base_n, denominator)
        alternate_headroom = Rational(alt_n, denominator)
        fields: list[Rational] = []
        for _ in range(5):
            numerator, pos = _s32(data, pos)
            fields.append(Rational(numerator, denominator))
        gain_min, gain_max, gamma, base_offset, alternate_offset = fields
    else:
        base_headroom, pos = _rational(data, pos, signed=False)
        alternate_headroom, pos = _rational(data, pos, signed=False)
        gain_min, pos = _rational(data, pos, signed=True)
        gain_max, pos = _rational(data, pos, signed=True)
        gamma, pos = _rational(data, pos, signed=False)
        base_offset, pos = _rational(data, pos, signed=True)
        alternate_offset, pos = _rational(data, pos, signed=True)
    if pos != len(data):
        raise PhaseALabelError("unexpected trailing ToneMapImage data")
    return _validate_metadata(
        IsoGainMapMetadata(
            minimum_version=minimum_version,
            writer_version=writer_version,
            flags=flags,
            use_base_color_space=bool(flags & 0x40),
            backward_direction=bool(flags & 0x04),
            common_denominator=common,
            base_headroom=base_headroom,
            alternate_headroom=alternate_headroom,
            gain_min=gain_min,
            gain_max=gain_max,
            gamma=gamma,
            base_offset=base_offset,
            alternate_offset=alternate_offset,
        )
    )


def serialize_tmap_payload(metadata: IsoGainMapMetadata) -> bytes:
    """Serialize a validated single-channel v0 metadata record."""
    metadata = _validate_metadata(metadata)
    out = bytearray([0])
    out.extend(metadata.minimum_version.to_bytes(2, "big"))
    out.extend(metadata.writer_version.to_bytes(2, "big"))
    flags = metadata.flags
    flags = (flags | 0x40) if metadata.use_base_color_space else (flags & ~0x40)
    flags = (flags | 0x08) if metadata.common_denominator else (flags & ~0x08)
    out.append(flags & 0xFF)

    def put_u32(value: int) -> None:
        out.extend(int(value).to_bytes(4, "big", signed=False))

    def put_s32(value: int) -> None:
        out.extend(int(value).to_bytes(4, "big", signed=True))

    def put_rational(value: Rational, signed: bool = True) -> None:
        (put_s32 if signed else put_u32)(value.numerator)
        put_u32(value.denominator)

    if metadata.common_denominator:
        denominator = metadata.base_headroom.denominator
        fields = (
            metadata.alternate_headroom,
            metadata.gain_min,
            metadata.gain_max,
            metadata.gamma,
            metadata.base_offset,
            metadata.alternate_offset,
        )
        if any(value.denominator != denominator for value in fields):
            raise PhaseALabelError("common-denominator metadata has mismatched denominators")
        put_u32(denominator)
        put_u32(metadata.base_headroom.numerator)
        put_u32(metadata.alternate_headroom.numerator)
        for value in fields[1:]:
            put_s32(value.numerator)
    else:
        put_rational(metadata.base_headroom, signed=False)
        put_rational(metadata.alternate_headroom, signed=False)
        put_rational(metadata.gain_min)
        put_rational(metadata.gain_max)
        put_rational(metadata.gamma, signed=False)
        put_rational(metadata.base_offset)
        put_rational(metadata.alternate_offset)
    return bytes(out)


def rec709_eotf(encoded: np.ndarray | float) -> np.ndarray | float:
    """Inverse OETF used by Apple's legacy gain-map documentation."""
    value = np.asarray(encoded, dtype=np.float32)
    result = np.where(value < 0.081, value / 4.5, ((value + 0.099) / 1.099) ** (1.0 / 0.45))
    if np.ndim(encoded) == 0:
        return float(result)
    return result


def decode_iso_gain_code(code: np.ndarray, metadata: IsoGainMapMetadata) -> np.ndarray:
    """Decode an 8-bit ISO gain image to signed canonical log2 gain."""
    encoded = np.asarray(code, dtype=np.float32) / 255.0
    encoded = np.clip(encoded, 0.0, 1.0)
    q = encoded ** (1.0 / metadata.gamma_value)
    return metadata.gain_min_value + (metadata.gain_max_value - metadata.gain_min_value) * q


def decode_legacy_gain_code(code: np.ndarray, headroom: float) -> np.ndarray:
    if not math.isfinite(headroom) or headroom < 1.0 or headroom > 32.0:
        raise PhaseALabelError(f"invalid legacy headroom {headroom!r}")
    encoded = np.asarray(code, dtype=np.float32) / 255.0
    gain_linear = 1.0 + (headroom - 1.0) * np.asarray(rec709_eotf(encoded))
    return np.log2(np.maximum(gain_linear, np.finfo(np.float32).tiny)).astype(np.float32)


def parse_xmp_headroom(xmp: bytes | str | None) -> float | None:
    if xmp is None:
        return None
    text = bytes(xmp).decode("utf-8", errors="ignore") if not isinstance(xmp, str) else xmp
    match = re.search(r"HDRGainMapHeadroom\s*=\s*[\"']([^\"']+)", text)
    if not match:
        match = re.search(r"HDRGainMapHeadroom[^>]*>([^<]+)<", text)
    if not match:
        return None
    try:
        value = float(match.group(1))
    except ValueError:
        return None
    return value if math.isfinite(value) and value >= 1.0 else None


def parse_apple_makernote(maker: bytes | None) -> dict[int, float]:
    """Parse Apple signed-rational MakerNote tags using Apple-relative offsets."""
    if not maker:
        return {}
    byte_order_at = maker.find(b"MM")
    if byte_order_at < 0 or byte_order_at + 4 > len(maker):
        raise PhaseALabelError("truncated or invalid Apple MakerNote")
    count = struct.unpack_from(">H", maker, byte_order_at + 2)[0]
    entries_at = byte_order_at + 4
    if entries_at + count * 12 > len(maker):
        raise PhaseALabelError("truncated Apple MakerNote entries")
    values: dict[int, float] = {}
    for index in range(count):
        at = entries_at + index * 12
        tag, field_type, item_count, offset = struct.unpack_from(">HHII", maker, at)
        if field_type != 10 or item_count != 1:
            continue
        if offset + 8 > len(maker):
            raise PhaseALabelError("truncated Apple MakerNote rational")
        numerator, denominator = struct.unpack_from(">ii", maker, offset)
        if denominator == 0:
            raise PhaseALabelError("zero Apple MakerNote rational denominator")
        values[tag] = numerator / denominator
    return values


def legacy_headroom(maker33: float, maker48: float) -> float:
    if not math.isfinite(maker33) or not math.isfinite(maker48):
        raise PhaseALabelError("non-finite MakerNote headroom fields")
    if maker33 < 1.0:
        stops = -20.0 * maker48 + 1.8 if maker48 <= 0.01 else -0.101 * maker48 + 1.601
    else:
        stops = -70.0 * maker48 + 3.0 if maker48 <= 0.01 else -0.303 * maker48 + 2.303
    return 2.0 ** max(stops, 0.0)


def _box_header(data: bytes, offset: int, end: int) -> tuple[int, str, int]:
    if offset + 8 > end:
        raise PhaseALabelError("truncated HEIF box")
    size = int.from_bytes(data[offset : offset + 4], "big")
    header = 8
    if size == 1:
        if offset + 16 > end:
            raise PhaseALabelError("truncated extended HEIF box")
        size = int.from_bytes(data[offset + 8 : offset + 16], "big")
        header = 16
    elif size == 0:
        size = end - offset
    if size < header or offset + size > end:
        raise PhaseALabelError("invalid HEIF box size")
    return header, data[offset + 4 : offset + 8].decode("latin1"), size


def _children(data: bytes, start: int, end: int) -> Iterable[tuple[int, str, int, int]]:
    pos = start
    while pos < end:
        header, kind, size = _box_header(data, pos, end)
        yield pos, kind, size, header
        pos += size


def _parse_tmap_item_id(data: bytes, meta_offset: int, meta_size: int) -> int:
    for offset, kind, size, header in _children(data, meta_offset + header_for_meta(data, meta_offset), meta_offset + meta_size):
        if kind != "iinf":
            continue
        payload = data[offset + header : offset + size]
        if len(payload) < 8:
            continue
        version = payload[0]
        # iinf version 0 uses a 16-bit entry count; version 1/2 use 32-bit.
        count_size = 2 if version == 0 else 4
        count = int.from_bytes(payload[4 : 4 + count_size], "big")
        pos = 4 + count_size
        for _ in range(count):
            if pos + 8 > len(payload):
                raise PhaseALabelError("truncated iinf entry")
            child_header, child_kind, child_size = _box_header(payload, pos, len(payload))
            if child_kind == "infe":
                info = payload[pos + child_header : pos + child_size]
                if len(info) >= 12:
                    inf_version = info[0]
                    if inf_version >= 2 and len(info) >= 12:
                        item_id = int.from_bytes(info[4:6], "big")
                        if info[8:12] == b"tmap":
                            return item_id
            pos += child_size
    raise PhaseALabelError("HEIF has no tmap item")


def header_for_meta(data: bytes, offset: int) -> int:
    header, _, _ = _box_header(data, offset, len(data))
    return header + 4  # meta is a FullBox; children follow version/flags.


def extract_tmap_payload(heif_bytes: bytes | bytearray | memoryview) -> bytes:
    """Extract the tmap item's metadata payload from a HEIF container."""
    data = bytes(heif_bytes)
    try:
        tops = list(_children(data, 0, len(data)))
        meta = next((item for item in tops if item[1] == "meta"), None)
        if meta is None:
            raise PhaseALabelError("HEIF has no meta box")
        meta_offset, _, meta_size, meta_header = meta
        tmap_id = _parse_tmap_item_id(data, meta_offset, meta_size)
        iloc = next(
            (item for item in _children(data, meta_offset + meta_header + 4, meta_offset + meta_size) if item[1] == "iloc"),
            None,
        )
        if iloc is None:
            raise PhaseALabelError("HEIF has no iloc box")
        loc_payload = data[iloc[0] + iloc[3] : iloc[0] + iloc[2]]
        version = loc_payload[0]
        if len(loc_payload) < 8:
            raise PhaseALabelError("truncated iloc")
        offset_size = loc_payload[4] >> 4
        length_size = loc_payload[4] & 0x0F
        base_size = loc_payload[5] >> 4
        index_size = (loc_payload[5] & 0x0F) if version in (1, 2) else 0
        pos = 6
        count_width = 4 if version >= 2 else 2
        item_count = int.from_bytes(loc_payload[pos : pos + count_width], "big")
        pos += count_width
        loc: tuple[int, int, int, list[tuple[int, int]]] | None = None
        for _ in range(item_count):
            item_id_width = 4 if version >= 2 else 2
            item_id = int.from_bytes(loc_payload[pos : pos + item_id_width], "big")
            pos += item_id_width
            construction_method = 0
            if version in (1, 2):
                construction_method = int.from_bytes(loc_payload[pos : pos + 2], "big") & 0x0FFF
                pos += 2
            if construction_method not in (0, 1):
                raise PhaseALabelError("unsupported HEIF iloc construction method")
            pos += 2  # data reference index
            base = int.from_bytes(loc_payload[pos : pos + base_size], "big") if base_size else 0
            pos += base_size
            extent_count = int.from_bytes(loc_payload[pos : pos + 2], "big")
            pos += 2
            extents: list[tuple[int, int]] = []
            for _ in range(extent_count):
                if index_size:
                    pos += index_size
                extent_offset = int.from_bytes(loc_payload[pos : pos + offset_size], "big") if offset_size else 0
                pos += offset_size
                extent_length = int.from_bytes(loc_payload[pos : pos + length_size], "big") if length_size else 0
                pos += length_size
                extents.append((base + extent_offset, extent_length))
            if item_id == tmap_id:
                loc = (construction_method, base, item_id, extents)
        if loc is None or not loc[3]:
            raise PhaseALabelError("tmap item has no extents")
        construction_method, _, _, extents = loc
        if construction_method == 1:
            idat = next((item for item in _children(data, meta_offset + meta_header + 4, meta_offset + meta_size) if item[1] == "idat"), None)
            if idat is None:
                raise PhaseALabelError("tmap uses idat but idat is missing")
            base_data = data[idat[0] + idat[3] : idat[0] + idat[2]]
            payload = b"".join(base_data[offset : offset + length] for offset, length in extents)
        else:
            payload = b"".join(data[offset : offset + length] for offset, length in extents)
        parse_tmap_payload(payload)
        return payload
    except PhaseALabelError:
        raise
    except (IndexError, struct.error) as exc:
        raise PhaseALabelError("malformed HEIF tmap metadata") from exc


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_formula(source_type: str) -> str:
    if source_type == "iso_21496_1_tmap":
        return "log2_gain = gain_min + (gain_max - gain_min) * (code/255) ** (1/gamma)"
    if source_type == "legacy_apple":
        return "log2(1 + (headroom - 1) * rec709_eotf(code/255))"
    raise PhaseALabelError(f"unknown Phase A source type {source_type!r}")
