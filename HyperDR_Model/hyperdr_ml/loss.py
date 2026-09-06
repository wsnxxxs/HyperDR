from __future__ import annotations

from dataclasses import dataclass

import torch
import torch.nn.functional as F

from hyperdr_ml.data import FIXED_GAIN_STOPS, TargetMode


def _per_image_masked_mean(
    value: torch.Tensor, weight: torch.Tensor
) -> tuple[torch.Tensor, torch.Tensor]:
    sums = (value * weight).flatten(1).sum(dim=1)
    counts = weight.flatten(1).sum(dim=1)
    valid = counts > 0
    return sums / counts.clamp_min(1.0), valid


def _valid_mean(values: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
    return values[valid].mean() if bool(valid.any()) else values.sum() * 0.0


def target_floor_metric_name(target_mode: TargetMode) -> str:
    """What a target of zero means, which is not the same in every mode.

    Under fixed_3stops and per_image the target is gain/scale, so zero really
    is zero gain.  Under iso_interval zero is gain_min, which is negative for
    most of the Apple corpus -- calling that "zero target" would name a
    darkening floor as no-op gain.
    """
    return (
        "false_high_prediction_rate_at_gain_min"
        if target_mode == "iso_interval"
        else "false_high_prediction_rate_on_zero_target"
    )


def _absolute_scale(
    target_mode: TargetMode,
    stops_per_unit: torch.Tensor | None,
    reference: torch.Tensor,
) -> torch.Tensor | None:
    """Stops per unit of normalized target, per image, or None if undefined.

    `fixed_3stops` divides every image by the same constant, so the scale is
    that constant.  `iso_interval` divides each image by its own declared
    interval width, so the scale varies per image and the caller must supply
    it -- silently reusing 3.0 there would report a number in the wrong unit
    for every sample whose interval is not three stops wide.  `per_image`
    normalizes by a quantity that differs per image with no absolute meaning,
    so no stops-valued metric is defined at all.
    """
    batch = reference.shape[0]
    if target_mode == "per_image":
        if stops_per_unit is not None:
            raise ValueError("per_image targets have no absolute stops scale")
        return None
    if stops_per_unit is None:
        if target_mode != "fixed_3stops":
            raise ValueError(f"target_mode={target_mode!r} requires stops_per_unit")
        return reference.new_full((batch,), FIXED_GAIN_STOPS)
    scale = stops_per_unit.to(reference.device, reference.dtype).reshape(-1)
    if scale.shape[0] != batch:
        raise ValueError(
            f"stops_per_unit has {scale.shape[0]} entries for a batch of {batch}"
        )
    if not torch.isfinite(scale).all() or bool((scale <= 0).any()):
        raise ValueError("stops_per_unit must be finite and positive")
    return scale


# The composite's two shape terms, at the constants v1 shipped with.  They were
# never swept; both models inherit the same pair so that neither gets a tuning
# dimension the other lacks.
DEFAULT_GRADIENT_WEIGHT = 0.20
DEFAULT_GLOBAL_MEAN_WEIGHT = 0.10


def gain_loss(
    prediction: torch.Tensor,
    target: torch.Tensor,
    mask: torch.Tensor,
    highlight_weight: float = 0.0,
    target_mode: TargetMode = "fixed_3stops",
    stops_per_unit: torch.Tensor | None = None,
    gradient_weight: float = DEFAULT_GRADIENT_WEIGHT,
    global_mean_weight: float = DEFAULT_GLOBAL_MEAN_WEIGHT,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    if prediction.shape != target.shape or target.shape != mask.shape:
        raise ValueError(
            f"prediction/target/mask shapes differ: "
            f"{prediction.shape}/{target.shape}/{mask.shape}"
        )
    if not torch.isfinite(prediction).all():
        raise FloatingPointError("Non-finite model prediction")
    if not torch.isfinite(target).all() or not torch.isfinite(mask).all():
        raise FloatingPointError("Non-finite target or mask")
    scale = _absolute_scale(target_mode, stops_per_unit, prediction)

    pixel_weight = mask * (1.0 + highlight_weight * target.square())
    reconstruction_per_image, reconstruction_valid = _per_image_masked_mean(
        F.smooth_l1_loss(prediction, target, reduction="none", beta=0.05),
        pixel_weight,
    )
    reconstruction = _valid_mean(reconstruction_per_image, reconstruction_valid)

    pred_dx = prediction[..., :, 1:] - prediction[..., :, :-1]
    pred_dy = prediction[..., 1:, :] - prediction[..., :-1, :]
    target_dx = target[..., :, 1:] - target[..., :, :-1]
    target_dy = target[..., 1:, :] - target[..., :-1, :]
    mask_dx = mask[..., :, 1:] * mask[..., :, :-1]
    mask_dy = mask[..., 1:, :] * mask[..., :-1, :]
    gradient_x, valid_x = _per_image_masked_mean(
        (pred_dx - target_dx).abs(), mask_dx
    )
    gradient_y, valid_y = _per_image_masked_mean(
        (pred_dy - target_dy).abs(), mask_dy
    )
    gradient_axes = valid_x.to(prediction.dtype) + valid_y.to(prediction.dtype)
    gradient_per_image = (
        gradient_x * valid_x + gradient_y * valid_y
    ) / gradient_axes.clamp_min(1.0)
    gradient = _valid_mean(gradient_per_image, gradient_axes > 0)

    mean_prediction, valid_prediction = _per_image_masked_mean(prediction, mask)
    mean_target, valid_target = _per_image_masked_mean(target, mask)
    valid_images = valid_prediction & valid_target
    global_mean = _valid_mean(
        (mean_prediction - mean_target).abs(), valid_images
    )
    total = reconstruction + gradient_weight * gradient + global_mean_weight * global_mean

    mae_per_image, mae_valid = _per_image_masked_mean(
        (prediction - target).abs(), mask
    )
    highlight_mask = mask * (target >= (1.0 / 3.0)).to(mask.dtype)
    highlight_mae_per_image, highlight_valid = _per_image_masked_mean(
        (prediction - target).abs(), highlight_mask
    )
    if scale is None:
        highlight_name = "relative_high_gain_mae"
        highlight_mae = _valid_mean(highlight_mae_per_image, highlight_valid)
    else:
        # Scale each image by its own stops-per-unit before averaging: with
        # iso_interval the widths differ across the batch, so scaling the
        # average instead would be the average of the wrong quantity.
        highlight_name = "absolute_highlight_mae_stops"
        highlight_mae = _valid_mean(highlight_mae_per_image * scale, highlight_valid)

    zero_target_mask = mask * (target <= 1e-6).to(mask.dtype)
    false_high_per_image, false_high_valid = _per_image_masked_mean(
        (prediction >= (1.0 / 3.0)).to(prediction.dtype),
        zero_target_mask,
    )
    metrics = {
        "loss": total.detach(),
        "reconstruction": reconstruction.detach(),
        "gradient": gradient.detach(),
        "global_mean": global_mean.detach(),
        "mae": _valid_mean(mae_per_image, mae_valid).detach(),
        highlight_name: highlight_mae.detach(),
        target_floor_metric_name(target_mode): _valid_mean(
            false_high_per_image, false_high_valid
        ).detach(),
        # Metrics defined on a subset of images are averaged over that subset,
        # not over the batch.  Declaring the weight next to the metric keeps the
        # caller from having to know which names are conditional.
        "_metric_weights": {
            highlight_name: highlight_valid.sum().detach(),
            target_floor_metric_name(target_mode): false_high_valid.sum().detach(),
        },
    }
    if scale is not None:
        # The comparable number across target modes and label contracts: `mae`
        # is in normalized units whose meaning changes with the mode.
        metrics["mae_stops"] = _valid_mean(mae_per_image * scale, mae_valid).detach()
        # Per-image values so the caller can re-weight by capture group. The
        # judgment weights groups equally, so anything that selects a model
        # has to be able to weight the same way.
        metrics["_per_image"] = {"mae_stops": (mae_per_image * scale).detach()}
    return total, metrics


@dataclass(frozen=True)
class IntervalLossWeights:
    """Weights for A2's decomposition.

    There is no `map` weight: scaling all four terms together only rescales the
    loss, which is degenerate with the learning rate, so one of them has to be
    pinned. Pinning the map term at 1 makes the other three read as "relative to
    the spatial term" and removes a search dimension that buys nothing.

    `gradient` and `global_mean` weight the two shape terms *inside* the map
    term. They are exposed here and in `direct_gain_loss` alike: both models
    have those terms, and a knob one model has and the other does not is a
    tuning asymmetry, not an architectural difference.

    **These are untuned placeholders.** Nothing here has been swept. Treat any
    run made with the defaults as a plumbing check, not as evidence about A2.
    """

    gain_min: float = 1.0
    gain_max: float = 1.0
    reconstructed_gain: float = 1.0
    gradient: float = DEFAULT_GRADIENT_WEIGHT
    global_mean: float = DEFAULT_GLOBAL_MEAN_WEIGHT


def reconstruct_gain(
    normalized_map: torch.Tensor, gain_min: torch.Tensor, gain_max: torch.Tensor
) -> torch.Tensor:
    """G = gain_min + (gain_max - gain_min) * M, broadcast over the grid."""
    low = gain_min.reshape(-1, 1, 1, 1).to(normalized_map.dtype)
    high = gain_max.reshape(-1, 1, 1, 1).to(normalized_map.dtype)
    return low + (high - low) * normalized_map


# The highlight band, in stops, on ground-truth G.  One stop is exactly where
# the v1 fixed_3stops threshold sat (target >= 1/3 of 3 stops), so G-domain
# highlight numbers stay comparable with the runs that came before.
HIGHLIGHT_THRESHOLD_STOPS = 1.0


def _highlight_stops(
    predicted_gain: torch.Tensor,
    truth_gain: torch.Tensor,
    mask: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor]:
    highlight_mask = mask * (truth_gain >= HIGHLIGHT_THRESHOLD_STOPS).to(mask.dtype)
    per_image, valid = _per_image_masked_mean(
        (predicted_gain - truth_gain).abs(), highlight_mask
    )
    return _valid_mean(per_image, valid), valid.sum()


def interval_gain_loss(
    prediction: dict[str, torch.Tensor],
    target: torch.Tensor,
    mask: torch.Tensor,
    gain_min: torch.Tensor,
    gain_max: torch.Tensor,
    highlight_weight: float = 0.0,
    weights: IntervalLossWeights | None = None,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    """Supervise M, both endpoints, and the reconstructed G, each separately.

    A3 is what makes the separate supervision necessary rather than optional:
    with only L_G the parameterization has a two-dimensional affine ambiguity.
    The label contract pins all three targets, so the ambiguity does not exist
    here -- but only as long as all three are actually supervised.
    """
    weights = weights or IntervalLossWeights()
    predicted_map = prediction["map"]
    predicted_min = prediction["gain_min"].reshape(-1)
    predicted_max = prediction["gain_max"].reshape(-1)
    truth_min = gain_min.reshape(-1).to(predicted_min.dtype)
    truth_max = gain_max.reshape(-1).to(predicted_max.dtype)
    width = truth_max - truth_min
    if bool((width <= 0).any()):
        raise ValueError("ground-truth gain interval must have positive width")
    if not torch.isfinite(predicted_min).all() or not torch.isfinite(predicted_max).all():
        raise FloatingPointError("Non-finite endpoint prediction")

    map_loss, metrics = gain_loss(
        predicted_map,
        target,
        mask,
        highlight_weight,
        "iso_interval",
        width,
        weights.gradient,
        weights.global_mean,
    )

    endpoint_min = F.smooth_l1_loss(predicted_min, truth_min, beta=0.05)
    endpoint_max = F.smooth_l1_loss(predicted_max, truth_max, beta=0.05)

    predicted_gain = reconstruct_gain(predicted_map, predicted_min, predicted_max)
    truth_gain = reconstruct_gain(target, truth_min, truth_max)
    gain_per_image, gain_valid = _per_image_masked_mean(
        F.smooth_l1_loss(predicted_gain, truth_gain, reduction="none", beta=0.05), mask
    )
    reconstructed = _valid_mean(gain_per_image, gain_valid)

    total = (
        map_loss  # pinned at weight 1; see IntervalLossWeights
        + weights.gain_min * endpoint_min
        + weights.gain_max * endpoint_max
        + weights.reconstructed_gain * reconstructed
    )

    gain_mae_per_image, _ = _per_image_masked_mean(
        (predicted_gain - truth_gain).abs(), mask
    )
    highlight_mae, highlight_images = _highlight_stops(predicted_gain, truth_gain, mask)
    map_weights = {
        f"map_{name}": value for name, value in metrics.pop("_metric_weights").items()
    }
    metrics.pop("_per_image", None)
    metrics = {f"map_{name}": value for name, value in metrics.items() if not name.startswith("_")}
    metrics.update(
        {
            "_metric_weights": {
                **map_weights,
                "absolute_highlight_mae_stops": highlight_images.detach(),
            },
            "_per_image": {"g_mae_stops": gain_mae_per_image.detach()},
            "absolute_highlight_mae_stops": highlight_mae.detach(),
            "loss": total.detach(),
            "map_loss": map_loss.detach(),
            "gain_min_loss": endpoint_min.detach(),
            "gain_max_loss": endpoint_max.detach(),
            "reconstructed_gain_loss": reconstructed.detach(),
            # The primary metric of the whole comparison: absolute log2-gain
            # MAE in stops, on G, identical in definition for both models.
            "g_mae_stops": _valid_mean(gain_mae_per_image, gain_valid).detach(),
            "gain_min_mae_stops": (predicted_min - truth_min).abs().mean().detach(),
            "gain_max_mae_stops": (predicted_max - truth_max).abs().mean().detach(),
            "gain_min_bias_stops": (predicted_min - truth_min).mean().detach(),
            "gain_max_bias_stops": (predicted_max - truth_max).mean().detach(),
            "predicted_gain_range_mean": (predicted_max - predicted_min).mean().detach(),
        }
    )
    return total, metrics


def direct_gain_loss(
    prediction: torch.Tensor,
    target: torch.Tensor,
    mask: torch.Tensor,
    highlight_weight: float = 0.0,
    gradient_weight: float = DEFAULT_GRADIENT_WEIGHT,
    global_mean_weight: float = DEFAULT_GLOBAL_MEAN_WEIGHT,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    """The control model's objective: the same composite, computed on G.

    Structurally identical to the map term of `interval_gain_loss` -- same
    reconstruction/gradient/global-mean mix, same Huber knee, and the same two
    tunable shape weights -- so that the non-inferiority test compares
    parameterizations rather than objectives or tuning effort. Both models
    report `g_mae_stops` for the same quantity.
    """
    if prediction.shape != target.shape or target.shape != mask.shape:
        raise ValueError(
            f"prediction/target/mask shapes differ: "
            f"{prediction.shape}/{target.shape}/{mask.shape}"
        )
    if not torch.isfinite(prediction).all():
        raise FloatingPointError("Non-finite model prediction")
    if not torch.isfinite(target).all() or not torch.isfinite(mask).all():
        raise FloatingPointError("Non-finite target or mask")

    pixel_weight = mask * (1.0 + highlight_weight * target.square())
    reconstruction_per_image, reconstruction_valid = _per_image_masked_mean(
        F.smooth_l1_loss(prediction, target, reduction="none", beta=0.05), pixel_weight
    )
    reconstruction = _valid_mean(reconstruction_per_image, reconstruction_valid)

    pred_dx = prediction[..., :, 1:] - prediction[..., :, :-1]
    pred_dy = prediction[..., 1:, :] - prediction[..., :-1, :]
    target_dx = target[..., :, 1:] - target[..., :, :-1]
    target_dy = target[..., 1:, :] - target[..., :-1, :]
    gradient_x, valid_x = _per_image_masked_mean(
        (pred_dx - target_dx).abs(), mask[..., :, 1:] * mask[..., :, :-1]
    )
    gradient_y, valid_y = _per_image_masked_mean(
        (pred_dy - target_dy).abs(), mask[..., 1:, :] * mask[..., :-1, :]
    )
    gradient_axes = valid_x.to(prediction.dtype) + valid_y.to(prediction.dtype)
    gradient = _valid_mean(
        (gradient_x * valid_x + gradient_y * valid_y) / gradient_axes.clamp_min(1.0),
        gradient_axes > 0,
    )

    mean_prediction, valid_prediction = _per_image_masked_mean(prediction, mask)
    mean_target, valid_target = _per_image_masked_mean(target, mask)
    global_mean = _valid_mean(
        (mean_prediction - mean_target).abs(), valid_prediction & valid_target
    )
    total = reconstruction + gradient_weight * gradient + global_mean_weight * global_mean

    mae_per_image, mae_valid = _per_image_masked_mean((prediction - target).abs(), mask)
    highlight_mae, highlight_images = _highlight_stops(prediction, target, mask)
    return total, {
        "loss": total.detach(),
        "reconstruction": reconstruction.detach(),
        "gradient": gradient.detach(),
        "global_mean": global_mean.detach(),
        "g_mae_stops": _valid_mean(mae_per_image, mae_valid).detach(),
        "absolute_highlight_mae_stops": highlight_mae.detach(),
        "_metric_weights": {"absolute_highlight_mae_stops": highlight_images.detach()},
        "_per_image": {"g_mae_stops": mae_per_image.detach()},
    }
