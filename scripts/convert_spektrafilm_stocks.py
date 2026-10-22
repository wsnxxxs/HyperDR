#!/usr/bin/env python3
"""Convert spektrafilm stock profiles into HyperDRRender film resources.

HyperDRRender evaluates the film model per pixel (exposure, development with
DIR couplers, printing, scanning). This script only prepares its inputs: it
resamples spektrafilm's spectral data onto the 81-wavelength grid, bakes the
Hanatos 2025 spectral upsampling into a per-film chromaticity table, resolves
illuminants, neutral print filters and colour matrices, and evaluates the
fitted density curves. It also writes reference outputs from spektrafilm's own
pipeline for the tests: per-pixel outputs with grain, halation and other
spatial effects off, and the film grain's density RMS on flat fields.

Run it with a spektrafilm checkout and its runtime dependencies:

    PYTHONPATH=<spektrafilm>/src python3 scripts/convert_spektrafilm_stocks.py

The profiles are CC BY-SA 4.0 (Andrea Volpato,
https://github.com/andreavolpato/spektrafilm); every resource keeps that
attribution and notes that HyperDR converted it.
"""
from __future__ import annotations

import argparse
import base64
import dataclasses
import json
from pathlib import Path

import colour
import numpy as np

from spektrafilm.config import STANDARD_OBSERVER_CMFS
from spektrafilm.model.couplers import compute_density_curves_before_dir_couplers, compute_dir_couplers_matrix
from spektrafilm.model.density_curves import interp_density_cmy_layers
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.runtime.params_builder import digest_params, init_params
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.topology import Tap
from spektrafilm.utils.morph_curves import apply_print_curves_morph
from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "apps/apple/Packages/HyperDRRender"
RESOURCES = RENDER / "Sources/HyperDRRender/Resources/Film"
FIXTURE = RENDER / "Tests/HyperDRRenderTests/Fixtures/film-reference.json"

# id, display name, film profile, print profile (None: a reversal film viewed directly)
STOCKS = [
    ("portra400", "Kodak Portra 400", "kodak_portra_400", "kodak_portra_endura"),
    ("velvia100", "Fujifilm Velvia 100", "fujifilm_velvia_100", None),
    ("vision3-500t", "Kodak Vision3 500T", "kodak_vision3_500t", "kodak_2383"),
]

ATTRIBUTION = ("Derived from spektrafilm by Andrea Volpato, https://github.com/andreavolpato/spektrafilm, "
               "licensed CC BY-SA 4.0. Converted for HyperDR: spectral upsampling baked per film, "
               "illuminants, neutral print filters, scanner black and white levels and fitted curves resolved, "
               "grain variance tabulated, NaN wavelengths masked.")

# Grain is evaluated for a 35 mm frame: the pixel pitch is FILM_FORMAT_MM over the long edge.
GRAIN_SAMPLES = 256


def params_for(film: str, print_profile: str | None, grain: bool = False):
    """Per-pixel settings: no auto exposure; spatial and stochastic effects off unless
    `grain` asks for the grain alone (no halation, coupler diffusion or blur besides it).
    The scanner maps paper (or slide) white and black to its white and black levels."""
    params = init_params(film, print_profile or "kodak_portra_endura")
    params.camera.auto_exposure = False
    params.scanner.white_correction = True
    params.scanner.black_correction = True
    if grain:
        params.film_render.halation.active = False
        params.film_render.dir_couplers.diffusion_size_um = 0
        params.scanner.unsharp_mask = (0.0, 0.0)
    else:
        params.debug.deactivate_spatial_effects = True
        params.debug.deactivate_stochastic_effects = True
    params.io.input_color_space = "Display P3"
    params.io.input_cctf_decoding = False
    params.io.output_color_space = "Display P3"
    params.io.output_cctf_encoding = False
    params.io.output_gamut_compress = dataclasses.replace(params.io.output_gamut_compress, algorithm="off")
    params.io.scan_film = print_profile is None
    return digest_params(params)


def linear_matrix(function) -> np.ndarray:
    """The 3x3 matrix M of a linear map, rows are outputs: f(rgb) = M @ rgb."""
    columns = [np.asarray(function(np.eye(3)[i]), dtype=float) for i in range(3)]
    return np.stack(columns, axis=1)


def uniform_axis(values) -> list[float]:
    axis = np.asarray(values, dtype=float)
    steps = np.diff(axis)
    assert np.allclose(steps, steps[0], rtol=0, atol=1e-9), "log exposure axis must be uniform"
    return [float(axis[0]), float(axis[-1]), int(axis.size)]


def masked(illuminant, channel_density, base_density) -> np.ndarray:
    """Light through a dye layer is zero where spektrafilm's spectral density is NaN."""
    channel = np.asarray(channel_density, dtype=float)
    base = np.asarray(base_density, dtype=float)
    mask = np.isnan(channel).any(axis=1) | np.isnan(base)
    light = np.array(illuminant, dtype=float)
    light[mask] = 0
    return light


def rows(array) -> list:
    return np.round(np.nan_to_num(np.asarray(array, dtype=float)), 12).tolist()


