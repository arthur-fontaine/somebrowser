"""Generates the app icon, `Defaults/Assets/AppIcon.icon` (an Icon Composer document).

A spaceship porthole onto a moonrise in Netscape's colours: a teal hull, a silver ring with rivets, a teal sky
brightening toward the horizon, Netscape's dark planet with a lit rim, and the Moon's real maria. Every shape is
computed here (no clip paths: Apple's icon renderer ignores them), so edit this file and rerun it rather than editing
the SVGs by hand. Open the result in Icon Composer to preview it in every appearance.

    python3 Tools/icon/porthole.py [output.icon]
"""
import json, math, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Defaults", "Assets", "AppIcon.icon")
CX = CY = 512                      # canvas centre; Icon Composer's canvas is 1024², masked to the squircle

HULL = ["#46D6DB", "#14909E"]
RING, RIVETS = ["#FBFDFD", "#AEBDC2"], "#8A9CA2"
SKY = ["#1D7590", "#56D0D8"]       # lighter toward the horizon, as in Netscape's sky
PLANET, LIMB = ["#0B2A33", "#020A0D"], "#B5F6F8"
MARIA_FILL = "#A3C9CE"
WR, RO, N_RIVETS = 318, 414, 6     # window radius, ring outer radius

# The Moon's maria at their real selenographic positions: (lat, lon, radius°, vertical squash, outline seed).
MARIA = [(20, -56, 23, 1.3, 2.6),    # Oceanus Procellarum
         (33, -17, 19, 0.85, 0.3),   # Imbrium
         (6, -28, 10, 0.9, 1.9),     # Insularum
         (27, 17, 12.5, 1.0, 1.1),   # Serenitatis
         (8, 30, 14, 0.9, 2.0),      # Tranquillitatis
         (13, 4, 7.5, 1.0, 0.7),     # Vaporum
         (17, 58, 9.5, 0.85, 1.5),   # Crisium
         (56, -4, 15, 0.32, 1.7)]    # Frigoris

def path(pts):
    return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"

def circle(cx, cy, r):
    return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="#FFFFFF"/>'

# The scene was composed for a 390-radius window; everything scales with the window.
K = WR / 390
PY, PR = CY + 788 * K, 680 * K                   # planet
MCY, MR = CY - 12 * K, 200 * K                   # moon
STARS = [(CX + (x - 512) * K, CY + (y - 512) * K, r * max(K, 0.8))
         for x, y, r in [(330, 290, 8), (420, 200, 5), (690, 250, 7), (760, 380, 5), (270, 420, 5), (610, 175, 4)]]

def planet_y(x):
    return PY - math.sqrt(PR ** 2 - (x - CX) ** 2)

def chord(r, cy):
    """Where the circle (CX, cy, r) crosses the planet: half-width and y of the chord."""
    d = PY - cy
    a = (r * r - PR * PR + d * d) / (2 * d)
    return math.sqrt(r * r - a * a), cy + a

def planet_in_window():
    h, y = chord(WR, CY)
    return (f'M {CX - h:.2f} {y:.2f} A {PR} {PR} 0 0 1 {CX + h:.2f} {y:.2f} '
            f'A {WR} {WR} 0 {1 if y < CY else 0} 1 {CX - h:.2f} {y:.2f} Z')

def limb(w, n=600):
    """The planet's lit edge, a band of width w inside its limb, cut by the window."""
    h, _ = chord(WR, CY)
    xs = [CX - h + 2 * h * i / n for i in range(n + 1)]
    bottom = lambda x: CY + math.sqrt(max(WR ** 2 - (x - CX) ** 2, 0))
    return path([(x, planet_y(x)) for x in xs] + [(x, min(planet_y(x) + w, bottom(x))) for x in reversed(xs)])

def risen_moon():
    h, y = chord(MR, MCY)
    return (f'M {CX - h:.2f} {y:.2f} A {MR} {MR} 0 1 1 {CX + h:.2f} {y:.2f} '
            f'A {PR} {PR} 0 0 0 {CX - h:.2f} {y:.2f} Z')

def maria():
    def face(lat, lon):  # orthographic projection, pinned above the horizon
        la, lo = math.radians(lat), math.radians(lon)
        x, y = CX + MR * math.cos(la) * math.sin(lo), MCY - MR * math.sin(la)
        return x, min(y, planet_y(x) - 4)
    out = []
    for lat, lon, r, sq, sd in MARIA:
        pts = []
        for i in range(96):
            t = 2 * math.pi * i / 96
            wob = 1 + 0.09 * math.sin(3 * t + sd) + 0.05 * math.sin(5 * t + 2 * sd)
            pts.append(face(lat + sq * r * wob * math.sin(t), lon + r * wob * math.cos(t)))
        out.append(f'<path fill="#FFFFFF" d="{path(pts)}"/>')
    return "".join(out)

