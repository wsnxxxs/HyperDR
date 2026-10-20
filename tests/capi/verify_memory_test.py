"""Fresh verifier processes exclude writer caches and own no full planes."""
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

for fmt in ("sdr-tiff", "iso-gainmap-jpeg", "adaptive"):
    peaks = []
    for height in (1024, 4096):
        with TemporaryDirectory(prefix="hyperdr-verify-memory-") as folder:
            image = str(Path(folder) / "image")
            # A separate producer exits before the measured verifier starts.
            subprocess.run([sys.argv[1], "stream", str(height), "64", fmt, image],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([sys.argv[1], "check", image, fmt],
                                    check=True, capture_output=True, text=True)
        print(fmt, height, result.stdout.strip(), flush=True)
        peaks.append(int(re.search(r"after footprint=\d+ peak=(\d+)", result.stdout)[1]))
    # Four times the height used to add whole decoded RGB/gain/HDR planes
    # (hundreds of MB). Permit allocator/VideoToolbox variation and tile tables.
    growth = peaks[1] - peaks[0]
    print(f"{fmt} height_x4_peak_growth={growth}", flush=True)
    assert growth < 16 * 1024 * 1024, (fmt, peaks)
