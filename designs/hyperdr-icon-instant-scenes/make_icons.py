#!/usr/bin/env python3
"""Generate the stacked instant-print icon with four photographs.

Each scene is a high-contrast subject whose brightest thing is the light
itself: a sunset, a sun over mountains, a moon over water, a window. Every
layer is a 1024 x 1024 SVG holding one flat shape, with the tilt baked into
its coordinates. The backdrop is the document's background fill, not a layer.

    python3 make_icons.py
"""

import base64
import json
import math
from pathlib import Path

SIZE = 1024
HERE = Path(__file__).resolve().parent

# The cards and the backdrop, shared by every scene: (default, dark).
FRAME_COLOURS = {
    "backdrop": ("#22211F", "#0E0E0D"),
    "back": ("#CFCAC1", "#7E7A73"),
    # Kept below pure white, so the light in the photograph is the only white.
    "card": ("#EEEBE4", "#D9D6CF"),
}
WARM_LIGHT = ("#FFF6E6", "#FFF6E6")


# Geometry ------------------------------------------------------------------

def rotate(x, y, angle, pivot):
    a = math.radians(angle)
    dx, dy = x - pivot[0], y - pivot[1]
    return (pivot[0] + dx * math.cos(a) - dy * math.sin(a),
            pivot[1] + dx * math.sin(a) + dy * math.cos(a))


def placement(ox, oy, scale, angle, pivot):
    """Maps local (u, v) to the canvas: scale, offset, then turn about pivot."""
    return lambda u, v: rotate(ox + u * scale, oy + v * scale, angle, pivot)


def rrect(x, y, w, h, r):
    if r == 0:
        return poly([(x, y), (x + w, y), (x + w, y + h), (x, y + h)])
    return [("M", x + r, y), ("L", x + w - r, y), ("A", r, 0, 1, x + w, y + r),
            ("L", x + w, y + h - r), ("A", r, 0, 1, x + w - r, y + h),
            ("L", x + r, y + h), ("A", r, 0, 1, x, y + h - r),
            ("L", x, y + r), ("A", r, 0, 1, x + r, y), ("Z",)]


def bar(cx, cy, w, h):
    return rrect(cx - w / 2, cy - h / 2, w, h, h / 2)


def poly(points):
    return ([("M", *points[0])] + [("L", *p) for p in points[1:]] + [("Z",)])


def circle(cx, cy, r):
    return [("M", cx - r, cy), ("A", r, 0, 1, cx + r, cy),
            ("A", r, 0, 1, cx - r, cy), ("Z",)]


def half_disc(cx, cy, r):
    """The upper half of a circle, flat side down: a sun on the horizon."""
    return [("M", cx - r, cy), ("A", r, 0, 1, cx + r, cy), ("Z",)]


def arc_flags(centre, start, end, through):
    """large-arc and sweep flags for the arc from start to end that passes
    through `through` (SVG's positive sweep turns clockwise on screen)."""
    angle = lambda p: math.atan2(p[1] - centre[1], p[0] - centre[0])
    a, b, m = angle(start), angle(end), angle(through)
    span = (b - a) % math.tau
    if (m - a) % math.tau < span:
        return int(span > math.pi), 1
    return int(math.tau - span > math.pi), 0


def crescent(c1, r1, c2, r2):
    """The part of circle (c1, r1) outside circle (c2, r2)."""
    dx, dy = c2[0] - c1[0], c2[1] - c1[1]
    d = math.hypot(dx, dy)
    a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
    h = math.sqrt(r1 * r1 - a * a)
    mx, my = c1[0] + a * dx / d, c1[1] + a * dy / d
    p = (mx + h * dy / d, my - h * dx / d)
    q = (mx - h * dy / d, my + h * dx / d)
    ux, uy = -dx / d, -dy / d
    outer = arc_flags(c1, p, q, (c1[0] + r1 * ux, c1[1] + r1 * uy))
    inner = arc_flags(c2, q, p, (c2[0] + r2 * ux, c2[1] + r2 * uy))
    return [("M", *p), ("A", r1, *outer, *q), ("A", r2, *inner, *p), ("Z",)]


