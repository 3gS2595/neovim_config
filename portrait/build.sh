#!/usr/bin/env bash
# Build the portrait pose atlas: render the head across a yaw x pitch grid into
# atlas/pose_<yi>_<pi>.png. The grid + angle formula MUST match
# baseline/portrait.lua (yaw_steps/pitch_steps/max_yaw/max_pitch and angle()).
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
    magick "$ppm" "atlas/pose_${yi}_${pi}.png"
    rm -f "$ppm"
    count=$((count+1))
  done
done
echo "built $count poses -> atlas/ (size ${SIZE})"