def ring(r_out, r_in):
    return (f'M {CX - r_out} {CY} A {r_out} {r_out} 0 1 0 {CX + r_out} {CY} A {r_out} {r_out} 0 1 0 {CX - r_out} {CY} Z '
            f'M {CX - r_in} {CY} A {r_in} {r_in} 0 1 1 {CX + r_in} {CY} A {r_in} {r_in} 0 1 1 {CX - r_in} {CY} Z')

def glare(r, off):
    """Crescent reflection on the pane: circle(r) minus the same circle shifted down-right by off."""
    h = math.sqrt(r * r - (off * math.sqrt(2) / 2) ** 2)
    mx, my = CX + off / 2, CY + off / 2
    u = 1 / math.sqrt(2)
    p1, p2 = (mx - u * h, my + u * h), (mx + u * h, my - u * h)
    return (f'M {p1[0]:.1f} {p1[1]:.1f} A {r} {r} 0 1 1 {p2[0]:.1f} {p2[1]:.1f} '
            f'A {r} {r} 0 0 0 {p1[0]:.1f} {p1[1]:.1f} Z')

def rivets():
    rb = (WR + RO) / 2
    return "".join(circle(CX + rb * math.cos(2 * math.pi * i / N_RIVETS + math.pi / N_RIVETS),
                          CY + rb * math.sin(2 * math.pi * i / N_RIVETS + math.pi / N_RIVETS), 18) for i in range(N_RIVETS))

def color(h):
    r, g, b = (int(h.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{1:.5f}"

def fill(v):
    return {"linear-gradient": [color(c) for c in v]} if isinstance(v, list) else {"solid": color(v)}

# Groups back to front (Icon Composer allows four). A layer: name, svg body, fill, opacity, glass, tinted fill.
GROUPS = [
    ("Space", dict(translucency=0.1, shadow=0.0, specular=False), [
        ("sky", circle(CX, CY, WR + 6), SKY, 1.0, False, "#A8A8A8"),
        ("stars", "".join(circle(*s) for s in STARS), "#FFFFFF", 0.85, False, None)]),
    ("Moon", dict(translucency=0.2, shadow=0.5, specular=True), [
        ("moon", f'<path fill="#FFFFFF" d="{risen_moon()}"/>', ["#FFFFFF", "#E2F4F5"], 0.97, True, None),
        ("maria", maria(), MARIA_FILL, 0.55, False, "#9A9A9A")]),
    ("Planet", dict(translucency=0.04, shadow=0.4, specular=True), [
        ("planet", f'<path fill="#FFFFFF" d="{planet_in_window()}"/>', PLANET, 1.0, True, "#141414"),
        ("limb", f'<path fill="#FFFFFF" d="{limb(18)}"/>', LIMB, 0.9, True, "#CFCFCF")]),
    ("Porthole", dict(translucency=0.1, shadow=0.7, specular=True), [
        ("pane", circle(CX, CY, WR + 4), "#FFFFFF", 0.1, True, None),
        ("glare", f'<path fill="#FFFFFF" d="{glare(WR - 18, 34)}"/>', "#FFFFFF", 0.22, False, None),
        ("frame", f'<path fill="#FFFFFF" fill-rule="evenodd" d="{ring(RO, WR)}"/>', RING, 1.0, True, "#E8E8E8"),
        ("rivets", rivets(), RIVETS, 1.0, True, "#B0B0B0")]),
]

def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, "Assets"))
    groups = []
    for name, g, layers in GROUPS:
        out_layers = []
        for lname, body, lfill, opacity, glass, tinted in layers:
            with open(os.path.join(OUT, "Assets", f"{lname}.svg"), "w") as f:
                f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>')
            specs = [{"value": fill(lfill)}] + ([{"appearance": "tinted", "value": fill(tinted)}] if tinted else [])
            out_layers.append({"image-name": f"{lname}.svg", "name": lname, "glass": glass, "opacity": opacity,
                               "fill-specializations": specs})
        groups.append({"name": name, "layers": out_layers[::-1], "lighting": "individual", "specular": g["specular"],
                       "shadow": {"kind": "neutral", "opacity": g["shadow"]},
                       "translucency": {"enabled": True, "value": g["translucency"]}})
    icon = {"groups": groups[::-1],  # icon.json lists front first
            "supported-platforms": {"squares": "shared"},
            "fill-specializations": [{"value": fill(HULL)}, {"appearance": "dark", "value": "system-dark"}]}
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2)
    print(OUT)

if __name__ == "__main__":
    main()
