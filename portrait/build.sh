#!/usr/bin/env bash
# Build the portrait pose sheet: render the head across a yaw x pitch grid, then
# montage every pose into ONE sprite sheet (atlas/sheet.png) -- a yaw_steps-wide,
# pitch_steps-tall grid of SIZE x SIZE cells. The runtime (baseline/portrait.lua)
# transmits that single sheet once and crops a cell per frame, so the grid layout
# MUST match: column = yaw index, row = pitch index, no spacing. yaw_steps/
# pitch_steps and the angle() formula must match portrait.lua / build.sh too.
#
#   ./build.sh [obj] [size]
set -euo pipefail
cd "$(dirname "$0")"

OBJ="${1:-suzanne.obj}"
SIZE="${2:-320}"

YAW_STEPS=15
PITCH_STEPS=9
MAX_YAW=35
MAX_PITCH=25

mkdir -p atlas
rm -f atlas/pose_*.png

# angle(i, steps, max) = (i/(steps-1)*2 - 1) * max   -- matches portrait.lua
angle() { awk -v i="$1" -v steps="$2" -v max="$3" 'BEGIN{printf "%.4f",(i/(steps-1)*2-1)*max}'; }

count=0
for ((yi=0; yi<YAW_STEPS; yi++)); do
  yaw=$(angle "$yi" "$YAW_STEPS" "$MAX_YAW")
  for ((pi=0; pi<PITCH_STEPS; pi++)); do
    pitch=$(angle "$pi" "$PITCH_STEPS" "$MAX_PITCH")
    ppm="$(mktemp --suffix=.ppm)"
    nvim -l render.lua "$OBJ" "$ppm" "$SIZE" "$yaw" "$pitch" >/dev/null 2>&1
    # Key the pure-black background out to alpha so only the model shows; the
    # model's darkest shade is deep indigo, never pure black, so this is clean.
    magick "$ppm" -transparent '#000000' "atlas/pose_${yi}_${pi}.png"
    rm -f "$ppm"
    count=$((count+1))
  done
done
echo "built $count poses -> atlas/ (size ${SIZE})"

# Montage every pose into one sprite sheet. The runtime crops cells by (yaw,pitch)
# index, so the order MUST be row-major with pitch as the row and yaw as the column:
# pi outer (rows), yi inner (columns). -geometry +0+0 packs the SIZE x SIZE tiles
# with zero spacing so cell (yi,pi) sits at exactly (yi*SIZE, pi*SIZE); -background
# none keeps the keyed-out background transparent.
tiles=()
for ((pi=0; pi<PITCH_STEPS; pi++)); do
  for ((yi=0; yi<YAW_STEPS; yi++)); do
    tiles+=("atlas/pose_${yi}_${pi}.png")
  done
done
magick montage "${tiles[@]}" -tile "${YAW_STEPS}x${PITCH_STEPS}" -geometry +0+0 \
  -background none "atlas/sheet.png"
echo "montaged -> atlas/sheet.png ($((YAW_STEPS*SIZE))x$((PITCH_STEPS*SIZE)))"
