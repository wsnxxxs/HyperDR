"""Input filename families shared by the panel's upload and execution paths."""

from __future__ import annotations


# This mirrors the C++ discovery filter. The native decoder still validates the
# file contents through LibRaw; these names only decide which files the panel
# offers and which jobs need RAW resources.
RAW_INPUT_EXTENSIONS = frozenset(
    {
        ".3fr",
        ".arw",
        ".bay",
        ".cap",
        ".cr2",
        ".cr3",
        ".crw",
        ".dcr",
        ".dng",
        ".erf",
        ".fff",
        ".gpr",
        ".iiq",
        ".k25",
        ".kdc",
        ".mef",
        ".mos",
        ".mrw",
        ".nef",
        ".nrw",
        ".orf",
        ".pef",
        ".raf",
        ".raw",
        ".rwl",
        ".rw2",
        ".sr2",
        ".srf",
        ".srw",
        ".x3f",
    }
)

RASTER_INPUT_EXTENSIONS = frozenset(
    {".jpg", ".jpeg", ".png", ".heic", ".heif", ".avif"}
)

SUPPORTED_EXTENSIONS = RAW_INPUT_EXTENSIONS | RASTER_INPUT_EXTENSIONS
