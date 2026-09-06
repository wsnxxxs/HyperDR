from __future__ import annotations

from typing import Literal

import torch
from torch import nn
import torch.nn.functional as F

Architecture = Literal["baseline", "global_conditioning", "dilation_pyramid"]
OutputMode = Literal["normalized_v1", "signed_stops_v2"]

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


class _GainMapTrunk(nn.Module):
    """Shared encoder and stride-16 head shape.

    The three models below differ only in what they put on top of this trunk,
    and they inherit it rather than nesting it so their parameter names stay
    identical for the shared part: A2's comparison requires one backbone, and
    identical names make that checkable with `state_dict()` instead of trust.
    """

    def __init__(
        self,
        base_channels: int = 24,
        architecture: Architecture = "baseline",
    ) -> None:
        super().__init__()
        if base_channels <= 0:
            raise ValueError(f"base_channels must be positive, got {base_channels}")
        channels = [base_channels, base_channels * 2, base_channels * 4, base_channels * 6]
        self.trunk_channels = channels
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

    def features(self, linear_p3: torch.Tensor) -> torch.Tensor:
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
        # Inputs are contractually divisible by stride 16, so stage3 is
        # exactly twice stage4 in each spatial dimension.  In this geometry,
        # adaptive 2:1 average pooling is mathematically the same as a 2x2
        # stride-2 average pool.  The explicit kernel has a deterministic CUDA
        # backward implementation; adaptive_avg_pool2d does not.
        expected_skip_shape = tuple(2 * int(value) for value in x4.shape[-2:])
        if tuple(x3.shape[-2:]) == expected_skip_shape:
            skip = F.avg_pool2d(x3, kernel_size=2, stride=2)
        else:
            # Keep the model's established ceil-grid inference behavior for
            # arbitrary standalone inputs. Training samples are rejected by
            # the data contract unless both dimensions are stride-16 aligned,
            # so registered training never takes this CUDA-backward path.
            skip = F.adaptive_avg_pool2d(x3, output_size=x4.shape[-2:])
        return x4 + self.skip3(skip)

    def _set_output_bias(self, value: float) -> float:
        output = self.head[-1]
        if not isinstance(output, nn.Conv2d) or output.bias is None:
            raise RuntimeError("Gain-map head has no initializable output bias")
        nn.init.constant_(output.bias, float(value))
        return float(value)


class GainMapNet(_GainMapTrunk):
    """Predict a normalized stride-16 gain grid from linear-P3 SDR.

    Spatial map only.  Under `iso_interval` this is M, and the interval
    endpoints have to come from somewhere else -- which is what
    `IntervalGainMapNet` adds.
    """

    def forward(self, linear_p3: torch.Tensor) -> torch.Tensor:
        return torch.sigmoid(self.head(self.features(linear_p3)))

    def initialize_output_bias(self, target_mean: float) -> float:
        clipped = min(max(float(target_mean), 1e-4), 1.0 - 1e-4)
        return self._set_output_bias(float(torch.logit(torch.tensor(clipped))))


def masked_pool(features: torch.Tensor, mask: torch.Tensor | None) -> torch.Tensor:
    """Global mean and max over the valid region only.

    collate pads short samples with zeros, and a global statistic computed over
    that padding would make a per-file scalar depend on which other images
    happened to share its batch.  The trunk output is at stride 16, the same
    grid the target mask is defined on, so the mask applies directly.
    """
    if mask is None:
        pooled_mean = features.mean(dim=(-2, -1))
        pooled_max = features.amax(dim=(-2, -1))
        return torch.cat((pooled_mean, pooled_max), dim=1)
    if mask.shape[-2:] != features.shape[-2:]:
        raise ValueError(
            f"mask grid {tuple(mask.shape[-2:])} does not match trunk output "
            f"{tuple(features.shape[-2:])}"
        )
    weight = mask[:, :1].to(features.dtype)
    counts = weight.sum(dim=(-2, -1)).clamp_min(1.0)
    pooled_mean = (features * weight).sum(dim=(-2, -1)) / counts
    pooled_max = features.masked_fill(weight == 0, float("-inf")).amax(dim=(-2, -1))
    # A fully masked sample would give -inf; it cannot occur (collate always
    # leaves the unpadded region), but the guard keeps it out of the graph.
    pooled_max = torch.where(torch.isfinite(pooled_max), pooled_max, pooled_mean)
    return torch.cat((pooled_mean, pooled_max), dim=1)


