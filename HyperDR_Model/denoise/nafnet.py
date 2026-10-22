"""NAFNet for HyperDR: the published network, made exportable and tile-stable.

Architecture from "Simple Baselines for Image Restoration" (Chen, Chu, Zhang and
Sun, ECCV 2022), https://github.com/megvii-research/NAFNet, MIT License,
Copyright (c) 2022 megvii-model. The layer names match the published
checkpoints, so ``NAFNet-SIDD-width32.pth`` loads with ``strict=True``.

Changes from the published code, none of which change a trained weight:

* ``LayerNorm2d`` is written with ordinary tensor operations instead of a custom
  autograd function, so the network traces and converts to Core ML.
* The channel attention's global average pool is a choice (``pool``):

  - ``"global"``: the published behaviour. Every output pixel depends on the
    mean over the whole input, so a photograph processed in tiles gets a
    different answer per tile and seams at the tile edges.
  - ``"local"``: Test-time Local Converter (Chu et al., "Improving Image
    Restoration by Revisiting Global Information Aggregation", ECCV 2022, the
    same authors' ``local_arch.py``): the mean over a window ``1.5×`` the
    training patch, scaled with each level's stride. Each pixel then depends on
    a bounded neighbourhood, which is what makes tiled inference of a 110MP
    photograph agree with whole-image inference away from the tile border.

* ``noise_map``: an optional extra input channel holding the expected noise
  standard deviation (FFDNet-style conditioning). Off for the published
  weights; used by the HyperDR fine-tune so one model covers every ISO and the
  user's strength control has a meaning beyond blending.
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


class LayerNorm2d(nn.Module):
    def __init__(self, channels: int, eps: float = 1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(channels))
        self.bias = nn.Parameter(torch.zeros(channels))
        self.eps = eps

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        mu = x.mean(1, keepdim=True)
        var = (x - mu).pow(2).mean(1, keepdim=True)
        y = (x - mu) / torch.sqrt(var + self.eps)
        return self.weight.view(1, -1, 1, 1) * y + self.bias.view(1, -1, 1, 1)


class LocalMean(nn.Module):
    """Mean over a ``kernel``-pixel square window, TLC style.

    The window is applied without padding and the result is replicate-padded
    back to the input size, exactly as ``local_arch.AvgPool2d`` does. When the
    window covers the input this is the global mean, as in TLC.
    """

    def __init__(self, kernel: int):
        super().__init__()
        self.kernel = kernel

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h, w = x.shape[-2:]
        k1, k2 = min(h, self.kernel), min(w, self.kernel)
        if k1 == h and k2 == w:
            return x.mean(dim=(2, 3), keepdim=True)
        out = F.avg_pool2d(x, kernel_size=(k1, 1), stride=1)
        out = F.avg_pool2d(out, kernel_size=(1, k2), stride=1)
        _h, _w = out.shape[-2:]
        pad = ((w - _w) // 2, (w - _w + 1) // 2, (h - _h) // 2, (h - _h + 1) // 2)
        return F.pad(out, pad, mode="replicate")


class SimpleGate(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x1, x2 = x.chunk(2, dim=1)
        return x1 * x2


class NAFBlock(nn.Module):
    def __init__(self, c: int, pool: nn.Module, dw_expand: int = 2, ffn_expand: int = 2):
        super().__init__()
        dw = c * dw_expand
        self.conv1 = nn.Conv2d(c, dw, 1)
        self.conv2 = nn.Conv2d(dw, dw, 3, padding=1, groups=dw)
        self.conv3 = nn.Conv2d(dw // 2, c, 1)
        self.sca = nn.Sequential(pool, nn.Conv2d(dw // 2, dw // 2, 1))
        self.sg = SimpleGate()
        ffn = ffn_expand * c
        self.conv4 = nn.Conv2d(c, ffn, 1)
        self.conv5 = nn.Conv2d(ffn // 2, c, 1)
        self.norm1 = LayerNorm2d(c)
        self.norm2 = LayerNorm2d(c)
        self.beta = nn.Parameter(torch.zeros((1, c, 1, 1)))
        self.gamma = nn.Parameter(torch.zeros((1, c, 1, 1)))

    def forward(self, inp: torch.Tensor) -> torch.Tensor:
        x = self.conv2(self.conv1(self.norm1(inp)))
        x = self.sg(x)
        x = x * self.sca(x)
        y = inp + self.conv3(x) * self.beta
        x = self.conv5(self.sg(self.conv4(self.norm2(y))))
        return y + x * self.gamma


def make_pool(kind: str, stride: int, train_size: int) -> nn.Module:
    if kind == "global":
        return nn.AdaptiveAvgPool2d(1)
    if kind == "local":
        return LocalMean(max(1, int(train_size * 1.5) // stride))
    raise ValueError(kind)


class NAFNet(nn.Module):
    def __init__(self, img_channel: int = 3, width: int = 32, middle_blk_num: int = 12,
                 enc_blk_nums=(2, 2, 4, 8), dec_blk_nums=(2, 2, 2, 2),
                 pool: str = "global", train_size: int = 256, noise_map: bool = False):
        super().__init__()
        self.noise_map = noise_map
        self.intro = nn.Conv2d(img_channel + (1 if noise_map else 0), width, 3, padding=1)
        self.ending = nn.Conv2d(width, img_channel, 3, padding=1)
        self.encoders = nn.ModuleList()
        self.decoders = nn.ModuleList()
        self.ups = nn.ModuleList()
        self.downs = nn.ModuleList()
        chan, stride = width, 1
        for num in enc_blk_nums:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan, make_pool(pool, stride, train_size)) for _ in range(num)]))
            self.downs.append(nn.Conv2d(chan, 2 * chan, 2, 2))
            chan, stride = chan * 2, stride * 2
        self.middle_blks = nn.Sequential(*[NAFBlock(chan, make_pool(pool, stride, train_size)) for _ in range(middle_blk_num)])
        for num in dec_blk_nums:
            self.ups.append(nn.Sequential(nn.Conv2d(chan, chan * 2, 1, bias=False), nn.PixelShuffle(2)))
            chan, stride = chan // 2, stride // 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan, make_pool(pool, stride, train_size)) for _ in range(num)]))
        self.multiple = 2 ** len(self.encoders)

    def forward(self, inp: torch.Tensor, sigma: torch.Tensor | None = None) -> torch.Tensor:
        """``inp`` is N×3×H×W with H and W multiples of ``self.multiple``.

        ``sigma`` (N×1×H×W) is required when the model was built with
        ``noise_map=True``. The output is the denoised image, the input plus the
        predicted residual.
        """
        x = torch.cat([inp, sigma], dim=1) if self.noise_map else inp
        x = self.intro(x)
        skips = []
        for encoder, down in zip(self.encoders, self.downs):
            x = encoder(x)
            skips.append(x)
            x = down(x)
        x = self.middle_blks(x)
        for decoder, up, skip in zip(self.decoders, self.ups, skips[::-1]):
            x = decoder(up(x) + skip)
        return self.ending(x) + inp


SIDD_WIDTH32 = dict(width=32, middle_blk_num=12, enc_blk_nums=(2, 2, 4, 8), dec_blk_nums=(2, 2, 2, 2))
SIDD_WIDTH64 = dict(width=64, middle_blk_num=12, enc_blk_nums=(2, 2, 4, 8), dec_blk_nums=(2, 2, 2, 2))


def load_published(path: str, config: dict, pool: str = "local") -> NAFNet:
    """Load a published NAFNet-SIDD checkpoint (``{"params": state_dict}``)."""
    model = NAFNet(**config, pool=pool)
    state = torch.load(path, map_location="cpu", weights_only=True)
    model.load_state_dict(state.get("params", state), strict=True)
    return model.eval()


def pad_to_multiple(x: torch.Tensor, multiple: int) -> tuple[torch.Tensor, int, int]:
    h, w = x.shape[-2:]
    ph, pw = (-h) % multiple, (-w) % multiple
    if ph or pw:
        x = F.pad(x, (0, pw, 0, ph), mode="reflect")
    return x, h, w
