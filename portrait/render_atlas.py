# Blender pose renderer for the portrait pane -- the high-quality alternative to
# render.lua. Run head-less from build_blender.sh:
#
#   blender --background --python render_atlas.py -- \
#     --portrait <obj/blend object> [--frame <obj>] --outdir atlas \
#     [--size N] [--engine eevee|cycles] [--samples N]
#
# It renders the SAME 15 yaw x 9 pitch grid that build.sh/render.lua produce, one
# PNG per cell (atlas/pose_<yi>_<pi>.png), which build_blender.sh then montages
# into atlas/sheet.png. The runtime (baseline/portrait.lua) only consumes that
# finished sheet and derives the per-cell size from its pixel dimensions, so as
# long as the grid layout + pose angles match render.lua, anything goes here:
# Cycles/EEVEE reflections, textures, full PBR materials, real anti-aliasing and
# -- crucially -- TRUE ALPHA (film transparency), so unlike render.lua there is no
# black-keying and no near-black "punch a hole" hazard.
#
# CONTRACT this must keep identical to render.lua / build.sh, or the head will
# look the wrong way at runtime:
#   * grid: YAW_STEPS=15 columns, PITCH_STEPS=9 rows;
#   * angle(i, steps, max) = (i/(steps-1)*2 - 1) * max, MAX_YAW=35, MAX_PITCH=25;
#   * the PORTRAIT rotates about its own centroid (yaw about the up axis, then
#     pitch about the right axis); the FRAME, if given, stays static;
#   * +X is screen-right, +Y is screen-up, +Z is toward the camera.
# If a rebuilt head looks mirrored, flip YAW_SIGN / PITCH_SIGN below (or pass
# --flip-yaw / --flip-pitch) and re-render -- compare a couple of corner cells
# against the current atlas/sheet.png.

import sys
import os
import math

import bpy
import mathutils

# --- grid + angles: MUST match build.sh / render.lua / portrait.lua -----------
YAW_STEPS = 15
PITCH_STEPS = 9
MAX_YAW = 35.0
MAX_PITCH = 25.0

# Turn direction. render.lua rotates yaw about +Y and pitch about +X; if a rebuild
# comes out mirrored relative to the old sheet, flip the offending sign.
YAW_SIGN = 1.0
PITCH_SIGN = 1.0

# Light direction matching render.lua's upper-front-right key light (camera space:
# +x right, +y up, +z toward viewer). Used to aim the sun lamp.
LIGHT_DIR = (0.4, 0.5, 0.85)


def angle(i, steps, max_deg):
    # identical to build.sh's angle(): even spread across [-max, +max]
    return (i / (steps - 1) * 2.0 - 1.0) * max_deg


