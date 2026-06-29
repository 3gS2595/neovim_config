# In-Blender portrait sheet builder -- paste into Blender's Text Editor and press
# Run Script (Alt+P). Unlike render_atlas.py / build.sh, this needs NO export:
# it spins an object already in your open .blend across the 15 yaw x 9 pitch grid,
# renders each pose from your existing camera/lights/world (so your reflections,
# PBR materials and shading are baked exactly as you set them up), then assembles
# atlas/sheet.png itself. build.sh / render.lua / render_atlas.py are untouched.
#
# QUICK START: select your head object, set OUTPUT_DIR below, Run Script.
#
# The output sheet keeps the contract the runtime (baseline/portrait.lua) needs:
# 15 columns (yaw) x 9 rows (pitch), row-major with pitch=row/yaw=column, zero
# spacing, transparent background. The runtime divides the sheet by 15x9, so it
# consumes this unchanged.
#
# If a rebuilt head looks mirrored vs the old atlas/sheet.png, flip YAW_SIGN /
# PITCH_SIGN below and re-run.

import os
import math
import shutil
import subprocess

import bpy
import mathutils
import numpy as np

# ============================ CONFIG =========================================
# Head object that turns to look at the mouse. "" = use the active/selected one.
HEAD_OBJECT = ""

# Where to write atlas/sheet.png (+ the per-pose PNGs). "//" is blend-relative;
# point this at your nvim config's portrait/atlas folder, e.g.
#   "/home/you/.config/nvim/portrait/atlas"
OUTPUT_DIR = "//atlas"

CELL_SIZE = 320           # px per pose cell

# "" keeps the scene's current render engine; or force "BLENDER_EEVEE_NEXT" /
# "BLENDER_EEVEE" / "CYCLES".
ENGINE = ""
SAMPLES = 0               # 0 = keep the scene's current sample count

USE_SCENE_CAMERA = True   # use your scene camera as-is (recommended -- aim your
                          # own camera in Blender to set the angle). If False or
                          # no camera exists, an orthographic camera is created
                          # head-on along AUTO_CAM_FRONT below.

# Only used when an auto camera is built: which WORLD axis the model's face points
# along. Blender characters usually face -Y (front view), so that's the default;
# use "+Y"/"+X"/"-X"/"+Z"/"-Z" if yours faces elsewhere.
AUTO_CAM_FRONT = "-Y"
TRANSPARENT = True        # render with a transparent background (true alpha)

YAW_SIGN = 1.0            # flip to -1.0 if horizontal turn comes out mirrored
PITCH_SIGN = 1.0          # flip to -1.0 if vertical turn comes out mirrored

KEEP_POSE_FILES = False   # keep the 135 per-pose PNGs next to the sheet
# =============================================================================

# Grid + angles -- MUST match render.lua / build.sh / portrait.lua.
YAW_STEPS = 15
PITCH_STEPS = 9
MAX_YAW = 35.0
MAX_PITCH = 25.0


def angle(i, steps, max_deg):
    return (i / (steps - 1) * 2.0 - 1.0) * max_deg


def world_bbox(obj):
    mn = mathutils.Vector((1e9, 1e9, 1e9))
    mx = mathutils.Vector((-1e9, -1e9, -1e9))
    for corner in obj.bound_box:
        p = obj.matrix_world @ mathutils.Vector(corner)
        for k in range(3):
            mn[k] = min(mn[k], p[k])
            mx[k] = max(mx[k], p[k])
    return mn, mx


def resolve_head():
    if HEAD_OBJECT:
        obj = bpy.data.objects.get(HEAD_OBJECT)
        if not obj:
            raise SystemExit("render_atlas_gui: no object named '%s'" % HEAD_OBJECT)
        return obj
    obj = bpy.context.view_layer.objects.active
    if not obj:
        raise SystemExit("render_atlas_gui: set HEAD_OBJECT or select the head object")
    return obj


