#!/usr/bin/env python3
"""Score denoisers on developed RawNIND pairs (noisy vs ground truth).

Inputs are the extended linear Display P3 TIFFs written by ``develop_raw``:
``<scene>__GT_<iso>.tiff`` (ground truth), ``<scene>__<iso>.tiff`` (noisy, Apple
NR off) and ``<scene>__<iso>__<tag>.tiff`` (a system baseline such as ``applenr`` for
decoder 8's default NR or ``apple9`` for decoder 9, scored under that tag).

The noisy capture and the ground truth differ slightly in exposure, so every
candidate is mapped onto the ground truth with per-channel gains measured
between the *noisy* frame and the ground truth on blurred mid-tones; the same
gains apply to every candidate of that capture. Scores are PSNR and SSIM after
a common display encoding: the scene is scaled so the ground truth's 99.5th
luminance percentile lands at 0.9, clipped to [0, 1] and sRGB-encoded.

    python3 eval_pairs.py --dev build/denoise/dev --weights .../NAFNet-SIDD-width32.pth
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import time

import numpy as np
import tifffile
import torch
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nafnet  # noqa: E402


def srgb_encode(x: np.ndarray | torch.Tensor):
    if isinstance(x, torch.Tensor):
        x = x.clamp(0, 1)
        return torch.where(x <= 0.0031308, 12.92 * x, 1.055 * x.clamp_min(1e-8) ** (1 / 2.4) - 0.055)
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(np.maximum(x, 1e-8), 1 / 2.4) - 0.055)


def srgb_decode(y: torch.Tensor) -> torch.Tensor:
    return torch.where(y <= 0.04045, y / 12.92, ((y.clamp_min(0) + 0.055) / 1.055) ** 2.4)


def luminance(x: np.ndarray) -> np.ndarray:
    # Display P3 (D65) luminance weights.
    return 0.2289746 * x[..., 0] + 0.6917385 * x[..., 1] + 0.0792869 * x[..., 2]


def box(x: np.ndarray, k: int = 8) -> np.ndarray:
    h, w = (x.shape[0] // k) * k, (x.shape[1] // k) * k
    return x[:h, :w].reshape(h // k, k, w // k, k, -1).mean(axis=(1, 3))


def channel_gains(noisy: np.ndarray, gt: np.ndarray) -> np.ndarray:
    n, g = box(noisy), box(gt)
    lum = luminance(g)
    mask = (lum > np.percentile(lum, 20)) & (lum < np.percentile(lum, 95))
    return np.array([np.sum(g[..., c][mask] * n[..., c][mask]) / np.sum(n[..., c][mask] ** 2) for c in range(3)])


def ssim(a: np.ndarray, b: np.ndarray) -> float:
    """Mean SSIM over channels, 11×11 Gaussian window (sigma 1.5)."""
    ta = torch.from_numpy(a).permute(2, 0, 1)[None].float()
    tb = torch.from_numpy(b).permute(2, 0, 1)[None].float()
    g = torch.exp(-((torch.arange(11) - 5.0) ** 2) / (2 * 1.5 ** 2))
    g = (g / g.sum())
    win = (g[:, None] * g[None, :]).expand(3, 1, 11, 11)
    mu_a, mu_b = F.conv2d(ta, win, groups=3), F.conv2d(tb, win, groups=3)
    s_aa = F.conv2d(ta * ta, win, groups=3) - mu_a ** 2
    s_bb = F.conv2d(tb * tb, win, groups=3) - mu_b ** 2
    s_ab = F.conv2d(ta * tb, win, groups=3) - mu_a * mu_b
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    m = ((2 * mu_a * mu_b + c1) * (2 * s_ab + c2)) / ((mu_a ** 2 + mu_b ** 2 + c1) * (s_aa + s_bb + c2))
    return float(m.mean())


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    return float(10 * np.log10(1.0 / np.mean((a - b) ** 2)))


def crops(shape, size: int, count: int, seed: int):
    rng = np.random.default_rng(seed)
    h, w = shape[:2]
    out = [((h - size) // 2, (w - size) // 2)]
    while len(out) < count:
        out.append((int(rng.integers(0, h - size)), int(rng.integers(0, w - size))))
    return out


class Candidate:
    def __init__(self, name: str, model: nafnet.NAFNet, device: str, encoding: str):
        self.name, self.model, self.device, self.encoding = name, model.to(device), device, encoding

    @torch.no_grad()
    def __call__(self, linear: np.ndarray, scale: float) -> np.ndarray:
        x = torch.from_numpy(np.ascontiguousarray(linear.transpose(2, 0, 1)))[None].to(self.device)
        x = x * scale
        if self.encoding == "srgb":
            inp = srgb_encode(x)
        elif self.encoding == "linear":
            inp = x
        else:
            raise ValueError(self.encoding)
        inp, h, w = nafnet.pad_to_multiple(inp, self.model.multiple)
        out = self.model(inp)[..., :h, :w]
        if self.encoding == "srgb":
            out = srgb_decode(out.clamp(0, 1))
            # Values the encoding clipped (scene above the display white) keep the input.
            out = torch.where(x > 1, x, out)
        out = out / scale
        return out[0].permute(1, 2, 0).float().cpu().numpy()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dev", type=Path, required=True)
    parser.add_argument("--weights", type=Path, action="append", required=True)
    parser.add_argument("--encoding", action="append", default=None, choices=["srgb", "linear"])
    parser.add_argument("--pool", default="local", choices=["local", "global"])
    parser.add_argument("--crop", type=int, default=1024)
    parser.add_argument("--crops", type=int, default=3)
    parser.add_argument("--scene", action="append", default=None)
    parser.add_argument("--save", type=Path, default=None, help="write the centre crop of each candidate as PNG")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    encodings = args.encoding or ["srgb"]

    candidates = []
    for weights in args.weights:
        config = nafnet.SIDD_WIDTH64 if "width64" in weights.name else nafnet.SIDD_WIDTH32
        model = nafnet.load_published(str(weights), config, pool=args.pool)
        for encoding in encodings:
            candidates.append(Candidate(f"{weights.stem}/{encoding}/{args.pool}", model, device, encoding))

    pattern = re.compile(r"^(.+?)__(GT_)?(\d+)(?:__(\w+))?\.tiff$")
    files: dict[str, dict] = {}
    for path in sorted(args.dev.glob("*.tiff")):
        m = pattern.match(path.name)
        if not m:
            continue
        scene, gt, iso, apple = m.group(1), m.group(2), int(m.group(3)), m.group(4)
        entry = files.setdefault(scene, {"noisy": {}, "baselines": {}})
        if gt:
            entry["gt"] = path
        elif apple:
            entry["baselines"].setdefault(iso, {})[apple] = path
        else:
            entry["noisy"][iso] = path

    rows = []
    for scene, entry in files.items():
        if args.scene and scene not in args.scene:
            continue
        gt_full = tifffile.imread(entry["gt"])[..., :3]
        for iso, noisy_path in sorted(entry["noisy"].items()):
            noisy_full = tifffile.imread(noisy_path)[..., :3]
            baselines = {tag: tifffile.imread(path)[..., :3] for tag, path in sorted(entry["baselines"].get(iso, {}).items())}
            for tag, image in baselines.items():
                if image.shape != gt_full.shape:
                    raise SystemExit(f"{scene} ISO{iso} {tag}: shape {image.shape} != {gt_full.shape}")
            gains = channel_gains(noisy_full, gt_full)
            scale = 0.9 / float(np.percentile(luminance(gt_full[::4, ::4]), 99.5))
            for index, (y, x) in enumerate(crops(gt_full.shape, args.crop, args.crops, seed=iso)):
                sl = (slice(y, y + args.crop), slice(x, x + args.crop))
                gt = gt_full[sl]
                noisy = noisy_full[sl]
                ref = srgb_encode(gt * scale)
                results = {"noisy": noisy, **{tag: image[sl] for tag, image in baselines.items()}}
                timings = {}
                for candidate in candidates:
                    start = time.perf_counter()
                    results[candidate.name] = candidate(noisy * gains, scale) / gains
                    if device == "mps":
                        torch.mps.synchronize()
                    timings[candidate.name] = time.perf_counter() - start
                for name, image in results.items():
                    shown = srgb_encode(image * gains * scale)
                    rows.append({"scene": scene, "iso": iso, "crop": index, "method": name,
                                 "psnr": psnr(shown, ref), "ssim": ssim(shown, ref),
                                 "seconds": timings.get(name)})
                    if args.save and index == 0:
                        args.save.mkdir(parents=True, exist_ok=True)
                        from PIL import Image
                        tag = name.replace("/", "_")
                        Image.fromarray((shown * 255 + 0.5).astype(np.uint8)).save(args.save / f"{scene}_{iso}_{tag}.png")
                if args.save and index == 0:
                    from PIL import Image
                    Image.fromarray((ref * 255 + 0.5).astype(np.uint8)).save(args.save / f"{scene}_{iso}_GT.png")
            print(f"{scene} ISO{iso} gains={np.round(gains, 3).tolist()}", file=sys.stderr)

    methods = list(dict.fromkeys(r["method"] for r in rows))
    print(f"{'scene':28s} {'iso':>6s} " + " ".join(f"{m[:26]:>26s}" for m in methods))
    keys = sorted({(r["scene"], r["iso"]) for r in rows})
    for scene, iso in keys:
        cells = []
        for m in methods:
            sel = [r for r in rows if r["scene"] == scene and r["iso"] == iso and r["method"] == m]
            cells.append(f"{np.mean([r['psnr'] for r in sel]):6.2f}dB/{np.mean([r['ssim'] for r in sel]):.3f}".rjust(26))
        print(f"{scene[:28]:28s} {iso:6d} " + " ".join(cells))
    for m in methods:
        sel = [r for r in rows if r["method"] == m]
        t = [r["seconds"] for r in sel if r["seconds"] is not None]
        timing = f"  {np.mean(t):.3f}s per {args.crop}² crop" if t else ""
        print(f"mean {m:40s} {np.mean([r['psnr'] for r in sel]):6.2f} dB  SSIM {np.mean([r['ssim'] for r in sel]):.4f}{timing}")
    if args.json:
        args.json.write_text(json.dumps(rows, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
