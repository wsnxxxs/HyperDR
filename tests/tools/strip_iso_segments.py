#!/usr/bin/env python3
"""Strip only ISO APP2 segments, repairing MPF sizes/offsets. Private output belongs in build-*.

The primary self-check excludes ISO, the repaired MPF, and GainMap Item:Length
digits (and the containing APP1 length). Every other segment and entropy byte,
and the complete gain image except ISO APP2,
are compared byte for byte. Opaque trailing data is retained unchanged.
"""
import argparse
import json
import re
from pathlib import Path

ISO = b"urn:iso:std:iso:ts:21496:-1\0"

def scan(data, start=0):
    if data[start:start + 2] != b"\xff\xd8":
        raise ValueError("missing SOI")
    pos, entropy, apps = start + 2, False, []
    while pos < len(data):
        if entropy and data[pos] != 255:
            pos += 1
            continue
        marker_start = pos
        if data[pos] != 255:
            raise ValueError("invalid marker")
        pos += 1
        while pos < len(data) and data[pos] == 255:
            pos += 1
        marker = data[pos]
        pos += 1
        if entropy and (marker == 0 or 0xD0 <= marker <= 0xD7):
            continue
        entropy = False
        if marker == 0xD9:
            return pos, apps
        if marker in (0, 0xD8) or 0xD0 <= marker <= 0xD7:
            raise ValueError("unexpected marker")
        length = int.from_bytes(data[pos:pos + 2], "big")
        if length < 2 or pos + length > len(data):
            raise ValueError("invalid segment length")
        if 0xE0 <= marker <= 0xEF:
            apps.append((marker_start, pos + length, marker, data[pos + 2:pos + length]))
        pos += length
        entropy = marker == 0xDA
    raise ValueError("missing EOI")

def without(data, apps, mpf=False):
    out = bytearray(data)
    for start, end, marker, payload in reversed(apps):
        if marker == 0xE2 and (payload.startswith(ISO) or (mpf and payload.startswith(b"MPF\0"))):
            del out[start:end]
    return bytes(out)

def item_length(payload, value):
    """Edit only the numeric Length in the GainMap container item, never hdrgm."""
    count = 0
    def tag(match):
        nonlocal count
        text = match[0]
        if not re.search(rb'(?:Item|GContainerItem):Semantic\s*=\s*["\']GainMap["\']', text):
            return text
        text, n = re.subn(rb'((?:Item|GContainerItem):Length\s*=\s*["\'])[0-9]+',
                          lambda m: m[1] + str(value).encode(), text)
        count += n
        return text
    return re.sub(rb'<[^<>]+>', tag, payload), count

def repair_directory(primary, gain_size):
    _, apps = scan(primary)
    out, changed = bytearray(primary), 0
    for start, end, marker, payload in reversed(apps):
        if marker != 0xE1 or not payload.startswith(b'http://ns.adobe.com/xap/1.0/\0'):
            continue
        replacement, count = item_length(payload, gain_size)
        changed += count
        if len(replacement) > 65533:
            raise ValueError("XMP segment exceeds JPEG limit")
        out[start:end] = b'\xff\xe1' + (len(replacement)+2).to_bytes(2,'big') + replacement
    return bytes(out), changed

def comparable_primary(data, apps):
    # Canonicalize only the permitted edits; all JPEG tables and entropy remain.
    primary = without(data, apps, True)
    return repair_directory(primary, 0)[0]

def compressed_payload(data):
    _, apps = scan(data)
    out = bytearray(data)
    for start, end, _, _ in reversed(apps):
        del out[start:end]
    return bytes(out)

def strip(data):
    primary_end, primary_apps = scan(data)
    gain_end, absolute_apps = scan(data, primary_end)
    gain_apps = [(a-primary_end,b-primary_end,m,p) for a,b,m,p in absolute_apps]
    primary = without(data[:primary_end], primary_apps)
    gain = without(data[primary_end:gain_end], gain_apps)
    primary, directory_items = repair_directory(primary, len(gain))
    primary = bytearray(primary)
    _, new_apps = scan(primary)
    indices = [a for a in new_apps if a[2] == 0xE2 and a[3].startswith(b"MPF\0")]
    if len(indices) != 1:
        raise ValueError("expected one primary MPF")
    start, end, _, payload = indices[0]
    header = start + 8
    order = "little" if primary[header:header+2] == b"II" else "big"
    def read(pos, n):
        return int.from_bytes(primary[header+pos:header+pos+n], order)
    ifd = read(4, 4)
    tables = []
    for i in range(read(ifd, 2)):
        p = ifd + 2 + i*12
        if read(p, 2) == 0xB002:
            tables.append(read(p+8, 4))
    if len(tables) != 1:
        raise ValueError("expected one MP entry table")
    table = header + tables[0]
    for pos, value in ((table+4,len(primary)), (table+20,len(gain)), (table+24,len(primary)-header)):
        primary[pos:pos+4] = value.to_bytes(4, order)
    result = bytes(primary) + gain + data[gain_end:]
    pe, pa = scan(result)
    ge, ga = scan(result, pe)
    ga = [(a-pe,b-pe,m,p) for a,b,m,p in ga]
    checks = {
        "primary_non_iso_except_mpf_item_length_identical": comparable_primary(data[:primary_end], primary_apps) == comparable_primary(result[:pe], pa),
        "primary_compressed_payload_identical": compressed_payload(data[:primary_end]) == compressed_payload(result[:pe]),
        "gain_compressed_payload_identical": compressed_payload(data[primary_end:gain_end]) == compressed_payload(result[pe:ge]),
        "item_length_recomputed": directory_items,
        "item_length_verified": repair_directory(result[:pe], ge-pe)[0] == result[:pe],
        "gain_non_iso_identical": without(data[primary_end:gain_end], gain_apps) == result[pe:ge],
        "trailer_identical": data[gain_end:] == result[ge:],
        "iso_segments_remaining": sum(m == 0xE2 and p.startswith(ISO) for _,_,m,p in pa+ga),
        "mpf_recomputed": True,
    }
    if not all(checks[k] for k in ("primary_non_iso_except_mpf_item_length_identical", "primary_compressed_payload_identical", "gain_compressed_payload_identical", "item_length_verified", "gain_non_iso_identical", "trailer_identical")) or checks["iso_segments_remaining"]:
        raise ValueError("ISO stripping self-check failed")
    return result, checks

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if not any(p.name.startswith("build-") for p in args.output.resolve().parents):
        parser.error("derived output must be inside a build-* directory")
    result, checks = strip(args.input.read_bytes())
    args.output.write_bytes(result)
    print(json.dumps(checks, sort_keys=True))
