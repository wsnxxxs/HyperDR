from __future__ import annotations

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


def gain_loss(
    prediction: torch.Tensor,
    target: torch.Tensor,
    mask: torch.Tensor,
    highlight_weight: float = 0.0,
    target_mode: TargetMode = "fixed_3stops",
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
    total = reconstruction + 0.20 * gradient + 0.10 * global_mean

    mae_per_image, mae_valid = _per_image_masked_mean(
        (prediction - target).abs(), mask
    )
    highlight_mask = mask * (target >= (1.0 / 3.0)).to(mask.dtype)
    highlight_mae_per_image, highlight_valid = _per_image_masked_mean(
        (prediction - target).abs(), highlight_mask
    )
    highlight_mae = _valid_mean(highlight_mae_per_image, highlight_valid)
    if target_mode == "fixed_3stops":
        highlight_name = "absolute_highlight_mae_stops"
        highlight_mae = highlight_mae * FIXED_GAIN_STOPS
    else:
        highlight_name = "relative_high_gain_mae"

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
        "false_high_prediction_rate_on_zero_target": _valid_mean(
            false_high_per_image, false_high_valid
        ).detach(),
        "_highlight_valid_images": highlight_valid.sum().detach(),
        "_zero_target_valid_images": false_high_valid.sum().detach(),
    }
    return total, metrics
