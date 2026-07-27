#!/usr/bin/env python3
"""Aggregate HyperDR --report JSON files into a benchmark summary.

Usage:
  python scripts/benchmark.py reports/*.json              # table to stdout
  python scripts/benchmark.py --csv reports/*.json > out.csv
  python scripts/benchmark.py --compare before/ after/    # A/B diff
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    idx = max(0, min(len(values) - 1, int(pct * (len(values) - 1))))
    return values[idx]


def load_report(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def collect_metrics(reports: list[dict]) -> dict:
    decode = []
    process = []
    encode = []
    total = []
    headroom = []
    rendered_peak = []
    wide_gamut = []
    gain_max = []
    files_ok = 0
    files_err = 0

    for report in reports:
        results = report.get("results", [])
        if not isinstance(results, list):
            continue
        for entry in results:
            if not isinstance(entry, dict):
                continue
            if entry.get("error"):
                files_err += 1
                continue
            files_ok += 1
            for field, collector in (
                ("decode_ms", decode),
                ("process_ms", process),
                ("encode_ms", encode),
            ):
                val = entry.get(field)
                if isinstance(val, (int, float)):
                    collector.append(float(val))
            d = entry.get("decode_ms", 0) or 0
            p = entry.get("process_ms", 0) or 0
            e = entry.get("encode_ms", 0) or 0
            total.append(float(d) + float(p) + float(e))

            # The report nests measurements under "render" and "gain_map";
            # this used to look for a flat "look_stats" object that no version
            # of the report has ever written, so every figure below was empty.
            render = entry.get("render")
            gain_map = entry.get("gain_map")
            if isinstance(render, dict) or isinstance(gain_map, dict):
                render = render if isinstance(render, dict) else {}
                gain_map = gain_map if isinstance(gain_map, dict) else {}
                hr = render.get("headroom_stops")
                rp = render.get("rendered_peak")
                wg = render.get("wide_gamut_fraction")
                gm = gain_map.get("max_stops")
                if isinstance(hr, (int, float)):
                    headroom.append(float(hr))
                if isinstance(rp, (int, float)):
                    rendered_peak.append(float(rp))
                if isinstance(wg, (int, float)):
                    wide_gamut.append(float(wg))
                if isinstance(gm, (int, float)):
                    gain_max.append(float(gm))

    return {
        "files_ok": files_ok,
        "files_err": files_err,
        "decode_ms": decode,
        "process_ms": process,
        "encode_ms": encode,
        "total_ms": total,
        "headroom_stops": headroom,
        "rendered_peak": rendered_peak,
        "wide_gamut_fraction": wide_gamut,
        "gain_max_stops": gain_max,
    }


def summarise(name: str, metrics: dict) -> str:
    lines = [f"## {name}  ({metrics['files_ok']} ok, {metrics['files_err']} errors)"]
    lines.append("")
    lines.append("| metric | min | p50 | p95 | max | mean |")
    lines.append("|--------|-----|-----|-----|-----|------|")

    for label, key in (
        ("decode_ms", "decode_ms"),
        ("process_ms", "process_ms"),
        ("encode_ms", "encode_ms"),
        ("total_ms", "total_ms"),
        ("headroom_stops", "headroom_stops"),
        ("rendered_peak", "rendered_peak"),
        ("wide_gamut_fraction", "wide_gamut_fraction"),
        ("gain_max_stops", "gain_max_stops"),
    ):
        values = metrics.get(key, [])
        if not values:
            continue
        p50 = percentile(values, 0.50)
        p95 = percentile(values, 0.95)
        lines.append(
            f"| {label} | {min(values):.2f} | {p50:.2f} | "
            f"{p95:.2f} | {max(values):.2f} | "
            f"{sum(values)/len(values):.2f} |"
        )
    return "\n".join(lines)


def main() -> None:
    args = sys.argv[1:]
    csv_mode = False
    compare_a: str | None = None
    compare_b: str | None = None

    # Parse --flags
    positional = []
    i = 0
    while i < len(args):
        if args[i] == "--csv":
            csv_mode = True
            i += 1
        elif args[i] == "--compare" and i + 2 < len(args):
            compare_a = args[i + 1]
            compare_b = args[i + 2]
            i += 3
        else:
            positional.append(args[i])
            i += 1

    if compare_a and compare_b:
        base_a = Path(compare_a)
        base_b = Path(compare_b)
        reports_a = [load_report(p) for p in sorted(base_a.glob("*.json"))]
        reports_b = [load_report(p) for p in sorted(base_b.glob("*.json"))]
        m_a = collect_metrics(reports_a)
        m_b = collect_metrics(reports_b)
        print(summarise(compare_a, m_a))
        print()
        print(summarise(compare_b, m_b))
        print()
        # Simple speedup ratio
        if m_a["total_ms"] and m_b["total_ms"]:
            avg_a = sum(m_a["total_ms"]) / len(m_a["total_ms"])
            avg_b = sum(m_b["total_ms"]) / len(m_b["total_ms"])
            ratio = avg_a / avg_b if avg_b > 0 else float("inf")
            direction = "faster" if ratio > 1 else "slower"
            print(f"**Speedup:** {compare_b} is {abs(1-ratio)*100:.1f}% {direction} "
                  f"(avg total {avg_a:.1f} ms vs {avg_b:.1f} ms)")
        return

    if not positional:
        print("Usage: python scripts/benchmark.py [--csv] [--compare A/ B/] report*.json",
              file=sys.stderr)
        sys.exit(1)

    paths = [Path(p) for p in positional if Path(p).suffix == ".json"]
    if not paths:
        print("No .json report files found.", file=sys.stderr)
        sys.exit(1)

    reports = [load_report(p) for p in sorted(paths)]
    metrics = collect_metrics(reports)

    if csv_mode:
        print("metric,min,p50,p95,max,mean")
        for label, key in (
            ("decode_ms", "decode_ms"),
            ("process_ms", "process_ms"),
            ("encode_ms", "encode_ms"),
            ("total_ms", "total_ms"),
        ):
            values = metrics.get(key, [])
            if not values:
                continue
            p50 = percentile(values, 0.50)
            p95 = percentile(values, 0.95)
            print(f"{label},{min(values):.2f},{p50:.2f},{p95:.2f},"
                  f"{max(values):.2f},{sum(values)/len(values):.2f}")
    else:
        print(summarise("Benchmark", metrics))


if __name__ == "__main__":
    main()