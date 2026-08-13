"""Translating panel controls into a HyperDR command line.

This is the only command builder in the project. The front-end used to assemble
a second copy purely for display and the two had already drifted apart, so the
command shown to the user was not the command that ran. The panel renders
whatever this module returns.

Panel controls are camelCase and deliberately fewer than the converter's
settings: one slider drives two settings in a couple of places. The translation
runs in one direction only. Named presets used to make it a round trip -- the
panel wrote a settings file, then read it back into the controls -- and that
reverse path is gone with them.

Five settings the panel used to expose are gone, and their absence is the point:

``--recursive`` and ``--threads`` only meant something when a run could cover a
folder. ``--skip-existing`` only meant something when that folder might already
hold output from an earlier pass. ``--overwrite`` never meant anything at all --
the session's output directory is emptied before every run, so there was nothing
there to overwrite, and the export step copies with ``shutil.copy2``, which
overwrites regardless.

``--no-verify`` is gone for a different reason: it is not a preference. The
converter verifies by decoding what it just encoded *before* writing it, so a
structurally broken gain map yields no file rather than a file that silently
opens as SDR on a phone. That is the failure this tool exists to prevent, and it
is not worth one decode to skip.
"""
from __future__ import annotations

import os

from .schema import validate as validate_settings
from .formats import RAW_INPUT_EXTENSIONS


def fmt_num(value) -> str:
    text = ("%.3f" % float(value)).rstrip("0").rstrip(".")
    return text if text else "0"


#: The single place that knows how a panel control maps onto a converter
#: setting, and the value used when the browser omits one.
PANEL_DEFAULTS = {
    "encoding": "adaptive",
    "highlightRecovery": "blend",
    "contrast": 1.08,
    "vibrance": 0.12,
    "hdrStrength": 0.4,
    "hdrRange": 2.5,
    # Raster inputs are already display-referred and RAW automatic exposure
    # supplies its own anchor. A neutral bias avoids lifting both paths by a
    # hidden extra stop before the user touches the control.
    "brightness": 0.0,
    "expansionStart": 0.25,
    "areaCoverage": 1.0,
    "quality": 90,
}

#: Formats whose standard 1000-nit mapping cannot carry more than this.
_HLG_ENCODINGS = frozenset({"hlg", "avif-hlg"})
_HLG_MAX_STOPS = 2.3

#: Only the gain-map formats have a selectable base depth; BT.2100 is 10-bit.
_EIGHT_BIT_ENCODINGS = frozenset({"adaptive", "ultrahdr"})


def _headroom(options: dict, encoding: str):
    value = options.get(
        "hdrRange",
        _HLG_MAX_STOPS if encoding in _HLG_ENCODINGS else PANEL_DEFAULTS["hdrRange"])
    if encoding in _HLG_ENCODINGS and isinstance(value, (int, float)) and value > _HLG_MAX_STOPS:
        raise ValueError("HLG 动态范围不能超过 %s stops。" % _HLG_MAX_STOPS)
    return value


def options_to_settings(options: dict) -> dict:
    """Translate panel controls into the converter's settings vocabulary."""
    def value(key):
        return options.get(key, PANEL_DEFAULTS[key])

    # One panel knob drives two converter settings in each of these pairs:
    # strength sets both the local gain and the EDR "pop", and the range slider
    # is both the auto-headroom ceiling and the explicit target, which is what
    # keeps a slider move deterministic rather than content-dependent.
    strength = value("hdrStrength")
    encoding = value("encoding")
    headroom = _headroom(options, encoding)
    return validate_settings({
        "encoding": encoding,
        # Not a panel control, and pinned rather than passed through: the
        # renderer decides what /api/curve draws, so a client that could choose
        # it could make the preview disagree with the export. `photographic` is
        # currently the only look, which does not make sending it pointless --
        # this is the line that keeps a second one from arriving from a client.
        "look": "photographic",
        "highlight_recovery": value("highlightRecovery"),
        "contrast": value("contrast"),
        "vibrance": value("vibrance"),
        "gain_strength": strength,
        "pop": strength,
        "headroom_max": headroom,
        "headroom": headroom,
        "exposure": "auto",
        "exposure_bias": value("brightness"),
        "expansion_start": value("expansionStart"),
        "area_coverage": value("areaCoverage"),
        "quality": value("quality"),
    })


