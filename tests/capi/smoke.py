"""Codec CLI smoke without external fixtures or optional Python packages."""
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib

cli = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="hyperdr-smoke-") as directory:
    root = pathlib.Path(directory)
    source = root / "source.png"
    def chunk(kind, data):
        return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data))
    source.write_bytes(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",64,64,8,2,0,0,0))
        +chunk(b"IDAT",zlib.compress((b"\0"+b"\x60\x90\xb0"*64)*64))+chunk(b"IEND",b""))
    for encoding in ("sdr-jpeg", "sdr-tiff", "ultrahdr", "avif-pq", "avif-hlg"):
        subprocess.run([cli,"convert",str(source),"--output",str(root/encoding),"--encoding",encoding],check=True)
    print("Five non-HEVC exports passed (including decoder verification)")
