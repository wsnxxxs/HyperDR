"""The converter's settings vocabulary, read from the converter itself.

The panel used to carry its own copy of every setting: which keys exist, which
names an enum accepts, and each numeric range. The Python test suite kept the
two in step by regular-expression scraping ``src/cli.cpp``, which caught a
renamed key only if the C++ happened to still look the way the pattern expected.

``HyperDR schema`` now emits that table as JSON, and ``schema/settings.json`` is
that output, checked in. This module turns it into validators, so a new setting
reaches the panel by rebuilding the converter rather than by editing Python.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .config import REPO_ROOT

SCHEMA_PATH = Path(
    os.environ.get("HYPERDR_SCHEMA", REPO_ROOT / "schema" / "settings.json")
)


class SchemaError(RuntimeError):
    """The schema file is missing or unusable, so nothing can be validated."""


def _load() -> dict:
    try:
        with SCHEMA_PATH.open("r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SchemaError(
            "无法读取设置定义 %s：%s。请重新构建 HyperDR 或运行 "
            "`HyperDR schema > schema/settings.json`。" % (SCHEMA_PATH, exc)
        ) from exc
    settings = document.get("settings")
    if not isinstance(settings, list) or not settings:
        raise SchemaError("设置定义为空或格式不正确。")
    return document


_DOCUMENT = _load()

#: Every setting, keyed by its canonical name.
SETTINGS: dict[str, dict] = {entry["key"]: entry for entry in _DOCUMENT["settings"]}
#: The version of the converter that produced this schema.
TOOL_VERSION: str = str(_DOCUMENT.get("tool", ""))
ALL_KEYS = frozenset(SETTINGS)
DEFAULTS = {key: entry["default"] for key, entry in SETTINGS.items()}


def reload() -> None:
    """Re-read the schema. Used by tests that regenerate it from the binary."""
    global _DOCUMENT, SETTINGS, TOOL_VERSION, ALL_KEYS, DEFAULTS
    _DOCUMENT = _load()
    SETTINGS = {entry["key"]: entry for entry in _DOCUMENT["settings"]}
    TOOL_VERSION = str(_DOCUMENT.get("tool", ""))
    ALL_KEYS = frozenset(SETTINGS)
    DEFAULTS = {key: entry["default"] for key, entry in SETTINGS.items()}


def _is_number(value) -> bool:
    # bool is a subclass of int, and "true" is not a quality of 1.
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _check_range(key: str, entry: dict, value) -> None:
    low, high = entry["minimum"], entry["maximum"]
    if not low <= value <= high:
        raise ValueError("设置 %s 必须在 %s 到 %s 之间。" % (key, low, high))


def validate_value(key: str, value):
    """Return `value` normalised, or raise ValueError describing the problem."""
    entry = SETTINGS.get(key)
    if entry is None:
        raise ValueError("存在未知设置项：%s" % key)
    kind = entry["kind"]
    if kind == "enum":
        if not isinstance(value, str) or value not in entry["choices"]:
            raise ValueError(
                "设置 %s 必须是 %s 之一。" % (key, "、".join(entry["choices"]))
            )
        return value
    if kind == "boolean":
        if not isinstance(value, bool):
            raise ValueError("设置 %s 必须是 true 或 false。" % key)
        return value
    if kind == "auto_or_number":
        if isinstance(value, str):
            if value != "auto":
                raise ValueError('设置 %s 只能是 "auto" 或数字。' % key)
            return value
        if not _is_number(value):
            raise ValueError('设置 %s 只能是 "auto" 或数字。' % key)
        _check_range(key, entry, value)
        return value
    if not _is_number(value):
        raise ValueError("设置 %s 必须是数字。" % key)
    _check_range(key, entry, value)
    if kind == "integer":
        if float(value) != int(value):
            raise ValueError("设置 %s 必须是整数。" % key)
        return int(value)
    return value


def validate(options: dict) -> dict:
    """Return a normalised settings dict, rejecting unknown keys and bad values."""
    if not isinstance(options, dict):
        raise ValueError("设置必须是一个 JSON 对象。")
    unknown = sorted(set(options) - ALL_KEYS)
    if unknown:
        raise ValueError("存在未知设置项：%s" % "、".join(unknown))
    # Ordered by the schema, so two settings dicts compare and diff cleanly.
    return {
        key: validate_value(key, options[key])
        for key in SETTINGS
        if key in options
    }