# --- arg parsing (everything after the lone "--") -----------------------------
def parse_args():
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    opt = {
        "portrait": None,
        "frame": None,
        "outdir": "atlas",
        "size": 320,
        "engine": "eevee",
        "samples": None,  # engine default if unset
        "flip_yaw": False,
        "flip_pitch": False,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--portrait":
            i += 1
            opt["portrait"] = argv[i]
        elif a == "--frame":
            i += 1
            opt["frame"] = argv[i]
        elif a == "--outdir":
            i += 1
            opt["outdir"] = argv[i]
        elif a == "--size":
            i += 1
            opt["size"] = int(argv[i])
        elif a == "--engine":
            i += 1
            opt["engine"] = argv[i].lower()
        elif a == "--samples":
            i += 1
            opt["samples"] = int(argv[i])
        elif a == "--flip-yaw":
            opt["flip_yaw"] = True
        elif a == "--flip-pitch":
            opt["flip_pitch"] = True
        else:
            raise SystemExit("render_atlas.py: unknown argument: " + a)
        i += 1
    if not opt["portrait"]:
        raise SystemExit("render_atlas.py: --portrait <obj> required")
    return opt


# --- engine selection: EEVEE id changed to *_NEXT in Blender 4.2 --------------
def select_engine(name, samples):
    scene = bpy.context.scene
    if name == "cycles":
        scene.render.engine = "CYCLES"
        # Use the GPU if one is configured; otherwise Cycles falls back to CPU.
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            prefs.get_devices()
            for dev in prefs.devices:
                dev.use = True
            scene.cycles.device = "GPU"
        except Exception:
            scene.cycles.device = "CPU"
        scene.cycles.samples = samples if samples else 128
        # Transparent film keeps the background clear (no black-key needed).
        scene.cycles.film_transparent = True
    elif name == "eevee":
        # Blender >= 4.2 renames the engine to EEVEE Next.
        eevee_id = "BLENDER_EEVEE_NEXT"
        try:
            scene.render.engine = eevee_id
        except TypeError:
            eevee_id = "BLENDER_EEVEE"
            scene.render.engine = eevee_id
        ee = scene.eevee
        if samples and hasattr(ee, "taa_render_samples"):
            ee.taa_render_samples = samples
        # Turn on reflections where the API exposes them (names differ by version).
        if hasattr(ee, "use_raytracing"):  # EEVEE Next
            ee.use_raytracing = True
        if hasattr(ee, "use_ssr"):  # legacy EEVEE screen-space reflections
            ee.use_ssr = True
            ee.use_ssr_refraction = True
    else:
        raise SystemExit("render_atlas.py: --engine must be 'eevee' or 'cycles'")
    scene.render.film_transparent = True
    return scene


# --- import helpers (new operator name landed in 3.3; keep a fallback) --------
def import_obj(path):
    before = set(bpy.data.objects)
    if hasattr(bpy.ops.wm, "obj_import"):
        # forward=-Y, up=Z tells the importer the file is already in Blender's
        # frame, so vertices are kept RAW (no axis remap) -- this preserves
        # render.lua's coords: +Y up, +Z toward viewer, +X right.
        bpy.ops.wm.obj_import(
            filepath=path, forward_axis="NEGATIVE_Y", up_axis="Z"
        )
    else:
        bpy.ops.import_scene.obj(
            filepath=path, axis_forward="-Y", axis_up="Z"
        )
    return [o for o in bpy.data.objects if o not in before and o.type == "MESH"]


def join_meshes(objs, name):
    if not objs:
        raise SystemExit("render_atlas.py: no mesh imported")
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    return obj


def world_bbox(obj):
    mn = mathutils.Vector((1e9, 1e9, 1e9))
    mx = mathutils.Vector((-1e9, -1e9, -1e9))
    for corner in obj.bound_box:
        p = obj.matrix_world @ mathutils.Vector(corner)
        for k in range(3):
            mn[k] = min(mn[k], p[k])
            mx[k] = max(mx[k], p[k])
    return mn, mx


# --- scene build --------------------------------------------------------------
def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
        for b in list(block):
            if b.users == 0:
                block.remove(b)


def main():
    opt = parse_args()
    if opt["flip_yaw"]:
        global YAW_SIGN
        YAW_SIGN = -YAW_SIGN
    if opt["flip_pitch"]:
        global PITCH_SIGN
        PITCH_SIGN = -PITCH_SIGN

    scene = select_engine(opt["engine"], opt["samples"])
    clear_scene()

    head = join_meshes(import_obj(opt["portrait"]), "portrait")
    frame = None
    if opt["frame"]:
        frame = join_meshes(import_obj(opt["frame"]), "frame")

    # Normalization basis mirrors render.lua: with a frame, the FRAME fills the
    # view (edge-to-edge, fit=2.0); without one, the head fits with a margin
    # (fit=1.7). We don't move geometry -- we just size the ortho camera to show
    # the basis bbox, so the head/frame layout authored in Blender is preserved.
    basis = frame if frame else head
    bmn, bmx = world_bbox(basis)
    center = (bmn + bmx) * 0.5
    ext = max(bmx[0] - bmn[0], bmx[1] - bmn[1], bmx[2] - bmn[2], 1e-6)
    fit = 2.0 if frame else 1.7
    # ortho_scale is the world width the camera shows; fit=2.0 => edge-to-edge.
    ortho_scale = ext * (2.0 / fit)

    # The head pivots about ITS OWN centroid so it turns in place.
    hmn, hmx = world_bbox(head)
    pivot = (hmn + hmx) * 0.5
    head_base = head.matrix_world.copy()

    # Orthographic camera on +Z looking toward -Z, up = +Y (render.lua's view).
    cam_data = bpy.data.cameras.new("portrait_cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho_scale
    cam = bpy.data.objects.new("portrait_cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (center[0], center[1], center[2] + ext * 10.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)  # looks down -Z, +Y up
    scene.camera = cam

    # Key light from render.lua's direction; a dim world fills shadows and gives
    # reflective materials something to catch.
    sun_data = bpy.data.lights.new("key", type="SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("key", sun_data)
    bpy.context.collection.objects.link(sun)
    ld = mathutils.Vector(LIGHT_DIR).normalized()
    # Point the sun so it shines along -LIGHT_DIR (lamp -Z is its beam).
    sun.rotation_euler = ld.to_track_quat("Z", "Y").to_euler()
    world = bpy.data.worlds.new("portrait_world")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.05, 0.04, 0.09, 1.0)
        bg.inputs[1].default_value = 0.6
    scene.world = world

    scene.render.resolution_x = opt["size"]
    scene.render.resolution_y = opt["size"]
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"

    outdir = opt["outdir"]
    os.makedirs(outdir, exist_ok=True)

    count = 0
    for yi in range(YAW_STEPS):
        yaw = math.radians(angle(yi, YAW_STEPS, MAX_YAW) * YAW_SIGN)
        ry = mathutils.Matrix.Rotation(yaw, 4, "Y")
        for pi in range(PITCH_STEPS):
            pitch = math.radians(angle(pi, PITCH_STEPS, MAX_PITCH) * PITCH_SIGN)
            rx = mathutils.Matrix.Rotation(pitch, 4, "X")
            # render.lua applies yaw then pitch about the pivot: p' = Rx@Ry@p.
            to_pivot = mathutils.Matrix.Translation(-pivot)
            from_pivot = mathutils.Matrix.Translation(pivot)
            head.matrix_world = from_pivot @ rx @ ry @ to_pivot @ head_base
            scene.render.filepath = os.path.join(
                outdir, "pose_%d_%d.png" % (yi, pi)
            )
            bpy.ops.render.render(write_still=True)
            count += 1

    print("render_atlas.py: rendered %d poses -> %s (size %d, %s)" % (
        count, outdir, opt["size"], opt["engine"]))


if __name__ == "__main__":
    main()
