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

Folder flags (`--recursive`, `--threads`, `--skip-existing`) stay in the CLI.
Each panel run writes into its own export directory, so it never needs to
replace an existing rendition.

``--no-verify`` is gone for a different reason: it is not a preference. The
converter verifies by decoding what it just encoded *before* writing it, so a
structurally broken gain map yields no file rather than a file that silently
opens as SDR on a phone. That is the failure this tool exists to prevent, and it
is not worth one decode to skip.
"""
from __future__ import annotations

import math
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
    "colorGamut": "srgb",
    "clampSrgb": False,
    "highlightRecovery": "blend",
    "contrast": 1.0,
    "vibrance": 0.0,
    "hdrStrength": 0.4,
    "hdrRange": 2.5,
    # The panel starts with a modest +0.6 EV lift after the renderer's
    # automatic exposure decision. The browser resets this image-scoped value
    # for every new upload.
    "brightness": 0.6,
    "expansionStart": 0.25,
    "areaCoverage": 1.0,
    "quality": 90,
    "lutInput": "srgb", "lutOutput": "srgb", "lutStrength": 1.0,
}

# AI controls are a post-processing layer over the model's spatial gain. They
# intentionally do not reuse the manual keys: a manual-mode request must keep
# emitting the same renderer flags even when a client sends a stale AI value.
AI_POST_DEFAULTS = {
    "aiBrightness": 0.0,
    "aiContrast": 1.0,
    "aiShadows": 0.0,
    "aiHighlights": 0.0,
    # Negative values are the native model layer's identity: preserve the
    # model's own range/knee until the user explicitly moves either slider.
    "aiHdrRange": -1.0,
    "aiExpansionStart": -1.0,
}

NATIVE_MODEL_ARTIFACT = "embedded"

_AI_POST_FLAGS = {
    "aiBrightness": ("--ai-brightness", -1.0, 1.0),
    "aiContrast": ("--ai-contrast", 0.8, 1.35),
    "aiShadows": ("--ai-shadows", -1.0, 1.0),
    "aiHighlights": ("--ai-highlights", -1.0, 1.0),
    "aiHdrRange": ("--ai-hdr-range", -1.0, 4.0),
    "aiExpansionStart": ("--ai-expansion-start", -1.0, 0.75),
}

#: Formats whose standard 1000-nit mapping cannot carry more than this.
_HLG_ENCODINGS = frozenset({"hlg", "avif-hlg"})
_HLG_MAX_STOPS = 2.3

#: Only the gain-map formats have a selectable base depth; BT.2100 is 10-bit.
_EIGHT_BIT_ENCODINGS = frozenset({"adaptive", "ultrahdr", "sdr-jpeg"})


def _headroom(options: dict, encoding: str):
    value = options.get(
        "hdrRange",
        _HLG_MAX_STOPS if encoding in _HLG_ENCODINGS else PANEL_DEFAULTS["hdrRange"])
    if encoding in _HLG_ENCODINGS and isinstance(value, (int, float)) and value > _HLG_MAX_STOPS:
        overflow = ValueError("HLG 动态范围不能超过 %s stops。" % _HLG_MAX_STOPS)
        overflow.code = "hlg_range"
        raise overflow
    return value


def options_to_settings(options: dict) -> dict:
    """Translate panel controls into the converter's settings vocabulary."""
    # A native model request develops its own deterministic SDR base. Keep the
    # panel's manual snapshot out of this translation too, so an old manual
    # HDR ceiling (especially one above HLG's limit) cannot reject or alter an
    # AI command before the model branch is selected.
    effective_options = options
    if bool(options.get("_model_mode")):
        effective_options = dict(options)
        effective_options.update({
            "brightness": 0.0,
            "contrast": PANEL_DEFAULTS["contrast"],
            "vibrance": PANEL_DEFAULTS["vibrance"],
            "hdrRange": (_HLG_MAX_STOPS
                          if options.get("encoding") in _HLG_ENCODINGS
                          else PANEL_DEFAULTS["hdrRange"]),
            "expansionStart": PANEL_DEFAULTS["expansionStart"],
            "areaCoverage": PANEL_DEFAULTS["areaCoverage"],
        })
        effective_options.setdefault("hdrStrength", 1.0)

    def value(key):
        return effective_options.get(key, PANEL_DEFAULTS[key])

    # Strength changes HDR gain only. Keep the photographic style fixed so
    # adjusting HDR does not also change base clarity and highlight colour.
    strength = value("hdrStrength")
    encoding = value("encoding")
    headroom = _headroom(effective_options, encoding)
    return validate_settings({
        "encoding": encoding,
        "lut_input": value("lutInput"),
        "lut_output": value("lutOutput"),
        "lut_strength": value("lutStrength"),
        "color_gamut": value("colorGamut"),
        "clamp_srgb": value("clampSrgb"),
        # Not a panel control, and pinned rather than passed through: the
        # renderer decides which curve the browser draws locally, so a client
        # that could choose it could make the preview disagree with the export. `photographic` is
        # currently the only look, which does not make sending it pointless --
        # this is the line that keeps a second one from arriving from a client.
        "look": "photographic",
        "highlight_recovery": value("highlightRecovery"),
        "contrast": value("contrast"),
        "vibrance": value("vibrance"),
        "gain_strength": strength,
        "pop": 0.0,
        "headroom_max": headroom,
        "headroom": headroom,
        "exposure": "auto",
        "exposure_bias": value("brightness"),
        "expansion_start": value("expansionStart"),
        "area_coverage": value("areaCoverage"),
        "quality": value("quality"),
    })