class IntervalGainMapNet(_GainMapTrunk):
    """A2's decomposition: spatial map M plus a per-file gain interval.

    `gain_min` is an unbounded signed linear output (implementation constraint
    2): a sigmoid there would reimpose the non-negativity that the v2 label
    contract exists to escape.  The interval width is `softplus(r) + eps`, so
    `gain_max > gain_min` holds by construction rather than by penalty
    (constraint 1).

    Under the Apple profile `gain_max` and H_alt are one scalar, not two
    outputs pulled together by two losses (A2).  That is not an assumption
    here: it is verified true to 0.000e+00 on all 847 corpus samples, and the
    loader re-checks it per sample.
    """

    MINIMUM_RANGE = 1.0e-3

    def __init__(
        self,
        base_channels: int = 24,
        architecture: Architecture = "baseline",
    ) -> None:
        super().__init__(base_channels, architecture)
        pooled = self.trunk_channels[3] * 2  # masked mean and masked max
        hidden = max(8, self.trunk_channels[1])
        self.metadata_head = nn.Sequential(
            nn.Linear(pooled, hidden),
            nn.SiLU(inplace=True),
            nn.Linear(hidden, 2),
        )

    def forward(
        self, linear_p3: torch.Tensor, mask: torch.Tensor | None = None
    ) -> dict[str, torch.Tensor]:
        features = self.features(linear_p3)
        raw = self.metadata_head(masked_pool(features, mask))
        gain_min = raw[:, 0]
        gain_range = F.softplus(raw[:, 1]) + self.MINIMUM_RANGE
        return {
            "map": torch.sigmoid(self.head(features)),
            "gain_min": gain_min,
            "gain_max": gain_min + gain_range,
            "gain_range": gain_range,
        }

    def initialize_output_bias(self, target_mean: float) -> float:
        clipped = min(max(float(target_mean), 1e-4), 1.0 - 1e-4)
        return self._set_output_bias(float(torch.logit(torch.tensor(clipped))))

    def initialize_metadata_bias(self, gain_min: float, gain_range: float) -> dict[str, float]:
        """Start the endpoints at the corpus means, in their own units."""
        if not gain_range > self.MINIMUM_RANGE:
            raise ValueError(f"gain_range must exceed {self.MINIMUM_RANGE}, got {gain_range}")
        output = self.metadata_head[-1]
        # Invert softplus so the initial width really is `gain_range`.
        residual = gain_range - self.MINIMUM_RANGE
        raw_range = float(torch.log(torch.expm1(torch.tensor(residual, dtype=torch.float64))))
        with torch.no_grad():
            nn.init.zeros_(output.weight)
            output.bias.copy_(torch.tensor([float(gain_min), raw_range]))
        return {"gain_min": float(gain_min), "raw_gain_range": raw_range}


