#!/bin/bash
# Draws the macOS app icon set from full-bleed square artwork (1024x1024 or larger).
# macOS 15 and earlier draw an icon's PNG as it is, so the artwork goes on Apple's macOS grid: an 824x824 rounded
# rectangle centred in the 1024 canvas, with a transparent margin and a soft shadow (#398). macOS 26 accepts it too.
# Usage: Scripts/make-macos-icon.sh <artwork.png> [<appiconset dir>]   (needs ImageMagick 7: `magick`)
set -euo pipefail
source=${1:?artwork png}
target=${2:-Config/macOS/Assets.xcassets/AppIcon.appiconset}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
magick "$source" -alpha off -alpha set -resize 824x824! \
  \( -size 824x824 xc:none -fill white -draw "roundrectangle 0,0,823,823,185,185" \) \
  -compose DstIn -composite "$work/body.png"
magick -size 1024x1024 xc:none "$work/body.png" -geometry +100+100 -composite "$work/flat.png"
magick "$work/flat.png" -fill black -colorize 100 -channel A -evaluate multiply 0.3 +channel \
  -channel RGBA -blur 0x10 +channel "$work/shadow.png"
magick -size 1024x1024 xc:none "$work/shadow.png" -geometry +0+10 -composite "$work/flat.png" -composite "$work/icon.png"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    magick "$work/icon.png" -filter Lanczos -resize ${pixels}x${pixels} -strip "PNG32:$target/icon_${size}x${size}@${scale}x.png"
  done
done
echo "wrote $target"