def floats_base64(array) -> str:
    return base64.b64encode(np.ascontiguousarray(array, dtype="<f4").tobytes()).decode("ascii")


def convert(identifier: str, name: str, film_name: str, print_name: str | None) -> tuple[dict, SimulationPipeline]:
    params = params_for(film_name, print_name)
    pipeline = SimulationPipeline(params)
    # One pixel through the pipeline resolves the scanner's black and white references.
    pipeline.process(np.full((1, 1, 3), 0.184))
    references = pipeline._color_reference_service
    film = params.film

    sensitivity = np.nan_to_num(10 ** np.asarray(film.data.log_sensitivity, dtype=float))
    tc_lut = pipeline._lut_service.get_filming_tc_lut(sensitivity)
    reference_xy = _illuminant_to_xy(film.info.reference_illuminant)
    p3_to_reference = linear_matrix(lambda rgb: colour.RGB_to_XYZ(
        rgb, colourspace="Display P3", apply_cctf_decoding=False,
        illuminant=reference_xy, chromatic_adaptation_transform="CAT16"))

    curves = np.asarray(film.data.density_curves, dtype=float)
    normalized = curves - np.nanmin(curves, axis=0)
    couplers = params.film_render.dir_couplers
    matrix = compute_dir_couplers_matrix(couplers) * couplers.amount if couplers.active else np.zeros((3, 3))
    before = compute_density_curves_before_dir_couplers(
        normalized, np.asarray(film.data.log_exposure, dtype=float), matrix, positive=film.is_positive)

    resource = {
        "schema": "hyperdr.film/v1",
        "id": identifier,
        "name": name,
        "film": film_name,
        "print": print_name,
        "attribution": ATTRIBUTION,
        "filming": {
            "type": film.info.type,
            "p3ToReference": rows(p3_to_reference),
            "spectralLUT": {"size": int(tc_lut.shape[0]), "float32": floats_base64(tc_lut)},
            "logExposure": uniform_axis(film.data.log_exposure),
            "densityCurves": rows(normalized),
            "densityCurvesBeforeCouplers": rows(before),
            "couplers": rows(matrix),
            "densityMaximum": rows(np.nanmax(normalized, axis=0)),
            "channelDensity": rows(film.data.channel_density),
            "baseDensity": rows(film.data.base_density),
            "exposureScale": float(np.asarray(references.black_white_filming_exposure_correction()).reshape(-1)[0]),
            "grain": grain_table(params_for(film_name, print_name, grain=True), normalized),
        },
    }

    if print_name is None:
        scanned = film
    else:
        printing = pipeline._printing_stage
        paper = params.print
        enlarger = pipeline._enlarger_service.enlarger_filtered_illuminant(standard_illuminant(params.enlarger.illuminant))
        paper_sensitivity = np.nan_to_num(10 ** np.asarray(paper.data.log_sensitivity, dtype=float))
        scale = float(np.asarray(printing._compute_exposure_factor_midgray(paper_sensitivity, enlarger)).reshape(-1)[0])
        scale *= params.enlarger.print_exposure
        scale *= float(np.asarray(references.black_white_printing_exposure_correction()).reshape(-1)[0])
        paper_curves = apply_print_curves_morph(
            np.asarray(paper.data.log_exposure, dtype=float), paper.data.density_curves_model,
            params.print_render.density_curves_morph, profile_type=paper.info.type)
        resource["printing"] = {
            "illuminant": rows(masked(enlarger, film.data.channel_density, film.data.base_density)),
            "sensitivity": rows(paper_sensitivity),
            "exposureScale": scale,
            "logExposure": uniform_axis(paper.data.log_exposure),
            "densityCurves": rows(paper_curves),
            "channelDensity": rows(paper.data.channel_density),
            "baseDensity": rows(paper.data.base_density),
        }
        scanned = paper

    viewing = standard_illuminant(scanned.info.viewing_illuminant)
    normalization = np.sum(viewing * STANDARD_OBSERVER_CMFS[:, 1])
    viewing_xyz = (viewing @ STANDARD_OBSERVER_CMFS[:]) / normalization
    viewing_xy = colour.XYZ_to_xy(viewing_xyz)
    xyz_to_p3 = linear_matrix(lambda xyz: colour.XYZ_to_RGB(
        xyz, colourspace="Display P3", apply_cctf_encoding=False, illuminant=viewing_xy))
    resource["scanning"] = {
        "illuminant": rows(masked(viewing, scanned.data.channel_density, scanned.data.base_density)),
        "observer": rows(np.asarray(STANDARD_OBSERVER_CMFS[:]) / normalization),
        "xyzToP3": rows(xyz_to_p3),
        # Y' = clamp(slope * Y + offset, 0, 1), XYZ scaled by Y'/Y (spektrafilm's scanner correction).
        "levels": scanner_levels(references),
    }
    return resource, pipeline


def scanner_levels(references) -> list[float]:
    black, white = float(np.ravel(references._y_black)[0]), float(np.ravel(references._y_white)[0])
    slope = (references._white_level - references._black_level) / (white - black + 1e-10)
    return [float(slope), float(references._black_level - slope * black)]


