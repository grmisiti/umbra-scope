#!/usr/bin/env python3
"""Generates the README banner (docs/brand/banner.svg + banner.png) from the UMBRA brand assets.

Usage: tools/make_brand_assets.py [path to "UMBRA BRAND"]   (default: ~/Claude/UMBRA-MOTION/assets/UMBRA BRAND)
Text is converted to outlines with the Aburo font, so the SVG renders the same everywhere (GitHub has no custom fonts).
Colours and rules come from the brand book: carvao #302F2B, gelo #E6E6E6, roxo #8A2BE2; ghost tone-on-tone as texture.
"""
import os, re, subprocess, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

BRAND = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Claude/UMBRA-MOTION/assets/UMBRA BRAND")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "brand")
W, H = 1600, 520
BG, ICE, PUR, TONE = "#302F2B", "#E6E6E6", "#8A2BE2", "#262520"

def text_path(font_file, text, size, x, y, tracking=0, anchor="start"):
    """Outline of `text` with its baseline at y; anchor 'end' right-aligns at x."""
    f = TTFont(os.path.join(BRAND, "LOGO", "Aburo", font_file))
    gs, cm, upm = f.getGlyphSet(), f.getBestCmap(), f["head"].unitsPerEm
    s = size / upm
    names = [cm[ord(c)] for c in text]
    adv = [gs[n].width * s + tracking for n in names]
    total = sum(adv) - tracking
    cx = x - total if anchor == "end" else x
    pen = SVGPathPen(gs)
    for n, a in zip(names, adv):
        gs[n].draw(TransformPen(pen, (s, 0, 0, -s, cx, y)))
        cx += a
    return pen.getCommands(), total

def inner_paths(svg_file):
    src = open(svg_file, encoding="utf-8").read()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', src).group(1).split()]
    return " ".join(re.findall(r'\sd="([^"]+)"', src)), vb

ghost_d, gvb = inner_paths(os.path.join(BRAND, "brandbook/assets/img/ghost.svg"))
mark_d, mvb = inner_paths(os.path.join(BRAND, "brandbook/assets/img/umbra.svg"))

# wordmark UMBRA: 90 px high, top-left on the 80 px margin; SCOPE underneath, right-aligned to the wordmark.
mh = 90.0; ms = mh / mvb[3]; mw = mvb[2] * ms
mx, my = 80, 78
scope_d, _ = text_path("Aburo-Bold.otf", "SCOPE", 64, mx + mw, my + mh + 20 + 64 * 0.7, tracking=1.5, anchor="end")
tag_d, _ = text_path("Aburo-Light.otf", "WAVEFORM · VECTORSCOPE · FALSE COLOR", 15, mx, H - 64, tracking=1.6)
tag2_d, _ = text_path("Aburo-Light.otf", "MACOS · METAL · DAVINCI RESOLVE", 15, mx, H - 40, tracking=1.6)

gh = 760.0; gs_ = gh / gvb[3]
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <clipPath id="frame"><rect width="{W}" height="{H}"/></clipPath>
  </defs>
  <g clip-path="url(#frame)">
    <rect width="{W}" height="{H}" fill="{BG}"/>
    <g transform="translate({W - 640} {-100}) scale({gs_})" fill="{TONE}"><path d="{ghost_d}"/></g>
    <g transform="translate({mx} {my}) scale({ms})" fill="{ICE}"><path d="{mark_d}"/></g>
    <path d="{scope_d}" fill="{PUR}"/>
    <path d="{tag_d}" fill="{ICE}" opacity="0.8"/>
    <path d="{tag2_d}" fill="{ICE}" opacity="0.8"/>
  </g>
</svg>
'''
os.makedirs(OUT, exist_ok=True)
svg_path = os.path.join(OUT, "banner.svg")
open(svg_path, "w", encoding="utf-8").write(svg)
print("wrote", svg_path)

# PNG: ImageMagick rasterises the SVG, then film grain (brand rule: "grão de filme sempre ativo") is added with numpy.
import numpy as np
from PIL import Image
tmp = os.path.join(OUT, "_banner_raw.png")
subprocess.run(["magick", "-background", BG, "-density", "96", svg_path, tmp], check=True)
img = np.asarray(Image.open(tmp).convert("RGB"), dtype=np.float32)
rng = np.random.default_rng(7)
img += rng.normal(0, 5.0, img.shape[:2])[..., None]          # mono grain, sigma ~5/255
Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(os.path.join(OUT, "banner.png"), optimize=True)
os.remove(tmp)
print("wrote", os.path.join(OUT, "banner.png"))

# App top bar: the same UMBRA / SCOPE lockup as the banner, on transparent, trimmed (Resources/wordmark.png).
lock_scope_d, _ = text_path("Aburo-Bold.otf", "SCOPE", 64, mw, mh + 20 + 64 * 0.7, tracking=1.5, anchor="end")
lock_h = mh + 20 + 64 * 0.7 + 4
lock_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{mw:.0f}" height="{lock_h:.0f}" viewBox="0 0 {mw} {lock_h}">
  <g transform="scale({ms})" fill="{ICE}"><path d="{mark_d}"/></g>
  <path d="{lock_scope_d}" fill="{PUR}"/>
</svg>
'''
lock_svg_path = os.path.join(OUT, "wordmark.svg")
open(lock_svg_path, "w", encoding="utf-8").write(lock_svg)
lock_png = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "wordmark.png")
subprocess.run(["magick", "-background", "none", "-density", "144", lock_svg_path, "-trim", "+repage", lock_png], check=True)
print("wrote", lock_svg_path, "and", lock_png)