def ensure_camera(scene, head):
    # Use the scene camera if asked and present; otherwise build an orthographic
    # camera that frames the head (fit=1.7 margin, matching render.lua's no-frame
    # path) looking down -Z with +Y up.
    if USE_SCENE_CAMERA and scene.camera:
        return scene.camera, None
    hmn, hmx = world_bbox(head)
    center = (hmn + hmx) * 0.5
    ext = max(hmx[0] - hmn[0], hmx[1] - hmn[1], hmx[2] - hmn[2], 1e-6)
    cam_data = bpy.data.cameras.new("portrait_cam_tmp")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ext * (2.0 / 1.7)
    cam = bpy.data.objects.new("portrait_cam_tmp", cam_data)
    scene.collection.objects.link(cam)

    # Place the camera in FRONT of the model's face and aim it head-on. Build the
    # orientation from an explicit look-at basis so it's correct in Blender's
    # Z-up world (a zero rotation would look straight DOWN, not head-on).
    axes = {
        "+X": (1, 0, 0), "-X": (-1, 0, 0),
        "+Y": (0, 1, 0), "-Y": (0, -1, 0),
        "+Z": (0, 0, 1), "-Z": (0, 0, -1),
    }
    f = mathutils.Vector(axes.get(AUTO_CAM_FRONT, (0, -1, 0))).normalized()
    cam.location = center + f * (ext * 10.0)
    forward = -f  # view direction (camera looks down its local -Z)
    world_up = mathutils.Vector((0, 0, 1))
    if abs(forward.dot(world_up)) > 0.99:  # looking up/down: pick a valid up
        world_up = mathutils.Vector((0, 1, 0))
    right = forward.cross(world_up).normalized()
    true_up = right.cross(forward).normalized()
    basis = mathutils.Matrix((
        (right.x, true_up.x, -forward.x),
        (right.y, true_up.y, -forward.y),
        (right.z, true_up.z, -forward.z),
    ))  # columns = camera local +X, +Y, +Z (+Z is opposite the view dir)
    cam.rotation_euler = basis.to_euler()
    scene.camera = cam
    return cam, cam  # second value = the temp cam to delete afterwards


def apply_engine(scene):
    if ENGINE:
        scene.render.engine = ENGINE
    eng = scene.render.engine
    if SAMPLES > 0:
        if eng == "CYCLES":
            scene.cycles.samples = SAMPLES
        elif hasattr(scene.eevee, "taa_render_samples"):
            scene.eevee.taa_render_samples = SAMPLES


def load_pose_rgba(path, w, h):
    # Read a rendered pose back as a (h, w, 4) array, bottom-up (Blender's pixel
    # order). 'Non-Color' avoids a colour-management round trip so the bytes pass
    # through untouched -- the sheet is pixel-identical to an ImageMagick montage.
    img = bpy.data.images.load(path, check_existing=False)
    try:
        img.colorspace_settings.name = "Non-Color"
    except Exception:
        pass
    buf = np.empty(len(img.pixels), dtype=np.float32)
    img.pixels.foreach_get(buf)
    bpy.data.images.remove(img)
    return buf.reshape(h, w, 4)


def montage_numpy(pose_paths, sheet_path, size):
    tw, th = YAW_STEPS * size, PITCH_STEPS * size
    sheet = np.zeros((th, tw, 4), dtype=np.float32)  # bottom-up
    for (yi, pi), path in pose_paths.items():
        cell = load_pose_rgba(path, size, size)
        # pi=0 is the TOP row in the final PNG; in bottom-up space the top band
        # is the highest y, so row pi occupies [th-(pi+1)*size : th-pi*size].
        y0 = th - (pi + 1) * size
        x0 = yi * size
        sheet[y0:y0 + size, x0:x0 + size, :] = cell
    out = bpy.data.images.new("portrait_sheet", tw, th, alpha=True)
    try:
        out.colorspace_settings.name = "Non-Color"
    except Exception:
        pass
    out.pixels.foreach_set(sheet.reshape(-1))
    out.filepath_raw = sheet_path
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)


def montage_magick(pose_paths, sheet_path):
    tool = shutil.which("magick") or shutil.which("montage")
    if not tool:
        return False
    tiles = []
    for pi in range(PITCH_STEPS):
        for yi in range(YAW_STEPS):
            tiles.append(pose_paths[(yi, pi)])
    cmd = ["magick", "montage"] if shutil.which("magick") else ["montage"]
    cmd += tiles + [
        "-tile", "%dx%d" % (YAW_STEPS, PITCH_STEPS),
        "-geometry", "+0+0", "-background", "none", sheet_path,
    ]
    subprocess.run(cmd, check=True)
    return True


