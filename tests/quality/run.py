#!/usr/bin/env python3
"""Local HEVC quality gate. No photos are required; outputs live in a temporary directory."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build')
    parser.add_argument('--e5', action='store_true', help='also run the package E5 synthetic photo-preservation cases')
    parser.add_argument('--report', type=Path, help='save numbers only, never image pixels or source metadata')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    spec = json.loads(Path(__file__).with_name('thresholds.json').read_text())
    results = []
    with tempfile.TemporaryDirectory(prefix='hyperdr-quality-') as temporary:
        directory = Path(temporary)
        for case in spec['cases']:
            result = json.loads(subprocess.check_output([
                str(build / 'quality_lab'), 'run', case['writer'], case['format'],
                str(case['depth']), str(case['quality']), case['scene'],
                str(case['width']), str(case['height']), str(directory / 'candidate.heic')], text=True))
            if 'reference_peak' in result:
                result['peak_relative_error'] = abs(result['candidate_peak'] / result['reference_peak'] - 1)
                result['mean_relative_error'] = abs(result['candidate_mean'] / result['reference_mean'] - 1)
            # The executable additionally checks dimensions/orientation/depth,
            # primaries/transfer, auxiliary presence/channels and coding rationals.
            for field, minimum in case.get('min', {}).items():
                if not math.isfinite(result[field]) or result[field] < minimum:
                    raise RuntimeError((case['name'], field, result[field], minimum))
            for field, maximum in case.get('max', {}).items():
                if not math.isfinite(result[field]) or result[field] > maximum:
                    raise RuntimeError((case['name'], field, result[field], maximum))
            result['name'] = case['name']
            results.append(result)
            print(json.dumps(result), flush=True)
        if args.e5:
            subprocess.run([str(build / 'e5_package_quality')], check=True)
    if args.report:
        args.report.write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
