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
import dataclasses
import json
from pathlib import Path

import colour
import numpy as np

from spektrafilm.config import STANDARD_OBSERVER_CMFS
from spektrafilm.model.couplers import compute_density_curves_before_dir_couplers, compute_dir_couplers_matrix
from spektrafilm.model.density_curves import interp_density_cmy_layers
from spektrafilm.model.diffusion import apply_halation_um
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.runtime.params_builder import _HALATION_PRESETS, digest_params, init_params
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.topology import Tap
from spektrafilm.utils.fast_gaussian_filter import _EXPONENTIAL_GAUSSIAN_FITS
from spektrafilm.utils.morph_curves import apply_print_curves_morph
from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "apps/apple/Packages/HyperDRRender"
RESOURCES = RENDER / "Sources/HyperDRRender/Resources/Film"
FIXTURE = RENDER / "Tests/HyperDRRenderTests/Fixtures/film-reference.json"

# HyperDR id and spektrafilm profile, in menu order (Recipe's Adjustments.filmStocks).
# Negatives print on the profile's target paper; slides are viewed directly.
STOCKS = [
    ("portra160", "kodak_portra_160"),
    ("portra400", "kodak_portra_400"),
    ("portra800", "kodak_portra_800"),
    ("portra800-push1", "kodak_portra_800_push1"),
    ("portra800-push2", "kodak_portra_800_push2"),
    ("ektar100", "kodak_ektar_100"),
    ("gold200", "kodak_gold_200"),
    ("ultramax400", "kodak_ultramax_400"),
    ("pro400h", "fujifilm_pro_400h"),
    ("c200", "fujifilm_c200"),
    ("xtra400", "fujifilm_xtra_400"),
    ("velvia100", "fujifilm_velvia_100"),
    ("provia100f", "fujifilm_provia_100f"),
    ("kodachrome64", "kodak_kodachrome_64"),
    ("ektachrome100", "kodak_ektachrome_100"),
    ("vision3-50d", "kodak_vision3_50d"),
    ("vision3-250d", "kodak_vision3_250d"),
    ("vision3-200t", "kodak_vision3_200t"),
    ("vision3-500t", "kodak_vision3_500t"),
    ("verita200d", "kodak_verita_200d"),
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
    params = digest_params(params)
    if film == "kodak_portra_400":
        # E-4050's red/green-sensitive flanks differ from the upstream profile.
        # Replace only the traced intervals, keeping upstream channel scaling,
        # tails, blue sensitivity, dyes, couplers and density curves unchanged.
        data = json.loads((ROOT / "scripts/data/portra400-e4050-sensitivity.json").read_text())
        grid = np.asarray(data["wavelengths"], dtype=float)
        wavelength = np.arange(380, 781, 5.0)
        sensitivity = np.array(params.film.data.log_sensitivity, dtype=float, copy=True)
        for channel, key in enumerate(("cyan", "magenta")):
            curve = np.asarray([np.nan if value is None else value for value in data[key]])
            valid = np.isfinite(curve)
            offset = np.nanmax(curve) - np.nanmax(sensitivity[:, channel])
            traced = (wavelength >= grid[valid].min()) & (wavelength <= grid[valid].max())
            sensitivity[traced, channel] = np.interp(wavelength[traced], grid[valid], curve[valid]) - offset
        params.film.data.log_sensitivity = sensitivity
    return params


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
    """Seven significant digits: float32 on the GPU, well inside the tests' tolerance."""
    values = np.nan_to_num(np.asarray(array, dtype=float))
    return np.vectorize(lambda v: float(f"{v:.7g}"))(values).tolist() if values.ndim else float(f"{values:.7g}")


def print_profile_for(film_name: str) -> str | None:
    film = init_params(film_name).film
    return None if film.is_positive else film.info.target_print


def convert(identifier: str, film_name: str, print_name: str | None) -> tuple[dict, SimulationPipeline, np.ndarray]:
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
        "name": film.info.name,
        "film": film_name,
        "print": print_name,
        "attribution": ATTRIBUTION + (" Portra 400 red/green sensitivity corrected from Kodak E-4050; "
            "see scripts/data/portra400-e4050-sensitivity.json." if identifier == "portra400" else ""),
        "filming": {
            "type": film.info.type,
            "p3ToReference": rows(p3_to_reference),
            # <id>.spectral beside this file: size × size × 3 little-endian float16, first index outermost.
            "spectralLUT": {"size": int(tc_lut.shape[0])},
            "logExposure": uniform_axis(film.data.log_exposure),
            "densityCurves": rows(normalized),
            "densityCurvesBeforeCouplers": rows(before),
            "couplers": rows(matrix),
            "densityMaximum": rows(np.nanmax(normalized, axis=0)),
            "channelDensity": rows(film.data.channel_density),
            "baseDensity": rows(film.data.base_density),
            "exposureScale": float(np.asarray(references.black_white_filming_exposure_correction()).reshape(-1)[0]),
            "grain": grain_table(params_for(film_name, print_name, grain=True), normalized),
            "halation": halation_parameters(film_name),
            "scatter": scatter_parameters(film_name),
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
    return resource, pipeline, tc_lut


def scanner_levels(references) -> list[float]:
    black, white = float(np.ravel(references._y_black)[0]), float(np.ravel(references._y_white)[0])
    slope = (references._white_level - references._black_level) / (white - black + 1e-10)
    return [float(slope), float(references._black_level - slope * black)]


def grain_table(params, normalized: np.ndarray) -> dict:
    """Film grain as spektrafilm's sublayer particle model, reduced to its cumulants:
    each sublayer develops Binomial(Poisson(n / s), p) = Poisson(n p / s) particles of
    density od * s, with p = d / dmax, s = 1 - p * uniformity and od = dmax / n, so its
    density variance is p s dmax^2 / n and its third cumulant p s^2 dmax^3 / n^2. n is
    proportional to the pixel area: per sublayer the tables hold variance x area (um^2)
    and third cumulant x area^2 (um^4) against the channel's density from 0 to its
    maximum. Each sublayer's dye clouds blur its particles by
    blur_dye_clouds * sqrt(od) pixels, a fixed size in micrometres; then the whole grain
    is blurred by `blur` pixels (the scan). Particles are counted on top of densityMinimum,
    which is subtracted after: grain never takes density below -densityMinimum."""
    grain = params.film_render.grain
    film = params.film
    layers = np.asarray(film.data.density_curves_layers, dtype=float)
    maximum_layers = np.nanmax(layers, axis=0)  # sublayer, channel
    fraction = maximum_layers / np.sum(maximum_layers, axis=0)[None, :]
    maximum_layers = maximum_layers + fraction * np.asarray(grain.density_min)[None, :]
    particle = grain.particle_area_um2 * np.asarray(grain.particle_scale)[None, :] * np.asarray(grain.particle_scale_layers)[:, None]
    densities = np.linspace(0, 1, GRAIN_SAMPLES)[:, None] * np.nanmax(normalized, axis=0)[None, :]
    per_layer = interp_density_cmy_layers(densities[None, :, :], normalized, layers, positive_film=film.is_positive)[0]
    layers_out = []
    for layer in range(3):
        d = per_layer[:, layer, :] + fraction[layer][None, :] * np.asarray(grain.density_min)[None, :]
        p = np.clip(d / maximum_layers[layer][None, :], 1e-6, 1 - 1e-6)
        saturation = 1 - p * np.asarray(grain.uniformity)[None, :] * (1 - 1e-6)
        variance = p * saturation * maximum_layers[layer] ** 2 * particle[layer] / fraction[layer]
        third = p * saturation ** 2 * maximum_layers[layer] ** 3 * particle[layer] ** 2 / fraction[layer] ** 2
        layers_out.append({"varianceArea": rows(variance), "thirdCumulantArea2": rows(third),
                           "dyeCloudMicrons": rows(grain.blur_dye_clouds_um
                                                   * np.sqrt(maximum_layers[layer] * particle[layer] / fraction[layer]))})
    return {"layers": layers_out, "blur": float(grain.blur), "densityMinimum": rows(grain.density_min),
            "filmFormatMillimetres": float(params.camera.film_format_mm)}


def halation_parameters(film_name: str) -> dict:
    """Back-reflection halation: the film exposure plus strength x a sum of `bounces`
    Gaussians of sigma sigmaMicrons * sqrt(k), weighted decay^(k-1) and normalised,
    divided by 1 + strength. `strengthRemoved` is the same film without its
    antihalation layer (spektrafilm's 'no' preset for its use)."""
    params = digest_params(init_params(film_name))
    halation, info = params.film_render.halation, params.film.info
    return {"sigmaMicrons": float(halation.halation_first_sigma_um[0]), "bounces": int(halation.halation_n_bounces),
            "decay": float(halation.halation_bounce_decay), "strength": rows(halation.halation_strength),
            "strengthRemoved": rows(_HALATION_PRESETS[(info.use, "no")]["strength"])}


def scatter_parameters(film_name: str) -> dict:
    """In-emulsion scatter, energy-preserving: (1 - tailWeight) x a Gaussian of sigma
    coreMicrons plus tailWeight x an exponential of decay tailMicrons, which spektrafilm
    evaluates as the Gaussian mixture `tailFit` (amplitude, sigma over decay)."""
    halation = digest_params(init_params(film_name)).film_render.halation
    return {"amount": float(halation.scatter_amount), "coreMicrons": rows(halation.scatter_core_um),
            "tailMicrons": rows(halation.scatter_tail_um), "tailWeight": rows(halation.scatter_tail_weight),
            "tailFit": rows(_EXPONENTIAL_GAUSSIAN_FITS[3])}


def scatter_reference(film_name: str) -> dict:
    """spektrafilm's scatter alone (no halation) on film exposure: a bright square, a
    point and a ramp on a dark field, 10 um pixels (every sigma under 3 pixels, so
    spektrafilm uses its truncated FIR, mode 'reflect'). The test rebuilds `raw`."""
    width, height, pixel = 40, 24, 10.0
    raw = np.full((height, width, 3), 0.02)
    raw[4:12, 6:16] = [40.0, 30.0, 20.0]
    raw[18, 24] = [200.0, 150.0, 90.0]
    raw[:, 32:] += (np.arange(width - 32) * 0.375)[None, :, None]
    halation = dataclasses.replace(digest_params(init_params(film_name)).film_render.halation,
                                   halation_strength=(0.0, 0.0, 0.0), boost_ev=0.0)
    return {"pixelMicrons": pixel, "width": width, "height": height,
            "scattered": rows(apply_halation_um(raw, halation, pixel).reshape(-1, 3))}


def halation_reference(film_name: str, print_name: str | None, removed: bool) -> dict:
    """spektrafilm's log film exposure along the centre row of a bright square on a dark
    field, with halation alone (no grain, scatter or other spatial effects)."""
    size, square, level, background = 1024, 32, 64.0, 0.02
    params = params_for(film_name, print_name, grain=True)
    params.film_render.grain.active = False
    params.film_render.halation.active = True
    params.film_render.halation.scatter_amount = 0.0
    if removed:
        params.film_render.halation.halation_strength = _HALATION_PRESETS[(params.film.info.use, "no")]["strength"]
    image = np.full((size, size, 3), background)
    image[(size - square) // 2:(size + square) // 2, (size - square) // 2:(size + square) // 2] = level
    log_exposure = SimulationPipeline(params).process(image, collect=Tap.LOG_E_FILM)
    start, row = size // 2 - 200, size // 2
    return {"size": size, "square": square, "level": level, "background": background, "removed": removed,
            "row": row, "start": start, "logExposure": rows(log_exposure[row, start:start + 400])}


def grain_reference(film_name: str, print_name: str | None) -> dict:
    """Statistics of spektrafilm's stochastic grain on flat fields (central crop): film
    density mean, RMS, skewness and the correlation of horizontal neighbours, for pixels
    from 91 um (a 384-pixel 35 mm frame) down to 1.5 um, where the dye clouds and the
    particle counts shape it. At 3 um and below the dye clouds correlate neighbouring
    pixels, so those fields are larger: on 384 pixels their skewness wanders by a tenth."""
    size, levels = 384, [0.03, 0.184, 0.8]
    result = []
    for pixel in [None, 6.0, 3.0, 1.5]:
        params = params_for(film_name, print_name, grain=True)
        field = 1024 if pixel is not None and pixel <= 3 else size
        if pixel is not None:
            params.camera.film_format_mm = pixel * field / 1000
        pipeline = SimulationPipeline(params)
        means, deviations, skews, correlations = [], [], [], []
        for level in levels:
            density = pipeline.process(np.full((field, field, 3), level), collect=Tap.CMY_FILM)[32:-32, 32:-32]
            flat = density.reshape(-1, 3)
            centred = flat - flat.mean(axis=0)
            means.append(flat.mean(axis=0))
            deviations.append(flat.std(axis=0))
            skews.append((centred ** 3).mean(axis=0) / flat.std(axis=0) ** 3)
            correlations.append([np.corrcoef(density[:, :-1, c].ravel(), density[:, 1:, c].ravel())[0, 1] for c in range(3)])
        result.append({"pixelMicrons": float(params.camera.film_format_mm * 1000 / field), "densityMean": rows(means),
                       "densityRMS": rows(deviations), "skewness": rows(skews), "correlation": rows(correlations)})
    return {"size": size, "levels": levels, "scales": result}


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
    parser.add_argument("--stock", choices=[stock for stock, _ in STOCKS], action="append",
                        help="regenerate only these stocks and their reference entries")
    arguments = parser.parse_args()

    inputs = reference_inputs()
    fixture = {"schema": "hyperdr.film-reference/v1", "attribution": ATTRIBUTION,
               "note": ("spektrafilm per-pixel outputs (no auto exposure, grain or spatial effects; scanner "
                        "black and white correction on), linear Display P3 in and out, output gamut compression "
                        "off; film density statistics of its grain on flat fields at several pixel sizes; log film exposure with halation alone "
                        "across a bright square (Vision3 500T without its antihalation layer); and film exposure "
                        "after in-emulsion scatter alone."),
               "inputs": rows(inputs), "outputs": {}, "grain": {}, "halation": {},
               "scatter": scatter_reference("kodak_portra_400")}
    RESOURCES.mkdir(parents=True, exist_ok=True)
    if arguments.stock:
        fixture = json.loads(FIXTURE.read_text())
        if "portra400" in arguments.stock:
            fixture["scatter"] = scatter_reference("kodak_portra_400")
    correction_note = " Portra 400 red/green sensitivity follows Kodak E-4050."
    if correction_note not in fixture["note"]:
        fixture["note"] += correction_note
    if not arguments.check and not arguments.stock:
        for old in list(RESOURCES.glob("*.json")) + list(RESOURCES.glob("*.spectral")):
            old.unlink()
    for identifier, film_name in STOCKS:
        if arguments.stock and identifier not in arguments.stock:
            continue
        print_name = print_profile_for(film_name)
        resource, pipeline, tc_lut = convert(identifier, film_name, print_name)
        output = pipeline.process(inputs[None, :, :])[0]
        fixture["outputs"][identifier] = rows(output)
        fixture["grain"][identifier] = grain_reference(film_name, print_name)
        if identifier in ("kodachrome64", "vision3-500t"):
            fixture["halation"][identifier] = halation_reference(film_name, print_name, removed=identifier == "vision3-500t")
        print(f"{identifier}: grey 18.4% -> {np.round(output[6], 4)}, 1 -> {np.round(output[11], 4)}, "
              f"16 -> {np.round(output[15], 4)}, grain RMS at 18.4% {np.round(fixture['grain'][identifier]['scales'][0]['densityRMS'][1], 4)}")
        if not arguments.check:
            text = json.dumps(resource, separators=(",", ":"), sort_keys=True)
            (RESOURCES / f"{identifier}.json").write_text(text + "\n")
            (RESOURCES / f"{identifier}.spectral").write_bytes(np.ascontiguousarray(tc_lut, dtype="<f2").tobytes())
    if not arguments.check:
        FIXTURE.write_text(json.dumps(fixture, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