def path_data(subpaths, place, scale):
    d = []
    for op in subpaths:
        if op[0] == "Z":
            d.append("Z")
        elif op[0] == "A":
            _, r, large, sweep, u, v = op
            x, y = place(u, v)
            d.append(f"A{r * scale:.2f} {r * scale:.2f} 0 {large} {sweep} "
                     f"{x:.2f} {y:.2f}")
        else:
            x, y = place(op[1], op[2])
            d.append(f"{op[0]}{x:.2f} {y:.2f}")
    return " ".join(d)


# Scenes, in the photograph's unit square -------------------------------------
# Each layer: (name, subpaths, (default colour, dark colour)), back to front.

def sunset():
    return [
        ("sky", rrect(0, 0, 1, 1, 0.008), ("#1A1714", "#0C0B0A")),
        ("sea", poly([(0, 0.62), (1, 0.62), (1, 1), (0, 1)]),
         ("#2C2925", "#1C1A18")),
        ("sun", half_disc(0.5, 0.62, 0.2), WARM_LIGHT),
        ("glint", bar(0.5, 0.72, 0.30, 0.036) + bar(0.5, 0.81, 0.19, 0.036)
         + bar(0.5, 0.90, 0.09, 0.036), ("#BFB4A3", "#8F877A")),
    ]


def mountains():
    return [
        ("sky", rrect(0, 0, 1, 1, 0.008), ("#383A3E", "#2A2C30")),
        ("sun", circle(0.72, 0.28, 0.095), ("#FFFFFF", "#FFFFFF")),
        ("far-ridge", poly([(0.26, 1), (0.66, 0.46), (1, 0.8), (1, 1)]),
         ("#232427", "#18191B")),
        ("near-ridge", poly([(0, 1), (0, 0.68), (0.32, 0.5), (0.74, 1)]),
         ("#0D0D0E", "#0A0A0B")),
    ]


def moon():
    return [
        ("sky", rrect(0, 0, 1, 1, 0.008), ("#13161A", "#0B0D10")),
        ("water", poly([(0, 0.7), (1, 0.7), (1, 1), (0, 1)]),
         ("#1E2228", "#14171B")),
        ("moon", crescent((0.6, 0.36), 0.16, (0.67, 0.30), 0.14),
         ("#F4F6F8", "#F4F6F8")),
        ("glint", bar(0.6, 0.78, 0.16, 0.034) + bar(0.6, 0.86, 0.10, 0.034)
         + bar(0.6, 0.94, 0.05, 0.034), ("#9AA1AB", "#6C727A")),
    ]


def window():
    x, y, w, h, gap = 0.3, 0.14, 0.4, 0.48, 0.036
    pw, ph = (w - gap) / 2, (h - gap) / 2
    panes = []
    for col in range(2):
        for row in range(2):
            panes += rrect(x + col * (pw + gap), y + row * (ph + gap), pw, ph, 0)
    return [
        ("room", rrect(0, 0, 1, 1, 0.008), ("#171614", "#0C0B0A")),
        ("floor-light", poly([(0.18, 1), (0.36, 0.8), (0.64, 0.8), (0.82, 1)]),
         ("#3B3832", "#26241F")),
        ("window", panes, WARM_LIGHT),
    ]


SCENES = {"s1-sunset": ("S1 日落", sunset), "s2-mountains": ("S2 山与日", mountains),
          "s3-moon": ("S3 月夜", moon), "s4-window": ("S4 窗光", window)}


# The stacked prints ------------------------------------------------------------

def stacked(scene, x=212, y=190, w=568, angle=-3, back=(34, -34, 7)):
    """Two prints in square-format proportions (a 72 x 86 card holding a
    62 x 62 image, 5 at the sides, 6.5 at the top): a plain one behind, turned
    by back[2] degrees, and the photograph in front, turned by `angle`."""
    k = w / 72
    h = 86 * k
    pivot = (x + w / 2, y + h / 2)
    bx, by = x + back[0], y + back[1]
    flat = lambda angle_, pivot_: placement(0, 0, 1, angle_, pivot_)
    layers = [
        ("back", path_data(rrect(bx, by, w, h, 16), flat(back[2], (bx + w / 2, by + h / 2)), 1),
         FRAME_COLOURS["back"]),
        ("card", path_data(rrect(x, y, w, h, 16), flat(angle, pivot), 1),
         FRAME_COLOURS["card"]),
    ]
    size = 62 * k
    place = placement(x + 5 * k, y + 6.5 * k, size, angle, pivot)
    for name, subpaths, colours in scene():
        layers.append((name, path_data(subpaths, place, size), colours))
    return layers