class EndpointRegressor(_GainMapTrunk):
    """A single per-file endpoint scalar, for the appendix E attribution.

    The head is unbounded signed linear (implementation constraint 2): gain_min
    is negative on 418/459 native ISO files, so a bounded head would decide the
    attribution by construction.

    `metadata_dim` is what separates the two image arms. At 0 this is the
    image-only arm; above 0 the registered feature vector is concatenated to the
    pooled trunk features, which is the image+metadata arm. One class rather
    than two so the arms cannot drift apart in the trunk, where they are
    supposed to be identical -- the same reason A2's two models share a trunk
    and their parameter names match verbatim.

    Pooling is masked. A per-file scalar read off zero padding would depend on
    which other images shared the batch, and the judgment resamples per-image
    numbers, so that dependence would be bootstrapped as if it were signal.
    """

    def __init__(
        self,
        base_channels: int = 24,
        architecture: Architecture = "baseline",
        metadata_dim: int = 0,
    ) -> None:
        super().__init__(base_channels, architecture)
        if metadata_dim < 0:
            raise ValueError(f"metadata_dim must be non-negative, got {metadata_dim}")
        self.metadata_dim = int(metadata_dim)
        pooled = self.trunk_channels[3] * 2  # masked mean and masked max
        hidden = max(8, self.trunk_channels[1])
        self.scalar_head = nn.Sequential(
            nn.Linear(pooled + self.metadata_dim, hidden),
            nn.SiLU(inplace=True),
            nn.Linear(hidden, 1),
        )

    def forward(
        self,
        linear_p3: torch.Tensor,
        mask: torch.Tensor | None = None,
        metadata: torch.Tensor | None = None,
    ) -> torch.Tensor:
        pooled = masked_pool(self.features(linear_p3), mask)
        if self.metadata_dim:
            if metadata is None:
                raise ValueError(
                    "this arm was built with metadata features; forward needs them"
                )
            if metadata.shape[1] != self.metadata_dim:
                raise ValueError(
                    f"expected {self.metadata_dim} metadata features, got "
                    f"{metadata.shape[1]}"
                )
            pooled = torch.cat((pooled, metadata.to(pooled.dtype)), dim=1)
        elif metadata is not None:
            raise ValueError(
                "this is the image-only arm; passing metadata would make it the "
                "image+metadata arm under the wrong name"
            )
        return self.scalar_head(pooled).squeeze(1)

    def initialize_output_bias(self, target_mean: float) -> float:
        """`target_mean` is already in stops and the head is linear."""
        with torch.no_grad():
            output = self.scalar_head[-1]
            nn.init.zeros_(output.weight)
            output.bias.fill_(float(target_mean))
        return float(target_mean)


class DirectGainNet(_GainMapTrunk):
    """A2's control model: regress signed canonical G directly, no interval.

    Implementation constraint 3 forbids reusing the sigmoid head here -- a
    bounded non-negative head would lose the comparison for the wrong reason.
    Same trunk, same parameter names, so the only difference under test is the
    output parameterization.
    """

    def forward(self, linear_p3: torch.Tensor) -> torch.Tensor:
        return self.head(self.features(linear_p3))

    def initialize_output_bias(self, target_mean: float) -> float:
        """`target_mean` is already in stops; the head is linear, so use it."""
        return self._set_output_bias(float(target_mean))


class DirectGainMapNet(DirectGainNet):
    """Checkpoint-compatible deployment name for the direct signed-stop model.

    Production-v3 was trained as ``DirectGainNet``.  The runtime/export copy
    later renamed that class and accidentally dropped the rest of the signed
    training stack.  This compatibility surface accepts the runtime's historic
    constructor without nesting the trunk, so state-dict keys remain identical.
    """

    def __init__(
        self,
        base_channels: int = DEFAULT_BASE_CHANNELS,
        architecture: Architecture = DEFAULT_ARCHITECTURE,
        output_mode: OutputMode = "signed_stops_v2",
    ) -> None:
        super().__init__(base_channels, architecture)
        if output_mode not in ("normalized_v1", "signed_stops_v2"):
            raise ValueError(f"Unknown output mode {output_mode!r}")
        self.output_mode = output_mode

    def forward(self, linear_p3: torch.Tensor) -> torch.Tensor:
        prediction = super().forward(linear_p3)
        return prediction if self.output_mode == "signed_stops_v2" else torch.sigmoid(prediction)

    def initialize_output_bias(self, target_mean: float) -> float:
        if self.output_mode == "signed_stops_v2":
            return super().initialize_output_bias(target_mean)
        clipped = min(max(float(target_mean), 1e-4), 1.0 - 1e-4)
        return self._set_output_bias(float(torch.logit(torch.tensor(clipped))))