def build_argv(exe: str, options: dict) -> list[str]:
    """Build the `HyperDR convert` command line for one image."""
    settings = options_to_settings(options)
    encoding = settings["encoding"]
    external_gain = options.get("external_gain")
    external_report = options.get("external_gain_report")
    if external_gain or external_report:
        if not external_gain or not external_report:
            raise ValueError("external gain requires both raw grid and JSON report")
        # The sidecar freezes the photographic development used for inference;
        # the converter validates and replays it before replacing only Gain.
        argv = [
            exe, "convert", options["input"], "--output", options["output"],
            "--encoding", encoding,
            "--gain-strength", fmt_num(settings["gain_strength"]),
            "--highlight-recovery", settings["highlight_recovery"],
            "--quality", str(settings["quality"]),
            "--depth", "8" if encoding in _EIGHT_BIT_ENCODINGS else "10",
            "--report", options["report"],
            "--external-gain", str(external_gain),
            "--external-gain-report", str(external_report),
        ]
        legacy_env = {
            os.environ.get("HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN", ""),
            os.environ.get("HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA", ""),
        }
        if any(value.strip().lower() in {"1", "true", "yes", "on"} for value in legacy_env):
            argv.append("--allow-legacy-external-gain")
        return argv
    return [
        exe, "convert", options["input"], "--output", options["output"],
        "--encoding", encoding,
        "--look", settings["look"],
        "--contrast", fmt_num(settings["contrast"]),
        "--vibrance", fmt_num(settings["vibrance"]),
        "--gain-strength", fmt_num(settings["gain_strength"]),
        "--headroom-max", fmt_num(settings["headroom_max"]),
        "--pop", fmt_num(settings["pop"]),
        "--exposure-bias", fmt_num(settings["exposure_bias"]),
        "--expansion-start", fmt_num(settings["expansion_start"]),
        "--area-coverage", fmt_num(settings["area_coverage"]),
        "--exposure", "auto",
        "--headroom", fmt_num(settings["headroom"]),
        "--highlight-recovery", settings["highlight_recovery"],
        "--quality", str(settings["quality"]),
        "--depth", "8" if encoding in _EIGHT_BIT_ENCODINGS else "10",
        "--report", options["report"],
    ]


def build_curve_argv(exe: str, options: dict, samples: int = 257) -> list[str]:
    """Command line for the converter's own tone-curve export."""
    settings = options_to_settings(options)
    return [
        exe, "curve",
        "--encoding", settings["encoding"],
        "--look", settings["look"],
        "--contrast", fmt_num(settings["contrast"]),
        "--vibrance", fmt_num(settings["vibrance"]),
        "--pop", fmt_num(settings["pop"]),
        "--gain-strength", fmt_num(settings["gain_strength"]),
        "--exposure-bias", fmt_num(settings["exposure_bias"]),
        "--expansion-start", fmt_num(settings["expansion_start"]),
        "--area-coverage", fmt_num(settings["area_coverage"]),
        "--headroom-max", fmt_num(settings["headroom_max"]),
        "--headroom", fmt_num(settings["headroom"]),
        "--samples", str(int(samples)),
    ]


def build_preview_frame_argv(
    exe: str, source, output, options: dict, max_edge: int,
) -> list[str]:
    """Build the native float-preview command from the export settings."""
    settings = options_to_settings(options)
    argv = [
        exe, "preview-frame", str(source), "--output", str(output),
        "--preview-max-edge", str(int(max_edge)),
        "--encoding", settings["encoding"],
        "--look", settings["look"],
        "--contrast", fmt_num(settings["contrast"]),
        "--vibrance", fmt_num(settings["vibrance"]),
        "--gain-strength", fmt_num(settings["gain_strength"]),
        "--headroom-max", fmt_num(settings["headroom_max"]),
        "--pop", fmt_num(settings["pop"]),
        "--exposure-bias", fmt_num(settings["exposure_bias"]),
        "--expansion-start", fmt_num(settings["expansion_start"]),
        "--area-coverage", fmt_num(settings["area_coverage"]),
        "--exposure", "auto", "--headroom", fmt_num(settings["headroom"]),
        "--highlight-recovery", settings["highlight_recovery"],
    ]
    if str(source).lower().endswith(tuple(RAW_INPUT_EXTENSIONS)):
        argv.append("--fast-preview")
    external_gain = options.get("external_gain")
    external_report = options.get("external_gain_report")
    if external_gain or external_report:
        if not external_gain or not external_report:
            raise ValueError("external gain requires both raw grid and JSON report")
        argv.extend(["--external-gain", str(external_gain),
                     "--external-gain-report", str(external_report)])
    return argv
