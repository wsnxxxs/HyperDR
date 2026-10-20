#!/usr/bin/env python3
"""Generate the ncnn reference data for the Core ML tolerance gate.

The gate compares the Core ML AI gain model against the ncnn path that ships
today, on identical inputs. Inputs must therefore be *stored*, not regenerated at
test time: two decoders, two languages and a different machine must produce the
same five feature planes, and the only way to guarantee that is to hand both
sides the same bytes.

Each case stores:

* ``<name>.png`` -- the developed linear Display-P3 SDR base, encoded through the
  sRGB transfer function into 8 bits. Both sides decode it with the same formula
  and both then run the engine's feature planes on the result, so the comparison
  covers the preprocessing as well as the network.
* ``<name>.ncnn.f32`` -- the gain grid the shipped ncnn model returns for that
  base, little-endian float32, row-major, stride-16 cells. This is the reference
  the Core ML model has to match, not the ONNX export.
* ``<name>-x4.png``/``.f32`` for one case: the same base nearest-neighbour
  scaled by four, so the gate also covers the production analysis scale (long
  side 1024) without storing a megapixel tensor.

The tensors come from ``HyperDR model-input`` on the RAW fixtures, whose output
is exactly what the deployed preprocessing feeds the network, plus synthetic
bases for the extremes (clipped highlights, deep shadow) a small fixture set does
not reach.

    python3 HyperDR_Model/scripts/make_coreml_tolerance_fixtures.py \
        --hyperdr build/HyperDR \
        --output apps/apple/Packages/HyperDRRender/Tests/HyperDRRenderTests/Fixtures/ModelGain
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

import numpy as np

MODEL_STRIDE = 16
PACKET_MAGIC = b"HYPGAIN1\n"
SRGB_THRESHOLD = 0.04045


def srgb_encode(linear: np.ndarray) -> np.ndarray:
    value = np.clip(linear, 0.0, 1.0)
    return np.where(value <= 0.0031308,
                    value * 12.92,
                    1.055 * np.power(value, 1.0 / 2.4) - 0.055)


def srgb_decode(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(value <= SRGB_THRESHOLD,
                    value / 12.92,
                    np.power((value + 0.055) / 1.055, 2.4))


def store_png(path: Path, rgb8: np.ndarray) -> np.ndarray:
    """Write an untagged 8-bit RGB PNG and return the values read back from it.

    Untagged is deliberate: a profile chunk would invite a colour match on the
    reading side and the two implementations would no longer see the same bytes.
    Reading the file back makes the reference depend on the stored asset rather
    than on the array that happened to be in memory first.
    """
    from PIL import Image

    Image.fromarray(rgb8, mode="RGB").save(path, format="PNG", optimize=True, compress_level=9)
    stored = np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)
    if stored.shape != rgb8.shape or not np.array_equal(stored, rgb8):
        raise SystemExit(f"{path}: the stored PNG does not round-trip")
    return stored


def read_tensor(path: Path, width: int, height: int) -> np.ndarray:
    values = np.fromfile(path, dtype="<f4")
    expected = width * height * 3
    if values.size != expected:
        raise SystemExit(f"{path}: expected {expected} floats, found {values.size}")
    return values.reshape(height, width, 3)


def read_gain_packet(data: bytes) -> tuple[np.ndarray, dict]:
    if not data.startswith(PACKET_MAGIC):
        raise SystemExit("model-gain did not return a gain packet")
    offset = len(PACKET_MAGIC)
    (length,) = struct.unpack_from("<I", data, offset)
    offset += 4
    report = json.loads(data[offset:offset + length])
    offset += length
    values = np.frombuffer(data[offset:], dtype="<f4")
    if values.size != report["width"] * report["height"]:
        raise SystemExit("gain packet pixel count does not match its report")
    return values.reshape(report["height"], report["width"]), report


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(command)} failed:\n{result.stderr.decode()[:2000]}")
    return result


def develop(hyperdr: Path, image: Path, long_side: int, workdir: Path) -> np.ndarray:
    tensor = workdir / "tensor.f32"
    report = workdir / "tensor.json"
    run([str(hyperdr), "model-input", str(image), "--output", str(tensor),
         "--report", str(report), "--long-side", str(long_side), "--clamp-srgb"])
    geometry = json.loads(report.read_text())["geometry"]
    width, height = geometry["model_tensor_size"]
    values = read_tensor(tensor, width, height)
    if not np.isfinite(values).all():
        raise SystemExit("developed tensor contains non-finite samples")
    return np.clip(values, 0.0, 1.0)


def ncnn_gain(hyperdr: Path, image: Path, tensor: np.ndarray, workdir: Path) -> tuple[np.ndarray, dict]:
    height, width = tensor.shape[:2]
    path = workdir / "tensor.f32"
    np.ascontiguousarray(tensor, dtype="<f4").tofile(path)
    result = run([str(hyperdr), "model-gain", str(image), "--ai-model",
                  "--input-tensor", str(path), "--tensor-width", str(width),
                  "--tensor-height", str(height)])
    return read_gain_packet(result.stdout)


def smooth_field(height: int, width: int, rng: np.random.Generator) -> np.ndarray:
    """Low-frequency luminance with visible structure, in [0, 1]."""
    ys = np.linspace(0.0, np.pi, height, dtype=np.float64)[:, None]
    xs = np.linspace(0.0, np.pi, width, dtype=np.float64)[None, :]
    field = 0.5 + 0.45 * np.sin(1.7 * xs + 0.4) * np.cos(1.1 * ys - 0.3)
    field += 0.05 * rng.standard_normal((height, width))
    return np.clip(field, 0.0, 1.0)


def synthetic_clipped(height: int, width: int, rng: np.random.Generator) -> np.ndarray:
    """A bright sky that clips, a saturated subject, and a deep-shadow corner."""
    base = smooth_field(height, width, rng) ** 1.6
    tint = np.stack((1.15 * base, 1.0 * base, 0.72 * base), axis=-1)
    tint[: height // 4, :, :] = 1.35  # straight into the clipping plane
    tint[height // 2:, width // 2:, 2] += 0.25  # blue-heavy shadow
    corners = np.minimum.outer(np.linspace(0, 1, height), np.linspace(1, 0, width))[:, :, None]
    tint *= 1.0 - 0.85 * corners
    return np.clip(tint, 0.0, 1.0)


def synthetic_shadow(height: int, width: int, rng: np.random.Generator) -> np.ndarray:
    """Mostly near-black with a small specular patch: the low-signal end."""
    base = 0.002 + 0.02 * smooth_field(height, width, rng) ** 3
    tint = np.stack((base, base * 0.98, base * 1.03), axis=-1)
    centre_y, centre_x = height // 3, width // 3
    tint[centre_y:centre_y + height // 6, centre_x:centre_x + width // 6] = 0.92
    return np.clip(tint, 0.0, 1.0)


def upsample_nearest(tensor: np.ndarray, factor: int) -> np.ndarray:
    return np.repeat(np.repeat(tensor, factor, axis=0), factor, axis=1)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hyperdr", type=Path, default=Path("build/HyperDR"))
    parser.add_argument("--fixtures", type=Path, default=Path("build/fixtures"))
    parser.add_argument("--output", type=Path,
                        default=Path("apps/apple/Packages/HyperDRRender/Tests/HyperDRRenderTests/Fixtures/ModelGain"))
    parser.add_argument("--long-side", type=int, default=192)
    parser.add_argument("--synthetic-size", type=int, default=96)
    parser.add_argument("--upsample-case", default="canon",
                        help="case that also gets a long-side-1024 variant")
    parser.add_argument("--upsample-factor", type=int, default=4)
    args = parser.parse_args(argv)

    if not args.hyperdr.exists():
        raise SystemExit(f"{args.hyperdr} is not built; run scripts/test.py native first")
    if args.long_side % MODEL_STRIDE:
        raise SystemExit("--long-side must be a multiple of 16")
    args.output.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(20261021)
    sources = [
        ("canon", args.fixtures / "canon-eos-5d-iii-lossy.dng"),
        ("leica", args.fixtures / "leica-c-portrait.RWL"),
    ]
    cases: list[tuple[dict, np.ndarray, Path | None]] = []
    summary: list[str] = []
    with tempfile.TemporaryDirectory() as temporary:
        workdir = Path(temporary)
        for name, image in sources:
            if not image.exists():
                raise SystemExit(f"missing fixture {image}; run scripts/fetch_test_fixtures.py")
            case = {"name": name, "source": image.name, "kind": "raw-fixture"}
            base = develop(args.hyperdr, image, args.long_side, workdir)
            cases.append((case, base, image))
        # The synthetic bases only have to reach the extremes, not real
        # resolution, so they are stored small.
        small = args.synthetic_size
        cases.append(({"name": "clipped", "source": "synthetic", "kind": "synthetic"},
                      synthetic_clipped(small, small, rng), None))
        cases.append(({"name": "shadow", "source": "synthetic", "kind": "synthetic"},
                      synthetic_shadow(small, small, rng), None))

        manifest: list[dict] = []
        for case, base, image in cases:
            height, width = base.shape[:2]
            # Quantise through the sRGB transfer function, then decode again: the
            # stored PNG *is* the input, and the ncnn reference is computed from
            # the decoded values, not from the pre-quantisation tensor.
            encoded = np.round(srgb_encode(base) * 255.0).astype(np.uint8)
            stored = store_png(args.output / f"{case['name']}.png", encoded)
            tensor = srgb_decode(stored.astype(np.float64) / 255.0).astype(np.float32)
            reference_arg = image if image is not None else args.fixtures / "canon-eos-5d-iii-lossy.dng"
            gain, report = ncnn_gain(args.hyperdr, reference_arg, tensor, workdir)
            gain.astype("<f4").tofile(args.output / f"{case['name']}.ncnn.f32")
            entry = {
                **case,
                "tensor": [int(height), int(width)],
                "grid": [int(gain.shape[0]), int(gain.shape[1])],
                "ncnnModelId": report["requestedModelId"],
                "ncnnModelVersion": report["modelVersion"],
                "gainMinStops": float(gain.min()),
                "gainMaxStops": float(gain.max()),
            }
            if case["name"] == args.upsample_case:
                # The test reproduces this with the same integer nearest-neighbour
                # replication, so only the reference grid has to be stored.
                factor = args.upsample_factor
                scaled = upsample_nearest(tensor, factor)
                scaled_gain, scaled_report = ncnn_gain(args.hyperdr, reference_arg, scaled, workdir)
                scaled_gain.astype("<f4").tofile(args.output / f"{case['name']}-x{factor}.ncnn.f32")
                entry["upsampledBy"] = factor
                entry["upsampledTensor"] = [int(scaled.shape[0]), int(scaled.shape[1])]
                entry["upsampledGrid"] = [int(scaled_gain.shape[0]), int(scaled_gain.shape[1])]
                entry["upsampledNcnnModelId"] = scaled_report["requestedModelId"]
            manifest.append(entry)
            summary.append(f"{case['name']}: {width}x{height} -> grid {gain.shape[1]}x{gain.shape[0]}, "
                           f"{gain.min():+.3f}..{gain.max():+.3f} stops")

    document = {
        "schema": "hyperdr.model-gain-references/v1",
        "description": "ncnn references for the Core ML tolerance gate; see "
                       "HyperDR_Model/scripts/make_coreml_tolerance_fixtures.py",
        "encoding": {"transfer": "sRGB", "bits": 8, "channels": "RGB",
                     "colorSpace": "linear Display P3 after decode"},
        "gainLayout": "row-major float32 little-endian, signed log2 stops, stride 16",
        "cases": manifest,
    }
    (args.output / "cases.json").write_text(json.dumps(document, indent=2) + "\n")
    for line in summary:
        print(line)
    total = sum(path.stat().st_size for path in args.output.iterdir() if path.is_file())
    print(f"{args.output}: {len(manifest)} cases, {total / 1024:.0f} KiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
