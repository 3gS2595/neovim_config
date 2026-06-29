#!/usr/bin/env bash
# High-quality portrait sheet builder -- the Blender counterpart to build.sh.
# Drives render_atlas.py (Cycles/EEVEE, real materials + reflections + alpha) to
# render every pose, then montages them into atlas/sheet.png with the SAME grid
# layout build.sh uses, so the runtime (baseline/portrait.lua) consumes it
# unchanged. build.sh / render.lua are left untouched: the pure-Lua CLI path
# still works exactly as before.
#
# Usage (same argument ORDER as build.sh):
#   ./build_blender.sh [options] <portrait.obj> [frame.obj]
#     portrait.obj  the head that turns to look at the mouse (rotates per cell)
#     frame.obj     OPTIONAL still background/border baked into every cell
#
# Options:
#   --size N        cell size in px (default 320)
#   --engine NAME   eevee (default, fast, screen-space reflections) | cycles
#                   (slower, true raytraced reflections + refraction)
#   --samples N     render samples (engine default if omitted)
#   --blender PATH  blender executable (default: blender on PATH, or $BLENDER)
#   --flip-yaw      flip horizontal turn direction (if a rebuild looks mirrored)
#   --flip-pitch    flip vertical turn direction
#
# Materials: Blender reads each OBJ's mtllib automatically -- full PBR, textures
# (map_Kd, normals), the lot. No --color flag: materials are always honored, and
# reflections come from the chosen engine. Drop the .mtl (and any textures) next
# to the .obj exactly as before.
set -euo pipefail
cd "$(dirname "$0")"

SIZE=320
ENGINE=eevee
SAMPLES=()
BLENDER="${BLENDER:-blender}"
FLIPS=()
POSITIONAL=()
while (($#)); do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --samples) SAMPLES=(--samples "$2"); shift 2 ;;
    --blender) BLENDER="$2"; shift 2 ;;
    --flip-yaw) FLIPS+=(--flip-yaw); shift ;;
    --flip-pitch) FLIPS+=(--flip-pitch); shift ;;
    -h | --help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

PORTRAIT="${POSITIONAL[0]:-suzanne.obj}"
FRAME="${POSITIONAL[1]:-}"

if ! command -v "$BLENDER" >/dev/null 2>&1; then
  echo "blender not found ('$BLENDER'). Install it or pass --blender <path> / set \$BLENDER." >&2
  exit 1
fi

# Grid -- MUST match render_atlas.py / build.sh / portrait.lua.
YAW_STEPS=15
PITCH_STEPS=9

mkdir -p atlas
rm -f atlas/pose_*.png

frame_args=()
if [[ -n "$FRAME" ]]; then
  frame_args=(--frame "$FRAME")
fi

# Render every pose head-less. render_atlas.py writes atlas/pose_<yi>_<pi>.png
# with true alpha, so no black-keying is needed downstream.
"$BLENDER" --background --python render_atlas.py -- \
  --portrait "$PORTRAIT" "${frame_args[@]}" \
  --outdir atlas --size "$SIZE" --engine "$ENGINE" \
  "${SAMPLES[@]}" "${FLIPS[@]}"

# Montage into the single sheet -- identical layout to build.sh: row-major with
# pitch as the row and yaw as the column, zero spacing, transparent background.
tiles=()
for ((pi = 0; pi < PITCH_STEPS; pi++)); do
  for ((yi = 0; yi < YAW_STEPS; yi++)); do
    tiles+=("atlas/pose_${yi}_${pi}.png")
  done
done
magick montage "${tiles[@]}" -tile "${YAW_STEPS}x${PITCH_STEPS}" -geometry +0+0 \
  -background none "atlas/sheet.png"
echo "montaged -> atlas/sheet.png ($((YAW_STEPS * SIZE))x$((PITCH_STEPS * SIZE))) [$ENGINE]"
