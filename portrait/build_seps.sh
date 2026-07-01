#!/usr/bin/env bash
# Build the SEPARATOR tiles: render the tube + junction models once and crop them
# into 1-cell tiles for the 3D heart-frame separators (the replacement for the glyph
# floats in lua/baseline/banners.lua and the box-drawing in lua/baseline/panetabs.lua).
#
# There is NO yaw/pitch pose grid here -- separators are static. Everything is rendered
# side-on (yaw 0, pitch 0) with the SAME render.lua rasterizer + celestial ramp as the
# portrait, the black background keyed to alpha, then cropped per piece.
#
# Pieces (all share the tube's radius-1 cross-section, so their stubs kiss the runs):
#   tube.obj       straight tube, Y = length            -> tube_v.png / tube_h.png
#   90_corner.obj  90 deg elbow, connects RIGHT + DOWN   -> corner_{0,90,180,270}.png
#   T_corner.obj   tee, connects LEFT + RIGHT + DOWN     -> tee_{0,90,180,270}.png
#
# JOINT-CELL CROP. A junction model's arms run several units past the bend so they can
# be modelled cleanly, but a TILE is one cell. The bend lives in the 2x2-unit "joint
# cell" world X in [-1,1], Y in [-2,0]: the down-stub centered on x=0, the horizontal
# arm one radius below the top (centerline y=-1). We crop exactly that square (NO trim)
# so each stub reaches the tile edge at full tube width and meets a straight run with no
# seam. Authoring a new junction MUST follow that convention (radius 1, that joint cell).
#
# Rotations 0/90/180/270 are baked here with magick, so each junction is modelled ONCE:
#   corner_0 = TL (right+down), 90 = TR, 180 = BR, 270 = BL.
#   tee_0    = down-tee, 90/180/270 = the other three.
#
# Usage:  ./build_seps.sh [--size N]
set -euo pipefail
cd "$(dirname "$0")"

SIZE=320
# Terminal cells are ~ASPECT:1 (tall:wide). A horizontal tube placed 1 row tall would
# otherwise render ~ASPECT x thicker than a vertical tube placed 1 col wide; we pad the
# horizontal tube vertically by ASPECT so its on-screen thickness matches the vertical.
ASPECT=2
while (($#)); do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    --aspect) ASPECT="$2"; shift 2 ;;
    -h | --help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p seps

# Render a model side-on to a black-keyed PNG (no crop yet). $1=obj $2=out.png
render_keyed() {
  local ppm
  ppm="$(mktemp --suffix=.ppm)"
  nvim -l render.lua --portrait "$1" --out "$ppm" --size "$SIZE" --yaw 0 --pitch 0 >/dev/null 2>&1
  magick "$ppm" -transparent '#000000' "$2"
  rm -f "$ppm"
}

# Print the joint-cell crop geometry ("WxH+X+Y") for an OBJ, mirroring render.lua's
# no-frame normalization (fit 1.7, bbox-centered) so the pixel box matches the render.
joint_crop() {
  python3 - "$1" "$SIZE" <<'PY'
import sys
obj, size = sys.argv[1], int(sys.argv[2])
mn=[1e9]*3; mx=[-1e9]*3
for line in open(obj):
    if line.startswith('v '):
        p=line.split()
        for i in range(3):
            v=float(p[i+1]); mn[i]=min(mn[i],v); mx[i]=max(mx[i],v)
c=[(mn[i]+mx[i])/2 for i in range(3)]
ext=max(mx[0]-mn[0], mx[1]-mn[1], mx[2]-mn[2], 1e-6)
s=1.7/ext; W=H=size
px=lambda x:( (x-c[0])*s + 1)/2*(W-1)
py=lambda y:(1-((y-c[1])*s + 1)/2)*(H-1)
# joint cell: world X in [-1,1], Y in [-2,0]
xs=[px(-1), px(1)]; ys=[py(0), py(-2)]
X=round(min(xs)); Y=round(min(ys))
Wc=round(abs(xs[1]-xs[0])); Hc=round(abs(ys[1]-ys[0]))
print(f"{Wc}x{Hc}+{X}+{Y}")
PY
}

# Tube: render, crop the uniform middle (drop the rounded rims), trim to a tight tile.
render_keyed ../tube.obj seps/_tube_full.png
magick seps/_tube_full.png -gravity center -crop 100x60%+0+0 +repage -trim +repage seps/tube_v.png
# Horizontal tube = vertical rotated, then padded vertically by ASPECT (tube centered,
# transparent above/below) so that after the 1-row cell squish it reads at the SAME
# on-screen thickness as the 1-col vertical tube instead of ~ASPECT x thicker.
magick seps/tube_v.png -rotate 90 seps/_tube_h.png
hdims=$(magick identify -format '%w %h' seps/_tube_h.png)
hw=${hdims% *}; hh=${hdims#* }
newh=$(python3 -c "print(round($hh*$ASPECT))")
magick seps/_tube_h.png -background none -gravity center -extent "${hw}x${newh}" seps/tube_h.png
rm -f seps/_tube_full.png seps/_tube_h.png

# Junctions: render, crop the joint cell (NO trim -- the crop edges ARE the cell edges),
# then bake the 0/90/180/270 rotations.
build_junction() {
  local obj="$1" name="$2" full crop
  full="$(mktemp --suffix=.png)"
  render_keyed "$obj" "$full"
  crop="$(joint_crop "$obj")"
  magick "$full" -crop "$crop" +repage "seps/${name}_0.png"
  magick "seps/${name}_0.png" -rotate 90  "seps/${name}_90.png"
  magick "seps/${name}_0.png" -rotate 180 "seps/${name}_180.png"
  magick "seps/${name}_0.png" -rotate 270 "seps/${name}_270.png"
  rm -f "$full"
}

build_junction ../90_corner.obj corner
build_junction ../T_corner.obj  tee

echo "built seps/:"
for f in seps/tube_v.png seps/tube_h.png seps/corner_0.png seps/tee_0.png; do
  printf '  %-22s %s\n' "$(basename "$f")" "$(magick identify -format '%wx%h' "$f")"
done
