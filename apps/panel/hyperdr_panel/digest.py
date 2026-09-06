"""Content identity for files the panel hands to the converter.

Three callers need the same answer -- the upload session, the model pipeline and
the native preview -- and they need it to be the *same* answer: a preview cache
key and a model binding that disagreed about which bytes they were describing
would silently reuse the wrong frame. One implementation is the point.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

#: Large enough that a 300 MB RAW is a few hundred reads, small enough that the
#: buffer stays out of the way while several previews hash concurrently.
CHUNK_BYTES = 1024 * 1024


def sha256_file(path: Path) -> str:
    """Return the hex SHA-256 of a file, read in bounded chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()
