"""Structured console diagnostics for the phone connection path.

The panel window is the only log surface most people will ever see, so each
event prints as one compact `key=value` line. Only the fields a support
conversation needs may be passed in: never tokens, cookies or key material.
"""
from __future__ import annotations


def log(event: str, **fields) -> None:
    parts = [f"[hyperdr] {event}"]
    for name, value in fields.items():
        if isinstance(value, float):
            value = f"{value:.3f}"
        parts.append(f"{name}={value}")
    print(" ".join(parts), flush=True)
