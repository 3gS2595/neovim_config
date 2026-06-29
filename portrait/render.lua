-- Offline pose renderer for the portrait pane.
--
-- Loads one or two OBJs and renders a single shaded view (orthographic,
-- z-buffered) to a binary PPM. The atlas builder (build.sh) calls this once per
-- yaw/pitch cell; PPMs are converted to PNG by ImageMagick and shown at runtime
-- by baseline/portrait.lua.
--
-- TWO MODELS. A "portrait" model and an optional "frame" model are composited
-- into the SAME image, sharing ONE normalization and ONE z-buffer:
--   * the PORTRAIT rotates (yaw/pitch) about its own centroid -- this is the head
--     that looks toward the mouse, so it pivots in place;
--   * the FRAME is static -- it gets only the shared normalization, no rotation,
--     so it reads as a still background/border behind the moving head.
-- Because they share a z-buffer the head can pass in front of / behind frame
-- geometry correctly. Because they share ONE bounding box for normalization,
-- their relative size and placement from Blender are preserved -- you don't have
-- to pre-scale anything; any input size auto-fits the square.
--
-- COLOR. By default both models use the celestial purple->pink shading ramp. With
-- --color, any model that ships an .mtl is shaded from its material diffuse (Kd)
-- instead; a model with no materials still falls back to the ramp. (Flat Kd only;
-- textures / map_Kd are out of scope.)
--
--   nvim -l render.lua --portrait <obj> [--frame <obj>] --out <ppm> \
--                      [--size N] [--yaw deg] [--pitch deg] [--color]
--
-- Pure LuaJIT (run via `nvim -l`); no Neovim APIs are used.

-- args ---------------------------------------------------------------------

local opt = { size = 256, yaw = 0, pitch = 0, color = false }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == '--portrait' then
      i = i + 1
      opt.portrait = arg[i]
    elseif a == '--frame' then
      i = i + 1
      opt.frame = arg[i]
    elseif a == '--out' then
      i = i + 1
      opt.out = arg[i]
    elseif a == '--size' then
      i = i + 1
      opt.size = tonumber(arg[i]) or opt.size
    elseif a == '--yaw' then
      i = i + 1
      opt.yaw = tonumber(arg[i]) or 0
    elseif a == '--pitch' then
      i = i + 1
      opt.pitch = tonumber(arg[i]) or 0
    elseif a == '--color' then
      opt.color = true
    else
      error('unknown argument: ' .. tostring(a))
    end
    i = i + 1
  end
end
assert(opt.portrait, '--portrait <obj> required')
assert(opt.out, '--out <ppm> required')

local size = opt.size
local yaw = math.rad(opt.yaw)
local pitch = math.rad(opt.pitch)

-- Base orientation so a model faces the camera before yaw/pitch are applied.
-- Models exported from Blender already facing the viewer (+Z) need no base spin;
-- set this if a different asset faces elsewhere.
local base_yaw = math.rad(0)

-- OBJ / MTL parsing --------------------------------------------------------

local function dirname(path)
  return path:match('^(.*)[/\\]') or '.'
end

-- Parse an .mtl into name -> { Kd = {r,g,b} } (diffuse colour, 0..1). Missing
-- files / fields are tolerated: callers fall back to the ramp when a material or
-- its Kd is absent.
local function parse_mtl(path)
  local mats = {}
  local fd = io.open(path, 'r')
  if not fd then
    return mats
  end
  local cur
  for line in fd:lines() do
    local name = line:match('^%s*newmtl%s+(.+)%s*$')
    if name then
      cur = { }
      mats[name] = cur
    else
      local r, g, b = line:match('^%s*Kd%s+(%S+)%s+(%S+)%s+(%S+)')
      if r and cur then
        cur.Kd = { tonumber(r), tonumber(g), tonumber(b) }
      end
    end
  end
  fd:close()
  return mats
end