def _external_gain_pair(options: dict):
    """Return the external-gain pair, refusing a half-specified one.

    Both builders accept the pair and both have to refuse the same half of it:
    a raw grid carries neither dimensions nor scale, so without its JSON
    sidecar the converter has nothing to replay it against.
    """
    external_gain = options.get("external_gain")
    external_report = options.get("external_gain_report")
    if (external_gain or external_report) and not (external_gain and external_report):
        raise ValueError("external gain requires both raw grid and JSON report")
    return external_gain, external_report


def _model_mode(options: dict) -> bool:
    """Whether this command is rendering a model result.

    Generic external-gain callers must remain unchanged, so the API sets this
    private marker only for a native model request. Keeping this test in the
    command builder lets convert and preview share one post-adjustment mapping.
    """
    return bool(options.get("_model_mode"))


def _ai_post_flags(options: dict, encoding: str) -> list[str]:
    """Validate and serialize AI post-adjustments for the native CLI."""
    if not _model_mode(options):
        return []
    flags: list[str] = []
    for key, (flag, low, high) in _AI_POST_FLAGS.items():
        value = options.get(key, AI_POST_DEFAULTS[key])
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) or not low <= value <= high):
            raise ValueError("%s must be a finite number in [%s, %s]" %
                             (key, low, high))
        if key == "aiHdrRange" and value >= 0.0:
            ceiling = _HLG_MAX_STOPS if encoding in _HLG_ENCODINGS else high
            if value > ceiling:
                raise ValueError("AI HDR range cannot exceed %s stops for %s" %
                                 (ceiling, encoding))
        flags.extend([flag, fmt_num(value)])
    return flags


def _color_flags(options: dict, settings: dict) -> list[str]:
    """Serialize the input-gamut and output-clamp choices.

    The panel always supplies ``colorGamut`` through ``toOptions``; keeping
    the presence check here preserves the old CLI default for callers that do
    not send the new option yet.
    """
    flags: list[str] = []
    if "colorGamut" in options:
        flags.extend(["--color-gamut", settings["color_gamut"]])
    if settings["clamp_srgb"]:
        flags.append("--clamp-srgb")
    if options.get("_lut_path"):
        flags.extend(["--lut", str(options["_lut_path"]),
                      "--lut-input", settings["lut_input"], "--lut-output", settings["lut_output"],
                      "--lut-strength", fmt_num(settings["lut_strength"])])
    return flags


def build_argv(exe: str, options: dict) -> list[str]:
    """Build the `HyperDR convert` command line for one image."""
    settings = options_to_settings(options)
    encoding = settings["encoding"]
    external_gain, external_report = _external_gain_pair(options)
    if _model_mode(options):
        if external_gain or external_report:
            raise ValueError("native AI model cannot be combined with external gain")
        # The model consumes a deterministic SDR development produced by the
        # native renderer. Manual look controls are intentionally absent here:
        # brightness, contrast, vibrance, pop, exposure, headroom and the
        # manual expansion knee must not leak into model input. `gain_strength`
        # is the existing model-strength plumbing slot; the six ai-* flags are
        # applied only after native inference.
        argv = [
            exe, "convert", options["input"], "--output", options["output"],
            "--encoding", encoding,
            "--gain-strength", fmt_num(settings["gain_strength"]),
            "--highlight-recovery", settings["highlight_recovery"],
            "--quality", str(settings["quality"]),
            "--depth", "8" if encoding in _EIGHT_BIT_ENCODINGS else "10",
            "--report", options["report"],
            "--ai-model", NATIVE_MODEL_ARTIFACT,
        ]
        argv.extend(_color_flags(options, settings))
        argv.extend(_ai_post_flags(options, encoding))
        return argv
    if external_gain:
        # Legacy external-gain callers remain supported for native integrations
        # outside the panel; the panel's AI path uses the branch above.
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
        argv.extend(_color_flags(options, settings))
        # External model integrations may also opt into the native post layer.
        argv.extend(_ai_post_flags(options, encoding))
        legacy_env = {
            os.environ.get("HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN", ""),
            os.environ.get("HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA", ""),
        }
        if any(value.strip().lower() in {"1", "true", "yes", "on"} for value in legacy_env):
            argv.append("--allow-legacy-external-gain")
        return argv
    argv = [
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
    argv.extend(_color_flags(options, settings))
    # Manual mode never emits AI post flags, even if a stale browser snapshot
    # contains those independent keys.
    argv.extend(_ai_post_flags(options, encoding))
    return argv


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
    decode_cache=None, source_digest: str | None = None,
) -> list[str]:
    """Build the native float-preview command from the export settings."""
    settings = options_to_settings(options)
    if _model_mode(options):
        external_gain, external_report = _external_gain_pair(options)
        if external_gain or external_report:
            raise ValueError("native AI model cannot be combined with external gain")
        # Match the convert model branch: preview development is native and
        # pinned, while model strength and AI post controls remain adjustable.
        argv = [
            exe, "preview-frame", str(source), "--output", str(output),
            "--preview-max-edge", str(int(max_edge)),
            "--encoding", settings["encoding"],
            "--gain-strength", fmt_num(settings["gain_strength"]),
            "--highlight-recovery", settings["highlight_recovery"],
            "--ai-model", NATIVE_MODEL_ARTIFACT,
        ]
    else:
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
    argv.extend(_color_flags(options, settings))
    if decode_cache:
        argv.extend(["--decode-cache", str(decode_cache)])
    if source_digest:
        argv.extend(["--decode-cache-source-sha256", source_digest])
    external_gain, external_report = _external_gain_pair(options)
    if external_gain:
        argv.extend(["--external-gain", str(external_gain),
                     "--external-gain-report", str(external_report)])
    argv.extend(_ai_post_flags(options, settings["encoding"]))
    return argv
