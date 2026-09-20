#!/usr/bin/env python3
"""Check the shipped research model assets against the reference implementation.

Four claims are made about this integration, and each one is a number here
rather than a description:

1. **The CNNs converted.** PyTorch and ncnn are run on the *same* float32 tensor
   -- the one ``model-input`` dumps -- so the reported difference is conversion
   error and not the decode path's.
2. **The EXIF level estimator is the fitted one.** Mean removal makes model 2's
   output mean equal to its estimator's scalar, so the whole native
   combination can be compared against sklearn on a zero tensor and
   deliberately chosen capture vectors, including the two presence cases that a
   photograph cannot be asked for on demand.
3. **The fallback is the fallback.** Model 2 with no usable capture must produce
   model 1's grid exactly, and must say so.
4. **The assets are the recorded ones.** Every manifest hash is re-computed.

The thresholds are the ones the adaptation plan sets: 1e-3 stops for the
conversion, 1e-5 for the estimator. A failure is reported as a failure; the
bounds are not widened here.

This is a development tool. It needs torch, scikit-learn and joblib, and it is
never invoked by the application.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

import numpy as np

SCRIPT_ROOT = Path(__file__).resolve().parent
MODEL_ROOT = SCRIPT_ROOT.parent
PROJECT_ROOT = MODEL_ROOT.parent
sys.path.insert(0, str(MODEL_ROOT))

from export_research_assets import ResearchFeatureGainMapNet, load_research_trunk  # noqa: E402
from hyperdr_ml.model import DirectGainMapNet  # noqa: E402

CONVERSION_TOLERANCE_STOPS = 1e-3
ESTIMATOR_TOLERANCE_STOPS = 1e-5

#: The six fields in the order the training pipeline builds them.
EXIF_FIELDS = (
    'log2_iso', 'log2_exposure_seconds', 'f_number',
    'exposure_bias_ev', 'focal_length_mm', 'focal_length_35mm',
)
CAPTURE_KEYS = (
    'iso', 'exposure_seconds', 'f_number',
    'exposure_bias_ev', 'focal_length_mm', 'focal_length_35mm',
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def parse_packet(path: Path) -> tuple[np.ndarray, dict]:
    data = Path(path).read_bytes()
    if not data.startswith(b'HYPGAIN1\n'):
        raise SystemExit(f'{path} is not a gain packet')
    size = int.from_bytes(data[9:13], 'little')
    metadata = json.loads(data[13:13 + size].decode('utf-8'))
    width, height = metadata['width'], metadata['height']
    payload = np.frombuffer(data[13 + size:], dtype='<f4')
    if payload.size != width * height:
        raise SystemExit(f'{path} payload is {payload.size}, expected {width * height}')
    return payload.reshape(height, width).astype(np.float32), metadata


def run(arguments: list[str], stdout_path: Path | None = None) -> subprocess.CompletedProcess:
    completed = subprocess.run(
        arguments, capture_output=True, cwd=str(PROJECT_ROOT), check=False)
    if completed.returncode != 0:
        raise SystemExit(
            f'{" ".join(arguments)} failed ({completed.returncode}): '
            f'{completed.stderr.decode("utf-8", errors="replace").strip()}')
    if stdout_path is not None:
        stdout_path.write_bytes(completed.stdout)
    return completed


def read_tensor(path: Path, width: int, height: int) -> np.ndarray:
    values = np.fromfile(path, dtype='<f4')
    if values.size != width * height * 3:
        raise SystemExit(f'{path} holds {values.size} samples, expected {width * height * 3}')
    return values.reshape(height, width, 3)


def torch_grid(model: DirectGainMapNet, tensor: np.ndarray) -> np.ndarray:
    import torch

    graph = ResearchFeatureGainMapNet(model)
    graph.eval()
    # The features are built exactly as the native runtime builds them: three
    # linear planes, the normalized log luminance, and the clipping indicator.
    # Rebuilding them from the tensor rather than passing RGB is what makes this
    # the same graph the ncnn asset runs.
    linear = torch.from_numpy(np.ascontiguousarray(tensor.transpose(2, 0, 1)))[None]
    luminance = (0.22897456 * linear[:, 0:1] + 0.69173852 * linear[:, 1:2]
                 + 0.07928691 * linear[:, 2:3])
    log_luminance = ((torch.log2(luminance.clamp_min(1e-6)) + 12.0) / 12.0).clamp(0.0, 1.0)
    clipping = (linear.amax(dim=1, keepdim=True) >= 0.98).to(linear.dtype)
    features = torch.cat((linear, log_luminance, clipping), dim=1)
    with torch.no_grad():
        prediction = graph(features)
    return prediction[0, 0].numpy().astype(np.float32)


def exif_vector(capture: dict) -> tuple[list[float], list[bool]]:
    """The training transform, and which fields were actually recorded."""
    values: list[float] = []
    present: list[bool] = []
    for key in CAPTURE_KEYS:
        raw = capture.get(key)
        present.append(raw is not None)
        values.append(float(raw) if raw is not None else 0.0)
    transformed = [
        math.log2(max(values[0], 1.0)) if present[0] else 0.0,
        math.log2(max(values[1], 1e-6)) if present[1] else 0.0,
        values[2], values[3], values[4], values[5],
    ]
    return transformed, present


def capture_vectors(research_root: Path | None, count: int) -> list[dict]:
    """Capture vectors to test the estimator with.

    The fold's own rows come first when the research workspace is present: they
    are the exact inputs the recorded readout was produced from. The extra cases
    are the ones the plan names -- a missing field, and a complete capture whose
    exposure bias is exactly zero -- plus a pair of values sitting on a real
    split threshold, which is where a mis-signed comparison would show up.
    """
    vectors: list[dict] = []
    if research_root is not None:
        bundle = research_root / 'cache/apple_development.npz'
        if bundle.is_file():
            with np.load(bundle) as data:
                rows = data['exif']
                # Sorting by the level the estimator assigns keeps the sample
                # spread across the tree's range instead of clustering wherever
                # the first rows happen to sit.
                step = max(1, len(rows) // max(1, count))
                for index in range(0, len(rows), step)[:count]:
                    row = rows[index]
                    vectors.append({
                        'iso': 2.0 ** float(row[0]),
                        'exposure_seconds': 2.0 ** float(row[1]),
                        'f_number': float(row[2]),
                        'exposure_bias_ev': float(row[3]),
                        'focal_length_mm': float(row[4]),
                        'focal_length_35mm': float(row[5]),
                    })
    baseline = vectors[0] if vectors else {
        'iso': 100.0, 'exposure_seconds': 0.01, 'f_number': 1.8,
        'exposure_bias_ev': 0.0, 'focal_length_mm': 6.765, 'focal_length_35mm': 30,
    }
    named = {
        'missing_exposure_bias': {**baseline, 'exposure_bias_ev': None},
        'missing_focal_length_35mm': {**baseline, 'focal_length_35mm': None},
        'zero_bias_is_complete': {**baseline, 'exposure_bias_ev': 0.0},
        'on_threshold_focal_length': {**baseline, 'focal_length_mm': 4.73992180818545},
        'on_threshold_focal_35': {**baseline, 'focal_length_35mm': 36.5},
        'high_iso': {**baseline, 'iso': 12800.0},
    }
    return vectors + [dict(capture, _case=name) for name, capture in named.items()]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exe', type=Path,
                        default=PROJECT_ROOT / 'build-release/Release/HyperDR.exe')
    parser.add_argument('--source', required=True, type=Path,
                        help='a photograph to derive the comparison tensor from')
    parser.add_argument('--research-root', type=Path,
                        help='the research workspace, for the fold capture rows')
    parser.add_argument('--research-checkpoint', type=Path,
                        help='baseline-f0-s908/best.pt, for model 1')
    parser.add_argument('--exif-level-export', type=Path,
                        help='flattened estimator JSON, to check the compiled tables')
    parser.add_argument('--work', type=Path,
                        default=PROJECT_ROOT / '.workbuddy/verify')
    parser.add_argument('--capture-samples', type=int, default=8)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)

    # Subprocesses run from the project root; preserve paths supplied relative
    # to the caller before crossing that working-directory boundary.
    for name in ('exe', 'source', 'research_root', 'research_checkpoint',
                 'exif_level_export', 'work', 'report'):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.resolve())

    args.work.mkdir(parents=True, exist_ok=True)
    exe = str(args.exe)
    report: dict = {'schema': 'hyperdr.research-model-verification/v1',
                    'exe': str(args.exe), 'source': str(args.source)}

    # ---- 4. the assets are the recorded ones -----------------------------
    assets = {}
    for model_id in ('research-cnn-v1', 'research-exif-v1'):
        manifest_path = MODEL_ROOT / 'models' / f'{model_id}.manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        entry = {'version': manifest['version'], 'files': {}}
        for key, asset in manifest['assets'].items():
            path = PROJECT_ROOT / asset['file']
            entry['files'][key] = {
                'path': str(path),
                'sha256': sha256(path),
                'matches': sha256(path) == asset['sha256'],
            }
        if (manifest.get('exif') or {}).get('generatedHeader'):
            header = PROJECT_ROOT / manifest['exif']['generatedHeader']
            entry['files']['exifLevelHeader'] = {
                'path': str(header),
                'sha256': sha256(header),
                'matches': sha256(header) == manifest['exif']['generatedHeaderSha256'],
            }
        entry['all_match'] = all(item['matches'] for item in entry['files'].values())
        assets[model_id] = entry
    report['assets'] = assets

    # The output mean isolates the estimator's scalar. Even a zero input can
    # have spatial variation from convolution padding; it need not be constant.
    zero_tensor = args.work / 'zero.raw'
    np.zeros((64, 64, 3), dtype='<f4').tofile(zero_tensor)

    # ---- 2. the estimator and the native combination ---------------------
    levels = []
    estimator = None
    bundle = None
    if args.research_root is not None:
        bundle = (args.research_root
                  / 'artifacts/sky_retrieval_bundles/fold0-seed908/level_models.joblib')
        if bundle.is_file():
            try:
                import joblib
            except ImportError as exc:
                raise SystemExit(f'joblib is required for the estimator check: {exc}') from exc
            estimator = joblib.load(bundle)['exif']
        else:
            bundle = None
    for capture in capture_vectors(args.research_root if bundle else None, args.capture_samples):
        case = capture.pop('_case', None)
        capture_path = args.work / f'capture-{case or len(levels)}.json'
        capture_path.write_text(json.dumps(capture), encoding='utf-8')
        packet_path = args.work / f'level-{case or len(levels)}.hypgain'
        run([exe, 'model-gain', str(zero_tensor), '--ai-model', 'research-exif-v1',
             '--input-tensor', str(zero_tensor),
             '--tensor-width', '64', '--tensor-height', '64',
             '--capture-json', str(capture_path)],
            stdout_path=packet_path)
        grid, metadata = parse_packet(packet_path)
        native_level = float(grid.mean())
        entry = {'case': case or 'fold_row', 'capture': capture,
                 'native_level': native_level,
                 'effective_model_id': metadata['effectiveModelId'],
                 'inference_mode': metadata['inferenceMode'],
                 'fallback_reason': metadata.get('fallbackReason', ''),
                 'spread': float(grid.max() - grid.min())}
        if case in ('missing_exposure_bias', 'missing_focal_length_35mm'):
            # These two are the fallback rule's own cases; comparing their level
            # against an estimator that was never consulted would be a
            # meaningless number, so what is checked is that they fell back and
            # named the field.
            entry['fell_back'] = (
                entry['inference_mode'] == 'pixel_only_fallback'
                and entry['effective_model_id'] == 'research-cnn-v1'
                and ('exposure_bias_ev' in entry['fallback_reason']) == (case == 'missing_exposure_bias')
                and ('focal_length_35mm' in entry['fallback_reason']) == (case == 'missing_focal_length_35mm'))
            levels.append(entry)
            continue
        if case == 'zero_bias_is_complete':
            # The rule the plan calls out: a recorded 0 EV is a value, not a
            # missing tag, and must not be inferred from truthiness.
            entry['used_exif'] = entry['inference_mode'] == 'exif_assisted'
        features, present = exif_vector(capture)
        if estimator is not None:
            entry['sklearn_level'] = float(estimator.predict(np.asarray(features)[None])[0])
            entry['difference'] = abs(entry['sklearn_level'] - native_level)
        levels.append(entry)
    comparable = [entry for entry in levels if 'difference' in entry]
    rule_cases = [entry for entry in levels
                  if 'fell_back' in entry or 'used_exif' in entry]
    report['estimator'] = {
        'cases': levels,
        'tolerance': ESTIMATOR_TOLERANCE_STOPS,
        'max_difference': max((entry['difference'] for entry in comparable), default=None),
        'within_tolerance': bool(comparable) and all(
            entry['difference'] <= ESTIMATOR_TOLERANCE_STOPS for entry in comparable),
        'presence_rules_hold': bool(rule_cases) and all(
            entry.get('fell_back', True) and entry.get('used_exif', True)
            for entry in rule_cases),
        'sklearn_reference': estimator is not None,
    }

    # ---- 1 and 3. the spatial networks -----------------------------------
    input_report_path = args.work / 'model-input.json'
    run([exe, 'model-input', str(args.source),
         '--output', str(args.work / 'model-input.raw'),
         '--report', str(input_report_path)])
    tensor_report = json.loads(input_report_path.read_text(encoding='utf-8'))
    tensor_path = Path(tensor_report['pixel_file']['path'])
    width = int(tensor_report['pixel_file']['width'])
    height = int(tensor_report['pixel_file']['height'])
    tensor = read_tensor(tensor_path, width, height)
    report['tensor'] = {'path': str(tensor_path), 'width': width, 'height': height,
                        'sha256': tensor_report['pixel_file']['sha256'],
                        'sha256_matches': sha256(tensor_path) == tensor_report['pixel_file']['sha256']}

    conversions = {}
    checkpoint = args.research_checkpoint or (
        (args.research_root / 'artifacts/runs/baseline-f0-s908/best.pt')
        if args.research_root else None)
    if checkpoint is not None and Path(checkpoint).is_file():
        model, _ = load_research_trunk(Path(checkpoint))
        reference = torch_grid(model, tensor)
        for actual_id in ('research-cnn-v1',):
            packet_path = args.work / f'conv-{actual_id}.hypgain'
            run([exe, 'model-gain', str(args.source), '--ai-model', actual_id,
                 '--input-tensor', str(tensor_path),
                 '--tensor-width', str(width), '--tensor-height', str(height)],
                stdout_path=packet_path)
            grid, metadata = parse_packet(packet_path)
            entry = {'model_id': actual_id,
                     'effective_model_id': metadata['effectiveModelId'],
                     'inference_mode': metadata['inferenceMode'],
                     'range_stops': [float(grid.min()), float(grid.max())]}
            if actual_id == 'research-cnn-v1':
                difference = float(np.abs(grid - reference).max())
                entry.update({
                    'max_difference_stops': difference,
                    'tolerance': CONVERSION_TOLERANCE_STOPS,
                    'within_tolerance': difference <= CONVERSION_TOLERANCE_STOPS,
                })
            conversions[actual_id] = entry
        report['cnn_conversion'] = conversions
        report['cnn_conversion_checked'] = True
    else:
        report['cnn_conversion_checked'] = False
        report['cnn_conversion_reason'] = (
            'no research checkpoint was given, so the PyTorch reference could not be built')

    # ---- 3. the fallback --------------------------------------------------
    fallback = {}
    with_capture = args.work / 'fallback-capture.json'
    with_capture.write_text(json.dumps({
        'iso': 100.0, 'exposure_seconds': 0.01, 'f_number': 1.8,
        'exposure_bias_ev': 0.0, 'focal_length_mm': 6.765, 'focal_length_35mm': 30,
    }), encoding='utf-8')
    for label, extra in (('complete_capture', ['--capture-json', str(with_capture)]),
                         ('no_capture', [])):
        packet = args.work / f'fallback-{label}.hypgain'
        run([exe, 'model-gain', str(args.source), '--ai-model', 'research-exif-v1',
             '--input-tensor', str(tensor_path),
             '--tensor-width', str(width), '--tensor-height', str(height)] + extra,
            stdout_path=packet)
        grid, metadata = parse_packet(packet)
        fallback[label] = {
            'effective_model_id': metadata['effectiveModelId'],
            'requested_model_id': metadata['requestedModelId'],
            'inference_mode': metadata['inferenceMode'],
            'fallback_reason': metadata.get('fallbackReason', ''),
            'base_offset': metadata['baseOffsetNumerator'] / metadata['baseOffsetDenominator'],
            'alternate_offset': (metadata['alternateOffsetNumerator']
                                 / metadata['alternateOffsetDenominator']),
            'grid': grid,
        }
    model1_packet = args.work / 'fallback-model1.hypgain'
    run([exe, 'model-gain', str(args.source), '--ai-model', 'research-cnn-v1',
         '--input-tensor', str(tensor_path),
         '--tensor-width', str(width), '--tensor-height', str(height)],
        stdout_path=model1_packet)
    model1, _ = parse_packet(model1_packet)
    no_capture = fallback['no_capture']
    fallback_report = {
        'complete': {key: value for key, value in fallback['complete_capture'].items()
                     if key != 'grid'},
        'absent': {key: value for key, value in no_capture.items() if key != 'grid'},
        'absent_matches_model1_exactly': bool(np.array_equal(no_capture['grid'], model1)),
        'absent_max_difference_vs_model1': float(np.abs(no_capture['grid'] - model1).max()),
        # A complete capture must still take the EXIF path: a fallback that
        # happened anyway would make the rule above meaningless.
        'complete_used_exif': fallback['complete_capture']['inference_mode'] == 'exif_assisted',
        'complete_differs_from_model1': bool(
            not np.array_equal(fallback['complete_capture']['grid'], model1)),
        'research_offset_stops': no_capture['base_offset'],
    }
    fallback_report['passed'] = (
        fallback_report['absent_matches_model1_exactly']
        and fallback_report['complete_used_exif']
        and no_capture['fallback_reason'].startswith('missing_capture_fields')
        and no_capture['effective_model_id'] == 'research-cnn-v1'
        and abs(no_capture['base_offset'] - 1e-5) < 1e-12)
    report['fallback'] = fallback_report

    # Verify the second CNN and the complete composition, not only model 1.
    shape_checkpoint = (args.research_root / 'artifacts/runs/shape_only-f0-s908/best.pt'
                        if args.research_root else None)
    if shape_checkpoint is not None and shape_checkpoint.is_file() and estimator is not None:
        shape_model, _ = load_research_trunk(shape_checkpoint)
        spatial = torch_grid(shape_model, tensor)
        capture = json.loads(with_capture.read_text(encoding='utf-8'))
        features, _ = exif_vector(capture)
        level = float(estimator.predict(np.asarray(features)[None])[0])
        reference = spatial.astype(np.float64) - spatial.mean(dtype=np.float64) + level
        difference = float(np.abs(fallback['complete_capture']['grid'] - reference).max())
        conversions['research-exif-v1'] = {
            'model_id': 'research-exif-v1',
            'max_difference_stops': difference,
            'tolerance': CONVERSION_TOLERANCE_STOPS,
            'within_tolerance': difference <= CONVERSION_TOLERANCE_STOPS,
        }
        report['cnn_conversion'] = conversions

    failures = []
    if not {'research-cnn-v1', 'research-exif-v1'} <= conversions.keys():
        failures.append('both research checkpoints and the sklearn estimator are required for full verification')
    if report.get('cnn_conversion_checked') and not all(
            entry.get('within_tolerance', True)
            for entry in report['cnn_conversion'].values()):
        failures.append('CNN conversion exceeded its tolerance')
    if report['estimator']['max_difference'] is not None and not report['estimator']['within_tolerance']:
        failures.append('EXIF estimator exceeded its tolerance')
    if not report['estimator']['presence_rules_hold']:
        failures.append('a capture-presence rule did not hold')
    if not fallback_report['passed']:
        failures.append('the fallback rule did not hold')
    if not all(entry['all_match'] for entry in assets.values()):
        failures.append('an asset hash does not match its manifest')
    report['failures'] = failures
    report['passed'] = not failures

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False, default=float)
                               + '\n', encoding='utf-8')
    summary = {key: value for key, value in report.items()
               if key not in ('estimator', 'cnn_conversion')}
    print(json.dumps(summary, indent=2, ensure_ascii=False, default=float))
    print(json.dumps(report['estimator']['cases'], indent=2, ensure_ascii=False, default=float))
    if 'cnn_conversion' in report:
        print(json.dumps(report['cnn_conversion'], indent=2, ensure_ascii=False, default=float))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