def main():
    scene = bpy.context.scene
    head = resolve_head()

    outdir = bpy.path.abspath(OUTPUT_DIR)
    os.makedirs(outdir, exist_ok=True)

    # Save everything we touch so the user's scene is restored afterwards.
    saved = {
        "engine": scene.render.engine,
        "rx": scene.render.resolution_x,
        "ry": scene.render.resolution_y,
        "pct": scene.render.resolution_percentage,
        "film": scene.render.film_transparent,
        "fmt": scene.render.image_settings.file_format,
        "mode": scene.render.image_settings.color_mode,
        "filepath": scene.render.filepath,
        "camera": scene.camera,
        "head_matrix": head.matrix_world.copy(),
    }
    temp_cam = None
    try:
        apply_engine(scene)
        cam, temp_cam = ensure_camera(scene, head)

        scene.render.resolution_x = CELL_SIZE
        scene.render.resolution_y = CELL_SIZE
        scene.render.resolution_percentage = 100
        scene.render.film_transparent = TRANSPARENT
        scene.render.image_settings.file_format = "PNG"
        scene.render.image_settings.color_mode = "RGBA" if TRANSPARENT else "RGB"

        # Rotate the head about ITS OWN centroid, around the CAMERA's axes, so yaw
        # turns it left/right on screen and pitch up/down regardless of how the
        # camera is oriented. render.lua applies yaw first, then pitch.
        cm = cam.matrix_world.to_3x3()
        right = cm.col[0].normalized()
        # Yaw (left-right) must turn the head about its VERTICAL spine -- the world
        # up axis -- exactly like render.lua, so the follow reads naturally. Using
        # the camera's up axis instead makes a tilted camera yaw about a diagonal
        # axis, which looks wrong. Pitch (up-down nod) stays about the camera's
        # horizontal right axis so it tracks the screen.
        up = mathutils.Vector((0.0, 0.0, 1.0))
        hmn, hmx = world_bbox(head)
        pivot = (hmn + hmx) * 0.5
        to_pivot = mathutils.Matrix.Translation(-pivot)
        from_pivot = mathutils.Matrix.Translation(pivot)
        head_base = head.matrix_world.copy()

        pose_paths = {}
        for yi in range(YAW_STEPS):
            ry = mathutils.Matrix.Rotation(
                math.radians(angle(yi, YAW_STEPS, MAX_YAW) * YAW_SIGN), 4, up)
            for pi in range(PITCH_STEPS):
                rx = mathutils.Matrix.Rotation(
                    math.radians(angle(pi, PITCH_STEPS, MAX_PITCH) * PITCH_SIGN),
                    4, right)
                head.matrix_world = from_pivot @ rx @ ry @ to_pivot @ head_base
                path = os.path.join(outdir, "pose_%d_%d.png" % (yi, pi))
                scene.render.filepath = path
                bpy.ops.render.render(write_still=True)
                pose_paths[(yi, pi)] = path
        print("render_atlas_gui: rendered %d poses" % len(pose_paths))

        sheet_path = os.path.join(outdir, "sheet.png")
        if not montage_magick(pose_paths, sheet_path):
            montage_numpy(pose_paths, sheet_path, CELL_SIZE)
        print("render_atlas_gui: wrote %s (%dx%d)" % (
            sheet_path, YAW_STEPS * CELL_SIZE, PITCH_STEPS * CELL_SIZE))

        if not KEEP_POSE_FILES:
            for path in pose_paths.values():
                try:
                    os.remove(path)
                except OSError:
                    pass
    finally:
        head.matrix_world = saved["head_matrix"]
        scene.render.engine = saved["engine"]
        scene.render.resolution_x = saved["rx"]
        scene.render.resolution_y = saved["ry"]
        scene.render.resolution_percentage = saved["pct"]
        scene.render.film_transparent = saved["film"]
        scene.render.image_settings.file_format = saved["fmt"]
        scene.render.image_settings.color_mode = saved["mode"]
        scene.render.filepath = saved["filepath"]
        scene.camera = saved["camera"]
        if temp_cam is not None:
            data = temp_cam.data
            bpy.data.objects.remove(temp_cam, do_unlink=True)
            bpy.data.cameras.remove(data)


if __name__ == "__main__":
    main()
