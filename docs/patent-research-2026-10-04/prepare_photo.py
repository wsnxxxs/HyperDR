"""Extract a private paired-photo fixture for the C++ patent comparison.

The photograph and generated pixels stay under ignored output/. Only aggregate
measurements are committed. Requires NumPy and an existing codec-enabled CLI.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "HyperDR_Model"))
from hyperdr_ml.phase_a_labels import extract_tmap_payload, parse_tmap_payload

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    wire = parse_tmap_payload(extract_tmap_payload(args.source.read_bytes()))
    if wire.base_offset.value != wire.alternate_offset.value:
        raise ValueError("This bounded comparison expects equal source offsets")
    packet = args.output.with_suffix(".hpf")
    command = [str(args.executable.resolve()), "preview-frame", str(args.source.resolve()),
               "--output", str(packet.resolve()), "--preview-max-edge", "1024",
               # Dual-rendition Ultra HDR previews return the float endpoints
               # directly. Adaptive previews have already packed/reconstructed
               # a monochrome map and would make this comparison circular.
               "--encoding", "ultrahdr",
               "--contrast", "1", "--vibrance", "0", "--pop", "0",
               "--exposure-bias", "0", "--gain-strength", "1",
               "--headroom", "4", "--headroom-max", "4"]
    subprocess.run(command, check=True, capture_output=True)
    data = packet.read_bytes()
    if data[:8] != b"HYPREV1\n":
        raise ValueError("Expected explicit SDR/HDR planes, not a packed gain preview")
    length, = struct.unpack_from("<I", data, 8)
    meta = json.loads(data[12:12+length])
    if meta["inputDomain"] != "dual-rendition":
        raise ValueError("Source must expose authored SDR/HDR endpoints")
    planes = np.frombuffer(data, dtype="<f4", offset=12+length)
    if planes.size != 2*meta["width"]*meta["height"]*3 or not np.isfinite(planes).all():
        raise ValueError("Invalid paired preview")
    args.output.write_bytes(struct.pack("<IIf", meta["width"], meta["height"],
                                      wire.base_offset.value) + planes.tobytes())
    evidence = {"source_name": args.source.name,
                "source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
                "input_generator_sha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
                "input_generator_mtime_utc_seconds": args.executable.stat().st_mtime,
                "preview_metadata": meta,
                "source_tmap": wire.as_dict(),
                "preview_encoding": "ultrahdr: direct paired endpoint path for dual-rendition input",
                "paired_float_sha256": hashlib.sha256(planes.tobytes()).hexdigest(),
                "limitation": "CLI prepares inputs only. The current core packager is called separately by probe.cpp. No final lossy codec comparison."}
    print(json.dumps(evidence, indent=2))

if __name__ == "__main__":
    main()
