#!/usr/bin/env python3
"""Summarize opt-in A3 records from log show --style json/ndjson.

No estimated GPU/presentation timings: missing callbacks/counters stay blank.
Each CSV row is one request, not one display refresh. GPU samples may arrive
out of log order; their calibrated host nanoseconds define their order.
"""
import argparse
import csv
import io
import json
import math
import re
import statistics
from collections import defaultdict, deque
from pathlib import Path

PATTERN = re.compile(r"A3 trace=([\w-]+) stage=(\w+) event=(\w+) ns=(\d+)")
STRESS = re.compile(r"A3Stress mode=\w+ event=(begin|end) ns=(\d+)")
STAGES = ("render_frame", "metalBuffers", "pass1_encode", "pass1_gpu", "commit_to_gpu_complete")
COLUMNS = ("trace", "edge", "purpose", "presented", "request_to_present_ms", "queue_to_engine_ms", *[s + "_ms" for s in STAGES])


def records(text):
    try:
        value = json.loads(text)
        entries = value if isinstance(value, list) else [value]
    except json.JSONDecodeError:
        entries = []
        for line in text.splitlines():
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                entries.append(line)
    for entry in entries:
        message = entry.get("eventMessage", "") if isinstance(entry, dict) else str(entry)
        match = PATTERN.search(message)
        if match:
            trace, stage, event, ns = match.groups()
            yield trace, stage, event, int(ns)
        elif marker := STRESS.search(message):
            yield "stress", "stress", marker[1], int(marker[2])


def summarize(events, edge=None, stress_only=False, start_ns=None, end_ns=None):
    events = list(events)
    windows, begin = [], None
    for _, stage, event, ns in sorted(events, key=lambda e: e[3]):
        if stage == "stress" and event == "begin":
            begin = ns
        elif stage == "stress" and event == "end" and begin is not None:
            windows.append((begin, ns)); begin = None
    grouped = defaultdict(list)
    for trace, stage, event, ns in events:
        grouped[trace].append((ns, stage, event))
    rows = []
    for trace, values in grouped.items():
        values.sort()
        starts = [n for n, s, e in values if s == "request" and e == "begin"]
        if not starts:
            continue
        start = starts[0]
        if (start_ns is not None and start < start_ns) or (end_ns is not None and start > end_ns):
            continue
        if stress_only and not any(a <= start <= b for a, b in windows):
            continue
        presented = [n for n, s, e in values if s == "presented" and n >= start]
        finish = min(presented) if presented else None
        row = {"trace": trace, "edge": "", "purpose": "", "presented": bool(finish)}
        for _, stage, _ in values:
            if stage.startswith("edge_"):
                row["edge"] = int(stage[5:])
            if stage in ("edit", "reference"):
                row["purpose"] = stage
        if edge is not None and row["edge"] != edge:
            continue
        row["request_to_present_ms"] = (finish - start) / 1e6 if finish else None
        engine = [n for n, s, e in values if s == "render_frame" and e == "begin"]
        row["queue_to_engine_ms"] = (engine[0] - start) / 1e6 if engine else None
        for stage in STAGES:
            pending = deque()
            durations = []
            for ns, s, event in values:
                if s != stage or (finish is not None and ns > finish):
                    continue
                if event == "begin":
                    pending.append(ns)
                elif event == "end" and pending:
                    durations.append(ns - pending.popleft())
            row[stage + "_ms"] = sum(durations) / 1e6 if durations else None
        rows.append(row)
    return rows


def table(rows):
    lines = [f"requests={len(rows)} presented={sum(r['presented'] for r in rows)} incomplete={sum(not r['presented'] for r in rows)}",
             "stage                         samples    p50_ms    p95_ms"]
    for key in COLUMNS[4:]:
        samples = sorted(r[key] for r in rows if r.get(key) is not None)
        if samples:
            p95 = samples[max(0, math.ceil(len(samples) * .95) - 1)]
            lines.append(f"{key:30} {len(samples):7} {statistics.median(samples):9.3f} {p95:9.3f}")
    return "\n".join(lines)


def self_test():
    # Two GPU layers, out-of-order delivery, an incomplete request, and a
    # post-presentation redraw which must not inflate the original latency.
    events = [("a", "request", "begin", 0), ("a", "edge_640", "point", 0),
              ("a", "pass1_gpu", "end", 4_000_000), ("a", "pass1_gpu", "begin", 2_000_000),
              ("a", "pass1_gpu", "begin", 5_000_000), ("a", "pass1_gpu", "end", 6_000_000),
              ("a", "presented", "point", 10_000_000),
              ("a", "pass1_gpu", "begin", 12_000_000), ("a", "pass1_gpu", "end", 14_000_000),
              ("b", "request", "begin", 20_000_000)]
    rows = summarize(events)
    assert rows[0]["pass1_gpu_ms"] == 3 and rows[0]["request_to_present_ms"] == 10
    assert rows[1]["request_to_present_ms"] is None and rows[1]["pass1_gpu_ms"] is None
    assert len(summarize(events, 640)) == 1
    marked = events + [("stress", "stress", "begin", 19_000_000), ("stress", "stress", "end", 21_000_000)]
    assert [r["trace"] for r in summarize(marked, stress_only=True)] == ["b"]
    assert not summarize(events, stress_only=True)
    assert [r["trace"] for r in summarize(events, start_ns=0, end_ns=0)] == ["a"]
    assert [r["trace"] for r in summarize(events, start_ns=1)] == ["b"]
    assert not summarize(events, start_ns=1, end_ns=19_999_999)
    assert summarize(events, end_ns=0)[0]["request_to_present_ms"] == 10
    assert not summarize(marked, stress_only=True, end_ns=19_999_999)
    message = "A3 trace=a stage=request event=begin ns=1"
    for text in (json.dumps([{"eventMessage": message}]), json.dumps({"eventMessage": message}) + "\n{}", message):
        assert list(records(text)) == [("a", "request", "begin", 1)]
    assert "incomplete=1" in table(rows)
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=COLUMNS); writer.writeheader(); writer.writerows(rows)
    assert "None" not in output.getvalue()
    print("preview timing summarizer self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?")
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--edge", type=int)
    parser.add_argument("--stress-only", action="store_true", help="Only requests started during a completed A3Stress run")
    parser.add_argument("--start", type=int, metavar="UPTIME_NS", help="Inclusive request-start boundary in host monotonic nanoseconds (A3 ns= field)")
    parser.add_argument("--end", type=int, metavar="UPTIME_NS", help="Inclusive request-end boundary in host monotonic nanoseconds; later presentation is retained")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    if args.input is None:
        parser.error("provide a log show JSON/NDJSON file")
    if (args.start is not None and args.start < 0) or (args.end is not None and args.end < 0):
        parser.error("--start and --end must be nonnegative host monotonic nanoseconds")
    if args.start is not None and args.end is not None and args.start > args.end:
        parser.error("--start must not exceed --end")
    rows = summarize(records(args.input.read_text()), args.edge, args.stress_only, args.start, args.end)
    if not rows:
        parser.error("no matching A3 requests found; enable -HDRPreviewTimings YES and include PreviewStress markers for --stress-only")
    print(table(rows))
    if args.csv:
        with args.csv.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=COLUMNS); writer.writeheader(); writer.writerows(rows)


if __name__ == "__main__":
    main()
