"""Which files are images, and how to tell from their first bytes.

The panel used to carry its own copy of every extension and tried to validate
RAW with a shorter table of generic container magic. That table could neither
cover every camera format nor distinguish CR3 from HEIC, so RAW is now routed
by extension and validated by LibRaw itself. Raster signatures remain useful
because JPEG, PNG and ISO-BMFF are distinguishable from their leading bytes.

``HyperDR schema`` emits the extension vocabulary and raster signatures;
``schema/settings.json`` is that output, checked in, and this module turns it
into the sets and sniffing the Python panel needs. Browser controls have a
separate UI adapter for presentation and request mapping.
"""
from __future__ import annotations

from . import schema
from .schema import SchemaError


def _inputs() -> dict:
    inputs = schema.DOCUMENT.get("inputs")
    if not isinstance(inputs, dict):
        raise SchemaError(
            "设置定义缺少 inputs 段。请重新构建 HyperDR 或运行 "
            "`HyperDR schema > schema/settings.json`。"
        )
    return inputs


def _raw_extensions() -> frozenset[str]:
    values = _inputs().get("extensions", {}).get("raw")
    if not isinstance(values, list) or not values:
        raise SchemaError("设置定义中的 inputs.extensions.raw 为空或格式不正确。")
    return frozenset(str(value).lower() for value in values)


def _raster_extensions() -> dict[str, frozenset[str]]:
    families = _inputs().get("extensions", {}).get("raster")
    if not isinstance(families, dict) or not families:
        raise SchemaError("设置定义中的 inputs.extensions.raster 为空或格式不正确。")
    return {
        kind: frozenset(str(value).lower() for value in values)
        for kind, values in families.items()
    }


def _signatures(kind: str) -> tuple[tuple[int, bytes], ...]:
    entries = _inputs().get("signatures", {}).get(kind)
    if not isinstance(entries, list) or not entries:
        raise SchemaError("设置定义中的 inputs.signatures.%s 为空或格式不正确。" % kind)
    return tuple(
        (int(entry["offset"]), bytes.fromhex(str(entry["magic"])))
        for entry in entries
    )


def _canonical_extensions() -> dict[str, str]:
    values = _inputs().get("canonicalExtensions")
    if not isinstance(values, dict) or not values:
        raise SchemaError(
            "设置定义中的 inputs.canonicalExtensions 为空或格式不正确。")
    return {str(kind): str(extension).lower() for kind, extension in values.items()}


def _derive() -> None:
    global RAW_INPUT_EXTENSIONS, RASTER_INPUT_EXTENSIONS, SUPPORTED_EXTENSIONS
    global RASTER_FAMILY_EXTENSIONS, CANONICAL_EXTENSIONS
    global _RASTER_SIGNATURES, PREFIX_BYTES
    RAW_INPUT_EXTENSIONS = _raw_extensions()
    RASTER_FAMILY_EXTENSIONS = _raster_extensions()
    RASTER_INPUT_EXTENSIONS = frozenset().union(*RASTER_FAMILY_EXTENSIONS.values())
    SUPPORTED_EXTENSIONS = RAW_INPUT_EXTENSIONS | RASTER_INPUT_EXTENSIONS
    # The raster families the panel can name from bytes alone. `isobmff` stops
    # at the container on purpose: HEIF and AVIF are the same box structure and
    # which codec sits inside is the decoder's business, as it always was here.
    _RASTER_SIGNATURES = {
        kind: _signatures(kind) for kind in ("jpeg", "png", "isobmff")
    }
    # The extension a file of each detected family is stored under. An ISO base
    # media file is named `.heic` whatever codec it carries, because that is the
    # name the converter's HEIF branch routes through -- and that branch already
    # hands an AV1 payload to the AVIF decoder. Derived, not mirrored: this was
    # the last table in this module still maintained by hand.
    CANONICAL_EXTENSIONS = _canonical_extensions()
    # How many leading bytes are enough to answer any of the questions below.
    # Reading more than this to classify a file is waste -- and reading the whole
    # file, which this module's predecessor did, is 300 MB of it on a large RAW.
    PREFIX_BYTES = int(_inputs().get("prefixBytes") or 16)


_derive()


def _matches(header: bytes, signatures) -> bool:
    return any(
        header[offset:offset + len(magic)] == magic for offset, magic in signatures
    )


def detect_format(header: bytes) -> str | None:
    """Name the raster family these leading bytes belong to, or None.

    RAW is deliberately not returned: most RAW containers *are* TIFF, so a
    signature cannot separate a .dng from any other TIFF. LibRaw validates a
    file after its extension routes it to the RAW decoder.
    """
    for kind, signatures in _RASTER_SIGNATURES.items():
        if _matches(header, signatures):
            return kind
    return None

def extension_format(extension: str) -> str | None:
    """The raster family a filename claims, or None for RAW and the unknown."""
    for kind, extensions in RASTER_FAMILY_EXTENSIONS.items():
        if extension in extensions:
            return kind
    return None
