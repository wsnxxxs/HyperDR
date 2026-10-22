#!/usr/bin/env python3
"""Generate the instant-print icon variants as Icon Composer layers.

Every layer is a 1024 x 1024 SVG holding one flat shape. Tilts are baked into
the path coordinates, so Icon Composer only has to place and recolour them.
The backdrop is the document's background fill, not a layer. Run from anywhere:

    python3 make_icons.py
"""

import base64
import json
import math
from pathlib import Path

SIZE = 1024
HERE = Path(__file__).resolve().parent

APPEARANCES = {
    "light": {"backdrop": "#22211F", "back": "#CFCAC1", "card": "#F6F4EF",
              "photo": "#161514", "horizon": "#6E6E73", "light": "#FFFFFF"},
    "dark": {"backdrop": "#0E0E0D", "back": "#7E7A73", "card": "#D9D6CF",
             "photo": "#0A0A0A", "horizon": "#5A5A5E", "light": "#FFFFFF"},
}


def rotate(x, y, angle, origin):
    a = math.radians(angle)
    dx, dy = x - origin[0], y - origin[1]
    return (origin[0] + dx * math.cos(a) - dy * math.sin(a),
            origin[1] + dx * math.sin(a) + dy * math.cos(a))


def rounded_rect(x, y, w, h, r, angle=0, origin=(512, 512)):
    """A rounded rectangle as a path, turned by `angle` degrees about `origin`."""
    steps = [("M", x + r, y), ("L", x + w - r, y), ("A", x + w, y + r),
             ("L", x + w, y + h - r), ("A", x + w - r, y + h), ("L", x + r, y + h),
             ("A", x, y + h - r), ("L", x, y + r), ("A", x + r, y)]
    d = []
    for op, px, py in steps:
        px, py = rotate(px, py, angle, origin)
        arc = f"A{r:g} {r:g} 0 0 1 " if op == "A" else op
        d.append(f"{arc}{px:.2f} {py:.2f}")
    return {"path": " ".join(d) + " Z"}


def circle(cx, cy, r, angle=0, origin=(512, 512)):
    cx, cy = rotate(cx, cy, angle, origin)
    return {"circle": (cx, cy, r)}


def motif(px, py, size, angle=0, origin=(512, 512)):
    """The photograph: a light above the white line, as in the framed variants."""
    t = max(18, 22 * size / 560)
    return {
        "photo": rounded_rect(px, py, size, size, 4, angle, origin),
        "horizon": rounded_rect(px + 0.15 * size, py + 0.74 * size - t / 2,
                                0.7 * size, t, t / 2, angle, origin),
        "light": circle(px + 0.5 * size, py + 0.45 * size, 0.09 * size,
                        angle, origin),
    }


def instant(x, y, w, angle=0, back=None, developing=False):
    """An instant print in square-format proportions: a 72 x 86 card holding a
    62 x 62 image, 5 at the sides and 6.5 at the top, the rest below.
    `back` = (dx, dy, angle) adds a second, plain card behind it. A
    `developing` print shows only its highlight: the rest has not come up yet."""
    k = w / 72
    h = 86 * k
    origin = (x + w / 2, y + h / 2)
    shapes = {}
    if back:
        bx, by = x + back[0], y + back[1]
        shapes["back"] = rounded_rect(bx, by, w, h, 16, back[2],
                                      (bx + w / 2, by + h / 2))
    shapes["card"] = rounded_rect(x, y, w, h, 16, angle, origin)
    shapes.update(motif(x + 5 * k, y + 6.5 * k, 62 * k, angle, origin))
    if developing:
        del shapes["horizon"]
    return shapes


# Each variant: its shapes and, per appearance, colours that differ from
# APPEARANCES. A 568-wide card is 678 tall, centred at y = 173.
VARIANTS = {
    "p1-upright": (instant(228, 173, 568), {}),
    "p2-tilted": (instant(228, 173, 568, angle=-7), {}),
    "p3-developing": (instant(228, 173, 568, developing=True),
                      {"light": {"photo": "#5B605B"},
                       "dark": {"photo": "#3C403C"}}),
    "p4-stacked": (instant(212, 190, 568, angle=-3, back=(34, -34, 7)), {}),
}
LABELS = {"p1-upright": "P1 正放", "p2-tilted": "P2 微倾",
          "p3-developing": "P3 显影", "p4-stacked": "P4 叠放"}


def colours_for(overrides, appearance):
    return {**APPEARANCES[appearance], **overrides.get(appearance, {})}

# Back to front.
LAYER_ORDER = ["back", "card", "photo", "horizon", "light"]


def shape_svg(shape, fill, shadow=False):
    extra = ' filter="url(#s)"' if shadow else ""
    if "circle" in shape:
        cx, cy, r = shape["circle"]
        return f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:g}" fill="{fill}"/>'
    return f'<path d="{shape["path"]}" fill="{fill}"{extra}/>'


def document(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" '
            f'height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">\n{body}\n</svg>\n')


def composite(shapes, colours):
    """A preview with an approximate system mask and a stand-in for the
    shadow Icon Composer adds to the cards."""
    rx = round(SIZE * 0.2237)
    defs = ('<defs><clipPath id="m"><rect width="1024" height="1024" '
            f'rx="{rx}"/></clipPath><filter id="s" x="-20%" y="-20%" '
            'width="140%" height="140%"><feDropShadow dx="0" dy="18" '
            'stdDeviation="22" flood-color="#000" flood-opacity="0.35"/>'
            '</filter></defs>\n')
    parts = [shape_svg(shapes[n], colours[n], shadow=n in ("back", "card"))
             for n in LAYER_ORDER if n in shapes]
    return document(defs + '<g clip-path="url(#m)">\n'
                    f'<rect width="1024" height="1024" fill="{colours["backdrop"]}"/>\n'
                    + "\n".join(parts) + "\n</g>")


def preview_page():
    icons = {name: {a: "data:image/svg+xml;base64," + base64.b64encode(
        composite(shapes, colours_for(overrides, a)).encode()).decode()
        for a in APPEARANCES}
        for name, (shapes, overrides) in VARIANTS.items()}
    template = (HERE / "preview.template.html").read_text()
    return (template.replace("/*ICONS*/null", json.dumps(icons))
            .replace("/*LABELS*/null", json.dumps(LABELS, ensure_ascii=False)))


def main():
    for name, (shapes, overrides) in VARIANTS.items():
        layers = HERE / name / "layers"
        layers.mkdir(parents=True, exist_ok=True)
        for stale in layers.glob("*.svg"):
            stale.unlink()
        present = [n for n in LAYER_ORDER if n in shapes]
        for index, layer in enumerate(present, 1):
            fill = colours_for(overrides, "light")[layer]
            (layers / f"{index}-{layer}.svg").write_text(
                document(shape_svg(shapes[layer], fill)))
        for appearance in APPEARANCES:
            (HERE / name / f"preview-{appearance}.svg").write_text(
                composite(shapes, colours_for(overrides, appearance)))
    (HERE / "preview.html").write_text(preview_page())
    print("wrote", ", ".join(VARIANTS), "and preview.html")


if __name__ == "__main__":
    main()
