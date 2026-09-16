#!/usr/bin/env python3
"""Generate CrispTuner's app icon.

The icon used to be neon line art on a near-black ground, which is both the
most crowded look in the store and near-indistinguishable at a glance from the
other apps published from this account. This one is warm and material — a
brass tuning fork on aged paper, under a tuner's dial — so it reads as an
instrument tool rather than as generic tech, and does not collide with anything
else in the portfolio.

Two masters are produced:
  app_icon.png        1024px, full-bleed, fully opaque. iOS and Android apply
                      their own mask, and Apple rejects any alpha channel in
                      the marketing icon outright (ITMS-90717).
  app_icon_macos.png  1024px with the squircle baked in on a transparent
                      margin — macOS does not mask icons, so a full-bleed
                      square would ship with hard corners.
"""

import math
import subprocess
import sys
from pathlib import Path

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"

PAPER_TOP = "#FBF1DE"
PAPER_BOTTOM = "#E9D2A8"
BRASS_TOP = "#C89434"
BRASS_BOTTOM = "#8A5B16"
DIAL = "#2F6E6B"
IN_TUNE = "#2F7D4F"


def dial_ticks() -> str:
    """An arc of tick marks across the top, like a tuner's dial."""
    cx, cy, radius = 512.0, 1010.0, 726.0
    parts = []
    for i in range(-5, 6):
        angle = math.radians(i * 9.0)
        # Straight up is -90 degrees in SVG coordinates.
        dx, dy = math.sin(angle), -math.cos(angle)
        centre = i == 0
        length = 74.0 if centre else (52.0 if i % 5 == 0 else 34.0)
        width = 20.0 if centre else (13.0 if i % 5 == 0 else 9.0)
        colour = IN_TUNE if centre else DIAL
        opacity = 1.0 if centre else (0.75 if i % 5 == 0 else 0.45)
        x1, y1 = cx + dx * radius, cy + dy * radius
        x2, y2 = cx + dx * (radius - length), cy + dy * (radius - length)
        parts.append(
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{colour}" stroke-width="{width:.1f}" '
            f'stroke-linecap="round" opacity="{opacity}"/>'
        )
    return "\n    ".join(parts)


def artwork() -> str:
    return f"""
    {dial_ticks()}
    <!-- Tuning fork: a U of two tines over a stem. -->
    <g fill="none" stroke="url(#brass)" stroke-linecap="round"
       stroke-linejoin="round">
      <path stroke-width="74"
            d="M 392 352 L 392 578 Q 392 686 512 686 Q 632 686 632 578 L 632 352"/>
      <path stroke-width="74" d="M 512 686 L 512 852"/>
    </g>
    <!-- Highlight down the left tine, so the metal reads as metal. -->
    <path d="M 392 384 L 392 566" fill="none" stroke="#F2D48F"
          stroke-width="16" stroke-linecap="round" opacity="0.7"/>
"""


def svg(masked: bool) -> str:
    if masked:
        # macOS: squircle on a transparent margin.
        clip = ('<rect x="100" y="100" width="824" height="824" rx="185" '
                'ry="185"/>')
        background = ('<rect x="100" y="100" width="824" height="824" '
                      'rx="185" ry="185" fill="url(#paper)"/>')
    else:
        clip = f'<rect x="0" y="0" width="{SIZE}" height="{SIZE}"/>'
        background = f'<rect width="{SIZE}" height="{SIZE}" fill="url(#paper)"/>'

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}"
     height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <!-- userSpaceOnUse, not the objectBoundingBox default: the fork's stem
         is a perfectly vertical line, so its bounding box has zero width, and
         a bounding-box gradient on a zero-width box paints nothing at all.
         The stem simply vanished from the rendered icon. Absolute coordinates
         also keep one continuous ramp across both paths instead of restarting
         it per subpath. -->
    <linearGradient id="paper" gradientUnits="userSpaceOnUse"
                    x1="0" y1="0" x2="360" y2="1024">
      <stop offset="0" stop-color="{PAPER_TOP}"/>
      <stop offset="1" stop-color="{PAPER_BOTTOM}"/>
    </linearGradient>
    <linearGradient id="brass" gradientUnits="userSpaceOnUse"
                    x1="380" y1="330" x2="640" y2="890">
      <stop offset="0" stop-color="{BRASS_TOP}"/>
      <stop offset="1" stop-color="{BRASS_BOTTOM}"/>
    </linearGradient>
    <clipPath id="frame">{clip}</clipPath>
  </defs>
  {background}
  <g clip-path="url(#frame)">{artwork()}</g>
</svg>
"""


def render(name: str, masked: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    source = OUT / (name + ".svg")
    target = OUT / (name + ".png")
    source.write_text(svg(masked), encoding="utf-8")
    subprocess.run(
        ["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE),
         "-o", str(target), str(source)],
        check=True,
    )
    source.unlink()
    return target


def main() -> int:
    flat = render("app_icon", masked=False)
    macos = render("app_icon_macos", masked=True)

    from PIL import Image

    # The marketing icon must have no alpha at all, so flatten it explicitly
    # rather than trusting the renderer to have produced an opaque surface.
    image = Image.open(flat).convert("RGBA")
    flattened = Image.new("RGB", image.size, (251, 241, 222))
    flattened.paste(image, mask=image.split()[3])
    flattened.save(flat)

    for path in (flat, macos):
        with Image.open(path) as check:
            print(f"{path.name}: {check.size[0]}x{check.size[1]} {check.mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
