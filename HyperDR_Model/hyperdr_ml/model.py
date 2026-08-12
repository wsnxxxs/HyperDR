from __future__ import annotations

from typing import Literal

import torch
from torch import nn
import torch.nn.functional as F

Architecture = Literal["baseline", "global_conditioning", "dilation_pyramid"]

DIRECT_GAINMAPNET_ID = "hyperdr.direct-fixed-incumbent/v3"
DEFAULT_ARCHITECTURE: Architecture = "baseline"
DEFAULT_BASE_CHANNELS = 24
MODEL_STRIDE = 16


def group_count(channels: int, maximum: int = 8) -> int:
    if channels <= 0:
        raise ValueError(f"channels must be positive, got {channels}")
    for groups in range(min(maximum, channels), 0, -1):
        if channels % groups == 0:
            return groups
    raise AssertionError("Every positive integer is divisible by one")


class ConvBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int = 1) -> None:
        super().__init__()
        groups = group_count(out_channels)
        self.block = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False),
            nn.GroupNorm(groups, out_channels),
            nn.SiLU(inplace=True),
            nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False),
            nn.GroupNorm(groups, out_channels),
            nn.SiLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.block(x)


class GlobalConditioning(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        hidden = max(1, channels // 2)
        self.local = nn.Sequential(
            nn.Conv2d(
                channels,
                channels,
                3,
                padding=2,
                dilation=2,
                groups=channels,
                bias=False,
            ),
            nn.GroupNorm(group_count(channels), channels),
            nn.SiLU(inplace=True),
        )
        self.global_mlp = nn.Sequential(
            nn.Conv2d(channels, hidden, 1),
            nn.SiLU(inplace=True),
            nn.Conv2d(hidden, channels, 1),
            nn.SiLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        global_context = self.global_mlp(F.adaptive_avg_pool2d(x, 1))
        return self.local(x) + global_context


class DilationPyramid(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        hidden = max(1, channels // 4)
        self.reduce = nn.Sequential(
            nn.Conv2d(channels, hidden, 1, bias=False),
            nn.GroupNorm(group_count(hidden), hidden),
            nn.SiLU(inplace=True),
        )
        self.branches = nn.ModuleList(
            [
                nn.Conv2d(
                    hidden,
                    hidden,
                    3,
                    padding=dilation,
                    dilation=dilation,
                    groups=hidden,
                    bias=False,
                )
                for dilation in (1, 2, 4)
            ]
        )
        self.project = nn.Sequential(
            nn.Conv2d(hidden * 3, channels, 1),
            nn.SiLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        reduced = self.reduce(x)
        return self.project(torch.cat([branch(reduced) for branch in self.branches], 1))


class DirectGainMapNet(nn.Module):
    """Direct v3: predict a single-channel stride-16 gain map from linear P3 SDR."""

    def __init__(
        self,
        base_channels: int = DEFAULT_BASE_CHANNELS,
        architecture: Architecture = DEFAULT_ARCHITECTURE,
    ) -> None:
        super().__init__()
        if base_channels <= 0:
            raise ValueError(f"base_channels must be positive, got {base_channels}")
        channels = [base_channels, base_channels * 2, base_channels * 4, base_channels * 6]
        self.stem = ConvBlock(5, channels[0], stride=2)
        self.stage2 = ConvBlock(channels[0], channels[1], stride=2)
        self.stage3 = ConvBlock(channels[1], channels[2], stride=2)
        self.stage4 = ConvBlock(channels[2], channels[3], stride=2)
        if architecture == "baseline":
            self.context = nn.Sequential(
                nn.Conv2d(
                    channels[3],
                    channels[3],
                    3,
                    padding=2,
                    dilation=2,
                    groups=channels[3],
                    bias=False,
                ),
                nn.GroupNorm(group_count(channels[3]), channels[3]),
                nn.SiLU(inplace=True),
                nn.Conv2d(channels[3], channels[3], 1),
                nn.SiLU(inplace=True),
            )
        elif architecture == "global_conditioning":
            self.context = GlobalConditioning(channels[3])
        elif architecture == "dilation_pyramid":
            self.context = DilationPyramid(channels[3])
        else:
            raise ValueError(f"Unknown architecture {architecture!r}")
        self.architecture = architecture
        self.skip3 = nn.Conv2d(channels[2], channels[3], 1)
        self.head = nn.Sequential(
            nn.Conv2d(channels[3], channels[2], 3, padding=1),
            nn.SiLU(inplace=True),
            nn.Conv2d(channels[2], 1, 1),
        )

    def forward(self, linear_p3: torch.Tensor) -> torch.Tensor:
        if linear_p3.ndim != 4 or linear_p3.shape[1] != 3:
            raise ValueError(
                "DirectGainMapNet expects a BCHW linear Display-P3 tensor with "
                f"three channels, got {tuple(linear_p3.shape)}"
            )
        luminance = (
            0.22897456 * linear_p3[:, 0:1]
            + 0.69173852 * linear_p3[:, 1:2]
            + 0.07928691 * linear_p3[:, 2:3]
        )
        log_luminance = torch.log2(luminance.clamp_min(1e-6))
        log_luminance = ((log_luminance + 12.0) / 12.0).clamp(0.0, 1.0)
        clipping = (linear_p3.amax(dim=1, keepdim=True) >= 0.98).to(linear_p3.dtype)
        x = torch.cat((linear_p3, log_luminance, clipping), dim=1)
        x1 = self.stem(x)
        x2 = self.stage2(x1)
        x3 = self.stage3(x2)
        x4 = self.stage4(x3)
        x4 = self.context(x4)
        skip = F.adaptive_avg_pool2d(x3, output_size=x4.shape[-2:])
        x4 = x4 + self.skip3(skip)
        return torch.sigmoid(self.head(x4))

    def initialize_output_bias(self, target_mean: float) -> float:
        clipped = min(max(float(target_mean), 1e-4), 1.0 - 1e-4)
        bias = float(torch.logit(torch.tensor(clipped)))
        output = self.head[-1]
        if not isinstance(output, nn.Conv2d) or output.bias is None:
            raise RuntimeError("Gain-map head has no initializable output bias")
        nn.init.constant_(output.bias, bias)
        return bias


# Checkpoint keys and downstream imports used the shorter name before the
# Direct-v3 model identity was frozen. Keep it as an alias rather than a
# wrapper so state_dict keys and isinstance behavior remain unchanged.
GainMapNet = DirectGainMapNet