# Output ------------------------------------------------------------------------

def document(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" '
            f'height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">\n{body}\n</svg>\n')


def composite(layers, dark):
    """A preview with an approximate system mask and a stand-in for the
    shadow Icon Composer adds to the cards."""
    rx = round(SIZE * 0.2237)
    defs = ('<defs><clipPath id="m"><rect width="1024" height="1024" '
            f'rx="{rx}"/></clipPath><filter id="s" x="-20%" y="-20%" '
            'width="140%" height="140%"><feDropShadow dx="0" dy="18" '
            'stdDeviation="22" flood-color="#000" flood-opacity="0.35"/>'
            '</filter></defs>\n')
    parts = []
    for name, d, colours in layers:
        shadow = ' filter="url(#s)"' if name in ("back", "card") else ""
        parts.append(f'<path d="{d}" fill="{colours[dark]}"{shadow}/>')
    backdrop = FRAME_COLOURS["backdrop"][dark]
    return document(defs + '<g clip-path="url(#m)">\n'
                    f'<rect width="1024" height="1024" fill="{backdrop}"/>\n'
                    + "\n".join(parts) + "\n</g>")


LIGHTS = {"sun", "moon", "window", "glint"}
PRINTS = {"back", "card"}


def colour(hex_colour):
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def icon_json(layers):
    """An Icon Composer document: the light in front with glass and specular,
    the matte photograph behind it, the two prints at the back with a shadow.
    Groups and layers are listed front to back, as the sidebar shows them."""
    def entry(name, colours):
        return {"name": name, "image-name": f"{name}.svg", "glass": name in LIGHTS,
                "fill-specializations": [
                    {"appearance": "dark", "value": {"solid": colour(colours[1])}}]}

    def group(names, **style):
        members = [entry(n, c) for n, _, c in reversed(layers) if n in names]
        return {"layers": members, **style}

    photo = {n for n, _, _ in layers} - LIGHTS - PRINTS
    backdrop = FRAME_COLOURS["backdrop"]
    return {
        "fill-specializations": [
            {"value": {"solid": colour(backdrop[0])}},
            {"appearance": "dark", "value": {"solid": colour(backdrop[1])}}],
        "groups": [
            group(LIGHTS, specular=True, shadow={"kind": "neutral", "opacity": 0.3}),
            group(photo, specular=False, translucency={"enabled": False, "value": 0}),
            group(PRINTS, specular=True, shadow={"kind": "neutral", "opacity": 0.5},
                  translucency={"enabled": False, "value": 0}),
        ],
        "supported-platforms": {"squares": "shared"},
    }


def write_icon(folder, layers):
    bundle = folder / "HyperDR.icon"
    assets = bundle / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for stale in assets.glob("*.svg"):
        stale.unlink()
    for name, d, colours in layers:
        (assets / f"{name}.svg").write_text(
            document(f'<path d="{d}" fill="{colours[0]}"/>'))
    (bundle / "icon.json").write_text(
        json.dumps(icon_json(layers), indent=2) + "\n")


def main():
    icons = {}
    for key, (label, scene) in SCENES.items():
        layers = stacked(scene)
        folder = HERE / key / "layers"
        folder.mkdir(parents=True, exist_ok=True)
        for stale in folder.glob("*.svg"):
            stale.unlink()
        for index, (name, d, colours) in enumerate(layers, 1):
            (folder / f"{index}-{name}.svg").write_text(
                document(f'<path d="{d}" fill="{colours[0]}"/>'))
        write_icon(HERE / key, layers)
        icons[key] = {}
        for dark, appearance in enumerate(("light", "dark")):
            svg = composite(layers, dark)
            (HERE / key / f"preview-{appearance}.svg").write_text(svg)
            icons[key][appearance] = ("data:image/svg+xml;base64,"
                                      + base64.b64encode(svg.encode()).decode())
    labels = {key: label for key, (label, _) in SCENES.items()}
    template = (HERE / "preview.template.html").read_text()
    (HERE / "preview.html").write_text(
        template.replace("/*ICONS*/null", json.dumps(icons))
        .replace("/*LABELS*/null", json.dumps(labels, ensure_ascii=False)))
    print("wrote", ", ".join(SCENES), "and preview.html")


if __name__ == "__main__":
    main()
