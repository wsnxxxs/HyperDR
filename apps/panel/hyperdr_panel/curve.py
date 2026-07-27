"""Fetching the exporter's own tone curve.

The browser previously reimplemented this curve twice, once in JavaScript for
the canvas preview and once in WGSL for the WebGPU path. Reading it from the
binary that writes the file is the only way to guarantee the preview and the
export agree.

The cache lookup and the subprocess used to be unrelated: the lookup held the
lock, the process ran outside it, and the result was only written back once the
process had exited. So N concurrent requests for the *same* curve -- several
tabs tracking one slider, which is the normal case -- were N cache misses and N
converter processes. The 30-second timeout bounded how long each one lived and
said nothing about how many could exist at once. Curves are now deduplicated by
key and capped globally.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading

from .command import build_curve_argv
from .concurrency import Budget, SingleFlight

_CACHE: dict[tuple, dict] = {}
_LOCK = threading.Lock()
_CACHE_LIMIT = 128

CURVE_TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_CURVE_TIMEOUT_SECONDS", "30")))
MAX_CURVE_PROCESSES = max(1, int(os.environ.get("HYPERDR_MAX_CURVE_PROCESSES", "2")))

_BUDGET = Budget(MAX_CURVE_PROCESSES, "曲线服务繁忙，请稍后再试。")
_INFLIGHT = SingleFlight()


def _run_curve(argv: list[str], key: tuple) -> dict:
    """Run one `HyperDR curve`, holding a slot in the global process budget."""
    with _BUDGET.hold(timeout=1.0):
        with _LOCK:
            # An earlier flight may have filled this in while we waited.
            cached = _CACHE.get(key)
        if cached is not None:
            return cached
        try:
            completed = subprocess.run(argv, capture_output=True,
                                       timeout=CURVE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as exc:
            raise ValueError("获取曲线数据超时。") from exc
        except OSError as exc:
            raise ValueError("无法启动 HyperDR：%s" % exc) from exc
    if completed.returncode != 0:
        message = completed.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(message or "无法获取曲线数据。")
    try:
        data = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("曲线数据无法解析。") from exc
    with _LOCK:
        if len(_CACHE) >= _CACHE_LIMIT:
            _CACHE.clear()
        _CACHE[key] = data
    return data


def look_curve(exe: str, options: dict, samples: int = 257) -> dict:
    """Return the curve for these settings, running the converter once per set."""
    argv = build_curve_argv(exe, options, samples)
    key = tuple(argv)
    with _LOCK:
        cached = _CACHE.get(key)
    if cached is not None:
        return cached
    # Followers wait slightly longer than the process may live, so a genuinely
    # slow run is shared rather than becoming a second one.
    return _INFLIGHT.run(key, lambda: _run_curve(argv, key),
                         timeout=CURVE_TIMEOUT_SECONDS + 5.0)
