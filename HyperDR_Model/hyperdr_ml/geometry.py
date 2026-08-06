from __future__ import annotations

import math

MODEL_STRIDE = 16


def align_dimension(value: int, multiple: int = MODEL_STRIDE) -> int:
    """Round a positive raster dimension up to the model stride."""
    if value <= 0:
        raise ValueError(f"Dimension must be positive, got {value}")
    if multiple <= 0:
        raise ValueError(f"Alignment multiple must be positive, got {multiple}")
    return max(multiple, math.ceil(value / multiple) * multiple)


def aligned_long_side_size(
    size: tuple[int, int],
    long_side: int,
    *,
    allow_upscale: bool = False,
) -> tuple[int, int]:
    """Fit an image to ``long_side`` and ceil-align both axes to stride 16.

    The returned dimensions are the single spatial contract used by dataset
    extraction, cache construction, and inference.
    """
    width, height = size
    if width <= 0 or height <= 0:
        raise ValueError(f"Image dimensions must be positive, got {size}")
    if long_side < MODEL_STRIDE:
        raise ValueError(f"long_side must be at least {MODEL_STRIDE}, got {long_side}")
    scale = long_side / max(width, height)
    if not allow_upscale:
        scale = min(1.0, scale)
    scaled_width = max(1, round(width * scale))
    scaled_height = max(1, round(height * scale))
    return align_dimension(scaled_width), align_dimension(scaled_height)


def target_grid_size(size: tuple[int, int]) -> tuple[int, int]:
    """Return the exact stride-16 target grid for an aligned raster."""
    width, height = size
    if width % MODEL_STRIDE or height % MODEL_STRIDE:
        raise ValueError(
            f"Raster must be divisible by {MODEL_STRIDE}, got {(width, height)}"
        )
    return width // MODEL_STRIDE, height // MODEL_STRIDE
