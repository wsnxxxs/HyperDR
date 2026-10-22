#!/usr/bin/env python3
"""Generate the framed-photo icon variants as Icon Composer layers.

Every layer is a 1024 x 1024 SVG holding one flat shape, so Icon Composer can
place it, recolour it per appearance and give it its own glass. The mat is the
document's background fill, not a layer. Run from anywhere:

    python3 make_icons.py
"""

import base64
import json
from pathlib import Path

SIZE = 1024
HERE = Path(__file__).resolve().parent

APPEARANCES = {
    "light": {"mat": "#EEEBE5", "photo": "#141414", "horizon": "#6E6E73",
              "light": "#FFFFFF", "caption": "#A39F96"},
    "dark": {"mat": "#262523", "photo": "#0A0A0A", "horizon": "#5A5A5E",
             "light": "#FFFFFF", "caption": "#6A665F"},
}


def bar(cx, cy, length, thickness):
    return {"kind": "bar", "x": cx - length / 2, "y": cy - thickness / 2,
            "w": length, "h": thickness}


def variant(photo, horizon, light, caption=None):
    x, y, w, h = photo
    shapes = {
        "photo": {"kind": "rect", "x": x, "y": y, "w": w, "h": h, "r": 10},
        "horizon": bar(x + w / 2, y + h * horizon[0], w - 2 * horizon[1],
                       horizon[2]),
        "light": {"kind": "circle", "cx": x + w * light[0],
                  "cy": y + h * light[1], "r": light[2]},
    }
    if caption:
        shapes["caption"] = bar(SIZE / 2, caption[0], caption[1], caption[2])
    return shapes


# photo = (x, y, w, h); horizon = (height fraction, inset, thickness);
# light = (x fraction, y fraction, radius); caption = (centre y, length, thickness).
# Every photo sits above the optical centre: the bottom margin is the widest.
VARIANTS = {
    "c1-square": variant((232, 168, 560, 560), (0.74, 84, 22),
                         (0.5, 0.45, 50), (852, 168, 18)),
    "c2-landscape": variant((192, 220, 640, 428), (0.72, 96, 22),
                            (0.62, 0.42, 44), (800, 168, 18)),
    "c3-portrait": variant((272, 152, 480, 600), (0.70, 72, 22),
                           (0.5, 0.40, 46)),
    "c4-wide-mat": variant((312, 232, 400, 400), (0.74, 60, 18),
                           (0.5, 0.44, 38), (760, 120, 16)),
}

# Back to front, the order Icon Composer lists them bottom-up.
LAYER_ORDER = ["photo", "horizon", "caption", "light"]
LAYER_FILES = {"photo": "1-photo.svg", "horizon": "2-horizon.svg",
               "caption": "3-caption.svg", "light": "4-light.svg"}


def shape_svg(shape, fill):
    if shape["kind"] == "circle":
        return (f'<circle cx="{shape["cx"]:g}" cy="{shape["cy"]:g}" '
                f'r="{shape["r"]:g}" fill="{fill}"/>')
    r = shape.get("r", shape["h"] / 2)
    return (f'<rect x="{shape["x"]:g}" y="{shape["y"]:g}" '
            f'width="{shape["w"]:g}" height="{shape["h"]:g}" '
            f'rx="{r:g}" fill="{fill}"/>')


def document(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" '
            f'height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">\n{body}\n</svg>\n')


def composite(shapes, colours, mask):
    parts = [shape_svg(shapes[name], colours[name])
             for name in LAYER_ORDER if name in shapes]
    # An approximation of the system mask, for previews only.
    rx = round(SIZE * 0.2237) if mask else 0
    clip = ('<defs><clipPath id="m"><rect width="1024" height="1024" '
            f'rx="{rx}"/></clipPath></defs>\n<g clip-path="url(#m)">\n')
    return document(clip + f'<rect width="1024" height="1024" '
                    f'fill="{colours["mat"]}"/>\n' + "\n".join(parts) + "\n</g>")


LABELS = {"c1-square": "C1 方幅", "c2-landscape": "C2 横幅",
          "c3-portrait": "C3 竖幅", "c4-wide-mat": "C4 宽边"}


def preview_page():
    """One self-contained page: each variant at several sizes and on a home screen."""
    icons = {name: {a: "data:image/svg+xml;base64," + base64.b64encode(
        composite(shapes, colours, mask=True).encode()).decode()
        for a, colours in APPEARANCES.items()} for name, shapes in VARIANTS.items()}
    template = (HERE / "preview.template.html").read_text()
    return (template.replace("/*ICONS*/null", json.dumps(icons))
            .replace("/*LABELS*/null", json.dumps(LABELS, ensure_ascii=False)))


def main():
    for name, shapes in VARIANTS.items():
        layers = HERE / name / "layers"
        layers.mkdir(parents=True, exist_ok=True)
        for stale in layers.glob("*.svg"):
            stale.unlink()
        for layer in LAYER_ORDER:
            if layer in shapes:
                fill = APPEARANCES["light"][layer]
                (layers / LAYER_FILES[layer]).write_text(
                    document(shape_svg(shapes[layer], fill)))
        for appearance, colours in APPEARANCES.items():
            (HERE / name / f"preview-{appearance}.svg").write_text(
                composite(shapes, colours, mask=True))
    (HERE / "preview.html").write_text(preview_page())
    print("wrote", ", ".join(VARIANTS), "and preview.html")


if __name__ == "__main__":
    main()
