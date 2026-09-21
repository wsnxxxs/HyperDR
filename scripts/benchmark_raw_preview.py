"""Measure cold/refinement/cache-hit RAW frames in the real native worker.

Run before and after builds sequentially, with no concurrent build or export.
Uses the panel's precomputed source digest and no on-disk preview cache.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time


def measure(executable: Path, source: Path, flags: list[str], digest: str,
            edges: list[int], packet_directory: Path | None, run: int) -> list[dict]:
    # Keep the input basename in argv, as the Windows CLI uses narrow paths.
    with subprocess.Popen([str(executable), "preview-worker"], cwd=source.parent,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE) as worker:
        try:
            hello = json.loads(worker.stdout.readline())
            if hello.get("schema") != "hyperdr.preview-worker/v1":
                raise RuntimeError(f"Unexpected worker handshake: {hello}")
            rows = []
            for step, edge in enumerate(edges):
                arguments = [source.name, "--output", "unused-benchmark.hpf",
                             "--preview-max-edge", str(edge), "--fast-preview",
                             "--exposure", "0", "--decode-cache-source-sha256", digest,
                             *flags]
                start = time.perf_counter()
                worker.stdin.write((json.dumps(arguments) + "\n").encode())
                worker.stdin.flush()
                header = json.loads(worker.stdout.readline())
                if not header.get("size"):
                    raise RuntimeError(header.get("error", "Empty preview packet"))
                packet = worker.stdout.read(header["size"])
                elapsed = time.perf_counter() - start
                if len(packet) != header["size"]:
                    raise RuntimeError("Truncated worker packet")
                rows.append({"run": run, "step": step, "edge": edge,
                             "seconds": elapsed, "bytes": len(packet)})
                print(f"run={run} step={step} edge={edge}: {elapsed:.3f}s", flush=True)
                if packet_directory:
                    (packet_directory / f"run-{run}-step-{step}-{edge}.hpf").write_bytes(packet)
            worker.stdin.close()
            if worker.wait(timeout=30):
                raise RuntimeError("Preview worker failed")
            return rows
        finally:
            if worker.poll() is None:
                worker.terminate()
                worker.wait(timeout=10)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--raw-profile", type=Path)
    parser.add_argument("--raw-lens-profile", type=Path)
    parser.add_argument("--edges", type=int, nargs="+", default=[640, 1440, 2048, 1440])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--packets", type=Path)
    args = parser.parse_args()
    if args.runs < 1 or any(edge < 1 or edge > 8192 for edge in args.edges):
        parser.error("runs must be positive and edges must be in [1,8192]")
    source, executable = args.source.resolve(strict=True), args.exe.resolve(strict=True)
    with source.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    flags = []
    for flag, value in [("--raw-profile", args.raw_profile),
                        ("--raw-lens-profile", args.raw_lens_profile)]:
        if value:
            flags.extend([flag, str(value.resolve(strict=True))])
    if args.packets:
        args.packets.mkdir(parents=True, exist_ok=True)
    rows = []
    for run in range(args.runs):
        rows.extend(measure(executable, source, flags, digest, args.edges, args.packets, run))
    medians = [{"step": step, "edge": edge,
                "seconds": statistics.median(r["seconds"] for r in rows if r["step"] == step)}
               for step, edge in enumerate(args.edges)]
    report = {"executable": str(executable), "source": str(source), "source_sha256": digest,
              "flags": flags, "medians": medians, "measurements": rows}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(medians, indent=2))


if __name__ == "__main__":
    main()
