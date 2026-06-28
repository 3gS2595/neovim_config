-- Offline pose renderer for the portrait pane.
--
-- Loads an OBJ and renders one shaded view (orthographic, z-buffered, Lambert
-- shading on a celestial purple->pink ramp) to a binary PPM. The atlas builder
-- (build.sh) calls this once per yaw/pitch cell; PPMs are converted to PNG by
-- ImageMagick and shown at runtime by baseline/portrait.lua.
--
--   nvim -l render.lua <obj> <out.ppm> <size> <yaw_deg> <pitch_deg>
--
-- Pure LuaJIT (run via `nvim -l`); no Neovim APIs are used.

local obj_path = assert(arg[1], 'obj path required')
local out_path = assert(arg[2], 'output path required')
local size = tonumber(arg[3]) or 256
local yaw = math.rad(tonumber(arg[4]) or 0)
local pitch = math.rad(tonumber(arg[5]) or 0)

-- Base orientation so the model faces the camera before yaw/pitch are applied.
-- Suzanne already faces +Z (the viewer) in this OBJ, so no base spin. Set this
-- if a different asset faces elsewhere.
local base_yaw = math.rad(0)

-- parse OBJ ----------------------------------------------------------------

local V, F = {}, {}
for line in io.lines(obj_path) do
  local k = line:sub(1, 2)
  if k == 'v ' then
    local x, y, z = line:match('^v%s+(%S+)%s+(%S+)%s+(%S+)')
    V[#V + 1] = { tonumber(x), tonumber(y), tonumber(z) }
  elseif k == 'f ' then
    local idx = {}
    for tok in line:gmatch('%S+') do
      if tok ~= 'f' then
        idx[#idx + 1] = tonumber(tok:match('^(%d+)'))
      end
    end
    F[#F + 1] = idx
  end
end

-- normalize: centre at origin, scale longest axis to ~1.8 so it fits [-1,1].
local mn = { 1e9, 1e9, 1e9 }
local mx = { -1e9, -1e9, -1e9 }
for _, v in ipairs(V) do
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
local ext = math.max(mx[1] - mn[1], mx[2] - mn[2], mx[3] - mn[3])
local s = 1.8 / ext
for _, v in ipairs(V) do
  v[1] = (v[1] - c[1]) * s
  v[2] = (v[2] - c[2]) * s
  v[3] = (v[3] - c[3]) * s
end

-- transform ----------------------------------------------------------------

local by, bsy = math.cos(base_yaw), math.sin(base_yaw)
local cyw, syw = math.cos(yaw), math.sin(yaw)
local cp, sp = math.cos(pitch), math.sin(pitch)

-- Apply base yaw, then view yaw (about Y), then pitch (about X). +Z is toward
-- the viewer; we keep camera-space coords so the face normal's z tells us facing.
local function transform(p)
  local x, y, z = p[1], p[2], p[3]
  -- base yaw
  local x0 = x * by + z * bsy
  local z0 = -x * bsy + z * by
  -- view yaw
  local x1 = x0 * cyw + z0 * syw
  local z1 = -x0 * syw + z0 * cyw
  -- pitch
  local y2 = y * cp - z1 * sp
  local z2 = y * sp + z1 * cp
  return x1, y2, z2
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

-- render every face: transform verts, cull backfaces, shade, triangulate.
for _, f in ipairs(F) do
  local poly = {}
  for _, vi in ipairs(f) do
    local x, y, z = transform(V[vi])
    poly[#poly + 1] = { x, y, z }
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
        local r, g, b = ramp(t)
        r, g, b = math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
        for k = 2, #poly - 1 do -- triangle fan
          shade_tri(poly[1], poly[k], poly[k + 1], r, g, b)
        end
      end
    end
  end
end

-- write PPM (P6) -----------------------------------------------------------

local out = assert(io.open(out_path, 'wb'))
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