-- Parse an OBJ into vertices, faces (each face carries the name of the material
-- in effect when it was declared), and the merged material table from any
-- mtllib it references. Face tokens may be v, v/vt, v//vn or v/vt/vn -- we keep
-- only the vertex index; negative (relative) indices are resolved.
local function parse_obj(path)
  local V, F = {}, {}
  local mats = {}
  local cur_mat
  for line in io.lines(path) do
    local k = line:sub(1, 2)
    if k == 'v ' then
      local x, y, z = line:match('^v%s+(%S+)%s+(%S+)%s+(%S+)')
      V[#V + 1] = { tonumber(x), tonumber(y), tonumber(z) }
    elseif k == 'f ' then
      local idx = {}
      for tok in line:gmatch('%S+') do
        if tok ~= 'f' then
          local n = tonumber(tok:match('^(-?%d+)'))
          if n then
            if n < 0 then
              n = #V + 1 + n -- OBJ relative index: -1 is the last vertex
            end
            idx[#idx + 1] = n
          end
        end
      end
      idx.mat = cur_mat
      F[#F + 1] = idx
    elseif line:sub(1, 7) == 'mtllib ' then
      local lib = line:match('^mtllib%s+(.+)%s*$')
      if lib then
        for name, m in pairs(parse_mtl(dirname(path) .. '/' .. lib)) do
          mats[name] = m
        end
      end
    elseif line:sub(1, 7) == 'usemtl ' then
      cur_mat = line:match('^usemtl%s+(.+)%s*$')
    end
  end
  return { V = V, F = F, mats = mats }
end

local portrait = parse_obj(opt.portrait)
local frame = opt.frame and parse_obj(opt.frame) or nil

-- normalization (shared, auto-fit) -----------------------------------------
--
-- ONE centre + ONE scale, applied to every vertex of both models, so input size
-- is irrelevant and the head/frame layout authored in Blender is preserved. The
-- BASIS for that fit depends on whether a frame was given:
--
--   * WITH a frame: fit the FRAME to fill the square (its bbox maps edge-to-edge,
--     so the frame is the "camera view" and is fully visible). The portrait rides
--     the same transform, keeping its size/placement RELATIVE to the frame -- so a
--     head you sized larger than the frame deliberately spills past the view and
--     the rasterizer just clips it. Size the portrait centred in the frame.
--   * WITHOUT a frame: fit the portrait alone to 1.7 (a margin inside [-1,1]) so
--     the head never clips the square edge as it swings.
local basis = frame and frame.V or portrait.V
local fit = frame and 2.0 or 1.7 -- 2.0 == edge-to-edge (project maps [-1,1] -> full square)

local mn = { 1e9, 1e9, 1e9 }
local mx = { -1e9, -1e9, -1e9 }
for _, v in ipairs(basis) do
  for i = 1, 3 do
    if v[i] < mn[i] then
      mn[i] = v[i]
    end
    if v[i] > mx[i] then
      mx[i] = v[i]
    end
  end
end

local c = { (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2 }
local ext = math.max(mx[1] - mn[1], mx[2] - mn[2], mx[3] - mn[3], 1e-6)
local s = fit / ext
local function normalize(V)
  for _, v in ipairs(V) do
    v[1] = (v[1] - c[1]) * s
    v[2] = (v[2] - c[2]) * s
    v[3] = (v[3] - c[3]) * s
  end
end
normalize(portrait.V)
if frame then
  normalize(frame.V)
end

-- The portrait pivots about ITS OWN centre (the bbox centre of just the portrait,
-- in the now-normalized space) so the head turns in place instead of swinging
-- across the frame.
local pmn = { 1e9, 1e9, 1e9 }
local pmx = { -1e9, -1e9, -1e9 }
for _, v in ipairs(portrait.V) do
  for i = 1, 3 do
    if v[i] < pmn[i] then
      pmn[i] = v[i]
    end
    if v[i] > pmx[i] then
      pmx[i] = v[i]
    end
  end
end
local pivot = { (pmn[1] + pmx[1]) / 2, (pmn[2] + pmx[2]) / 2, (pmn[3] + pmx[3]) / 2 }

-- transforms ---------------------------------------------------------------

local by, bsy = math.cos(base_yaw), math.sin(base_yaw)
local cyw, syw = math.cos(yaw), math.sin(yaw)
local cp, sp = math.cos(pitch), math.sin(pitch)

-- The portrait: base yaw, then view yaw (about Y), then pitch (about X), applied
-- about its pivot. +Z is toward the viewer; we keep camera-space coords so a face
-- normal's z tells us whether it faces the camera.
local function transform_portrait(p)
  local x, y, z = p[1] - pivot[1], p[2] - pivot[2], p[3] - pivot[3]
  local x0 = x * by + z * bsy
  local z0 = -x * bsy + z * by
  local x1 = x0 * cyw + z0 * syw
  local z1 = -x0 * syw + z0 * cyw
  local y2 = y * cp - z1 * sp
  local z2 = y * sp + z1 * cp
  return x1 + pivot[1], y2 + pivot[2], z2 + pivot[3]
end

-- The frame is static: identity (it already carries the shared normalization).
local function transform_frame(p)
  return p[1], p[2], p[3]
end

-- shading ------------------------------------------------------------------

-- Light from upper-front-right, in camera space.
local L = { 0.4, 0.5, 0.85 }
do
  local m = math.sqrt(L[1] ^ 2 + L[2] ^ 2 + L[3] ^ 2)
  L[1], L[2], L[3] = L[1] / m, L[2] / m, L[3] / m
end

-- Celestial ramp: deep indigo -> magenta/purple -> warm pink. Returns r,g,b.
local STOPS = {
  { 0.00, 0x12, 0x05, 0x2a },
  { 0.45, 0x6a, 0x12, 0x9e },
  { 0.80, 0xbe, 0x19, 0xe8 },
  { 1.00, 0xff, 0x8a, 0xd8 },
}
local function ramp(t)
  if t <= STOPS[1][1] then
    return STOPS[1][2], STOPS[1][3], STOPS[1][4]
  end
  for i = 2, #STOPS do
    if t <= STOPS[i][1] then
      local a, b = STOPS[i - 1], STOPS[i]
      local f = (t - a[1]) / (b[1] - a[1])
      return a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f
    end
  end
  return STOPS[#STOPS][2], STOPS[#STOPS][3], STOPS[#STOPS][4]
end

-- raster -------------------------------------------------------------------

local W, H = size, size
local px = {} -- r,g,b bytes, transparent-black background
local zb = {} -- z-buffer
for i = 1, W * H do
  px[i * 3 - 2], px[i * 3 - 1], px[i * 3] = 0, 0, 0
  zb[i] = -1e9
end

-- project camera coords to screen (orthographic). Flip Y for image space.
local function project(x, y)
  return (x + 1) / 2 * (W - 1), (1 - (y + 1) / 2) * (H - 1)
end

local function shade_tri(p1, p2, p3, r, g, b)
  local x1, y1 = project(p1[1], p1[2])
  local x2, y2 = project(p2[1], p2[2])
  local x3, y3 = project(p3[1], p3[2])
  local minx = math.max(0, math.floor(math.min(x1, x2, x3)))
  local maxx = math.min(W - 1, math.ceil(math.max(x1, x2, x3)))
  local miny = math.max(0, math.floor(math.min(y1, y2, y3)))
  local maxy = math.min(H - 1, math.ceil(math.max(y1, y2, y3)))
  local denom = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
  if denom == 0 then
    return
  end
  local z1, z2, z3 = p1[3], p2[3], p3[3]
  for yy = miny, maxy do
    for xx = minx, maxx do
      local a = ((y2 - y3) * (xx - x3) + (x3 - x2) * (yy - y3)) / denom
      local bb = ((y3 - y1) * (xx - x3) + (x1 - x3) * (yy - y3)) / denom
      local cc = 1 - a - bb
      if a >= 0 and bb >= 0 and cc >= 0 then
        local z = a * z1 + bb * z2 + cc * z3
        local i = yy * W + xx + 1
        if z > zb[i] then
          zb[i] = z
          px[i * 3 - 2], px[i * 3 - 1], px[i * 3] = r, g, b
        end
      end
    end
  end
end

-- Render one model: transform verts, cull backfaces, shade, triangulate. When
-- `colored` and the face's material has a Kd, the albedo is that diffuse colour
-- (Lambert-modulated); otherwise the celestial ramp.
local function render_model(model, transform, colored)
  for _, f in ipairs(model.F) do
    local poly = {}
    for _, vi in ipairs(f) do
      local v = model.V[vi]
      if v then
        local x, y, z = transform(v)
        poly[#poly + 1] = { x, y, z }
      end
    end
    if #poly >= 3 then
      -- face normal from first three verts
      local ax, ay, az = poly[2][1] - poly[1][1], poly[2][2] - poly[1][2], poly[2][3] - poly[1][3]
      local bx, by2, bz = poly[3][1] - poly[1][1], poly[3][2] - poly[1][2], poly[3][3] - poly[1][3]
      local nx = ay * bz - az * by2
      local ny = az * bx - ax * bz
      local nz = ax * by2 - ay * bx
      local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
      if nl > 0 then
        nx, ny, nz = nx / nl, ny / nl, nz / nl
        if nz > 0 then -- facing the viewer
          local diff = math.max(0, nx * L[1] + ny * L[2] + nz * L[3])
          local t = 0.18 + 0.82 * diff -- ambient + diffuse
          local r, g, b
          local mat = colored and f.mat and model.mats[f.mat] or nil
          if mat and mat.Kd then
            r, g, b = mat.Kd[1] * 255 * t, mat.Kd[2] * 255 * t, mat.Kd[3] * 255 * t
          else
            r, g, b = ramp(t)
          end
          r, g, b = math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
          -- The background is pure black and gets keyed to alpha downstream, so a
          -- covered pixel must never be exactly black (a near-black material would
          -- otherwise punch a hole). Nudge the blue channel up by one.
          if r == 0 and g == 0 and b == 0 then
            b = 1
          end
          for k = 2, #poly - 1 do -- triangle fan
            shade_tri(poly[1], poly[k], poly[k + 1], r, g, b)
          end
        end
      end
    end
  end
end

-- Frame first, head second; the shared z-buffer sorts out occlusion either way.
if frame then
  render_model(frame, transform_frame, opt.color)
end
render_model(portrait, transform_portrait, opt.color)

-- write PPM (P6) -----------------------------------------------------------

local out = assert(io.open(opt.out, 'wb'))
out:write('P6\n', W, ' ', H, '\n255\n')
local chunk = {}
for i = 1, W * H * 3 do
  chunk[#chunk + 1] = string.char(px[i])
  if #chunk >= 8192 then
    out:write(table.concat(chunk))
    chunk = {}
  end
end
out:write(table.concat(chunk))
out:close()
