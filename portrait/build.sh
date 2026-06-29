#!/usr/bin/env bash
# Build the portrait pose sheet: render the head across a yaw x pitch grid, then
# montage every pose into ONE sprite sheet (atlas/sheet.png) -- a yaw_steps-wide,
# pitch_steps-tall grid of SIZE x SIZE cells. The runtime (baseline/portrait.lua)
# transmits that single sheet once and crops a cell per frame, so the grid layout
# MUST match: column = yaw index, row = pitch index, no spacing. yaw_steps/
# pitch_steps and the angle() formula must match portrait.lua / render.lua too.
#
# Two models, decided by ORDER:
#   ./build.sh [options] <portrait.obj> [frame.obj]
#     portrait.obj  the head that turns to look at the mouse (rotates per cell)
#     frame.obj     OPTIONAL still background/border (baked identically into every
#                   cell, so it never moves). Omit it to build the head alone.
#
# Options:
#   --size N    cell size in px (default 320)
#   --color     shade any model that ships an .mtl from its material diffuse (Kd);
#               models without materials keep the celestial ramp either way
#
# Sizing: with NO frame the head auto-fits the square (input size doesn't matter).
# With a frame, the FRAME fills the square (it's the camera view) and the portrait
# keeps its size/placement RELATIVE to the frame -- so size the head centred in the
# frame, and a head larger than the frame deliberately spills off-screen.
set -euo pipefail
cd "$(dirname "$0")"

SIZE=320
COLOR=""
POSITIONAL=()
while (($#)); do
  case "$1" in
    --size)
      SIZE="$2"
      shift 2
      ;;
    --color)
      COLOR="--color"
      shift
      ;;
    -h | --help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

PORTRAIT="${POSITIONAL[0]:-suzanne.obj}"
FRAME="${POSITIONAL[1]:-}"

YAW_STEPS=15
PITCH_STEPS=9
MAX_YAW=35
MAX_PITCH=25

mkdir -p atlas
rm -f atlas/pose_*.png

# angle(i, steps, max) = (i/(steps-1)*2 - 1) * max   -- matches portrait.lua
angle() { awk -v i="$1" -v steps="$2" -v max="$3" 'BEGIN{printf "%.4f",(i/(steps-1)*2-1)*max}'; }

# Common render.lua flags shared by every cell (the frame flag is added only when
# a frame OBJ was supplied).
frame_args=()
if [[ -n "$FRAME" ]]; then
  frame_args=(--frame "$FRAME")
fi

count=0
for ((yi = 0; yi < YAW_STEPS; yi++)); do
  yaw=$(angle "$yi" "$YAW_STEPS" "$MAX_YAW")
  for ((pi = 0; pi < PITCH_STEPS; pi++)); do
    pitch=$(angle "$pi" "$PITCH_STEPS" "$MAX_PITCH")
    ppm="$(mktemp --suffix=.ppm)"
    nvim -l render.lua --portrait "$PORTRAIT" "${frame_args[@]}" \
      --out "$ppm" --size "$SIZE" --yaw "$yaw" --pitch "$pitch" $COLOR >/dev/null 2>&1
    # Key the pure-black background out to alpha so only the models show; render.lua
    # guarantees covered pixels are never pure black, so this is a clean cut.
    magick "$ppm" -transparent '#000000' "atlas/pose_${yi}_${pi}.png"
    rm -f "$ppm"
    count=$((count + 1))
  done
done
echo "built $count poses -> atlas/ (size ${SIZE})"

# Montage every pose into one sprite sheet. The runtime crops cells by (yaw,pitch)
# index, so the order MUST be row-major with pitch as the row and yaw as the column:
# pi outer (rows), yi inner (columns). -geometry +0+0 packs the SIZE x SIZE tiles
# with zero spacing so cell (yi,pi) sits at exactly (yi*SIZE, pi*SIZE); -background
# none keeps the keyed-out background transparent.
tiles=()
for ((pi = 0; pi < PITCH_STEPS; pi++)); do
  for ((yi = 0; yi < YAW_STEPS; yi++)); do
    tiles+=("atlas/pose_${yi}_${pi}.png")
  done
done
magick montage "${tiles[@]}" -tile "${YAW_STEPS}x${PITCH_STEPS}" -geometry +0+0 \
  -background none "atlas/sheet.png"
echo "montaged -> atlas/sheet.png ($((YAW_STEPS * SIZE))x$((PITCH_STEPS * SIZE)))"