def grain_table(params, normalized: np.ndarray) -> dict:
    """Film grain as spektrafilm's sublayer particle model, reduced to its variance:
    each sublayer develops Binomial(Poisson(n / s), p) particles of density od * s with
    p = d / dmax and s = 1 - p * uniformity, so its density variance is p * s * dmax^2 / n.
    n is proportional to the pixel area; the table holds variance x area (um^2) against
    the channel's density from 0 to its maximum. The blur is in pixels."""
    grain = params.film_render.grain
    film = params.film
    layers = np.asarray(film.data.density_curves_layers, dtype=float)
    maximum_layers = np.nanmax(layers, axis=0)  # sublayer, channel
    fraction = maximum_layers / np.sum(maximum_layers, axis=0)[None, :]
    maximum_layers = maximum_layers + fraction * np.asarray(grain.density_min)[None, :]
    particle = grain.particle_area_um2 * np.asarray(grain.particle_scale)[None, :] * np.asarray(grain.particle_scale_layers)[:, None]
    densities = np.linspace(0, 1, GRAIN_SAMPLES)[:, None] * np.nanmax(normalized, axis=0)[None, :]
    per_layer = interp_density_cmy_layers(densities[None, :, :], normalized, layers, positive_film=film.is_positive)[0]
    variance = np.zeros((GRAIN_SAMPLES, 3))
    for layer in range(3):
        d = per_layer[:, layer, :] + fraction[layer][None, :] * np.asarray(grain.density_min)[None, :]
        p = np.clip(d / maximum_layers[layer][None, :], 1e-6, 1 - 1e-6)
        saturation = 1 - p * np.asarray(grain.uniformity)[None, :] * (1 - 1e-6)
        variance += p * saturation * maximum_layers[layer] ** 2 * particle[layer] / fraction[layer]
    return {"varianceArea": rows(variance), "blur": float(grain.blur),
            "filmFormatMillimetres": float(params.camera.film_format_mm)}


def grain_reference(film_name: str, print_name: str | None) -> dict:
    """Density RMS of spektrafilm's stochastic grain on flat fields, central crop."""
    size, levels = 384, [0.03, 0.184, 0.8]
    params = params_for(film_name, print_name, grain=True)
    pipeline = SimulationPipeline(params)
    means, deviations = [], []
    for level in levels:
        density = pipeline.process(np.full((size, size, 3), level), collect=Tap.CMY_FILM)[32:-32, 32:-32]
        means.append(density.reshape(-1, 3).mean(axis=0))
        deviations.append(density.reshape(-1, 3).std(axis=0))
    return {"size": size, "levels": levels, "densityMean": rows(means), "densityRMS": rows(deviations)}


def reference_inputs() -> np.ndarray:
    grey = [[v, v, v] for v in (0, .002, .01, .03, .06, .1, .184, .3, .45, .6, .8, 1, 2, 4, 8, 16)]
    colours = []
    for level in (.05, .184, .5, 1):
        for rgb in ((1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0)):
            colours.append([level * c for c in rgb])
    skin = [[.45, .3, .22], [.25, .15, .1], [.7, .52, .42]]
    sky_foliage = [[.12, .25, .55], [.08, .2, .05], [.3, .35, .12]]
    random = np.random.default_rng(20261022).uniform(0, 1, (24, 3)).tolist()
    random += (np.random.default_rng(20261023).uniform(0, 1, (8, 3)) * 6).tolist()
    return np.array(grey + colours + skin + sky_foliage + random, dtype=float)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="only report the reference spread, write nothing")
    arguments = parser.parse_args()

    inputs = reference_inputs()
    fixture = {"schema": "hyperdr.film-reference/v1", "attribution": ATTRIBUTION,
               "note": ("spektrafilm per-pixel outputs (no auto exposure, grain or spatial effects; scanner "
                        "black and white correction on), linear Display P3 in and out, output gamut compression "
                        "off; and film density RMS of its grain on flat fields."),
               "inputs": rows(inputs), "outputs": {}, "grain": {}}
    RESOURCES.mkdir(parents=True, exist_ok=True)
    for identifier, name, film_name, print_name in STOCKS:
        resource, pipeline = convert(identifier, name, film_name, print_name)
        output = pipeline.process(inputs[None, :, :])[0]
        fixture["outputs"][identifier] = rows(output)
        fixture["grain"][identifier] = grain_reference(film_name, print_name)
        print(f"{identifier}: grey 18.4% -> {np.round(output[6], 4)}, 1 -> {np.round(output[11], 4)}, "
              f"16 -> {np.round(output[15], 4)}, grain RMS at 18.4% {np.round(fixture['grain'][identifier]['densityRMS'][1], 4)}")
        if not arguments.check:
            text = json.dumps(resource, separators=(",", ":"), sort_keys=True)
            (RESOURCES / f"{identifier}.json").write_text(text + "\n")
    if not arguments.check:
        FIXTURE.write_text(json.dumps(fixture, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
