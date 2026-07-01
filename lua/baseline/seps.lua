-- 3D separators + tabs: replace the glyph separators (the float columns/rows in
-- baseline.banners) and the box-drawing tab frames (baseline.panetabs) with kitty-
-- rendered tube/junction tiles. Tiles are built offline by portrait/build_seps.sh
-- (portrait/seps/*.png) and placed through the portrait module's generic kitty surface
-- (M.kitty_transmit_image / M.kitty_place / M.kitty_remove), so there is ONE kitty
-- layer and one terminal-detection path.
--
-- TILES: tube_v, tube_h (runs) and corner_{0,90,180,270} / tee_{0,90,180,270}
-- (junctions). All share the tube's radius-1 cross-section, so a corner/tee stub meets
-- a run with no seam.
--
-- GROUPS: placements are namespaced so independent redraws don't clobber each other --
-- banners owns 'frame', panetabs owns 'tabs'. Each clears only its own group.
--
-- Toggle with :Seps3D on|off. Off (or any non-kitty terminal) falls straight back to
-- the glyph UI, so this can never break the working separators/tabs.

local api = vim.api
local M = {}

-- Tile name -> kitty image id. Ids start above the portrait's (1000/1001). go_ready
-- transmits whichever tiles exist on disk; missing ones are simply never placed.
local TILES = {
  tube_v = 2000,
  tube_h = 2001,
  corner_0 = 2002,
  corner_90 = 2003,
  corner_180 = 2004,
  corner_270 = 2005,
  tee_0 = 2006,
  tee_90 = 2007,
  tee_180 = 2008,
  tee_270 = 2009,
}

M.config = {
  enabled = false, -- :Seps3D toggles; gated on kitty + the tiles regardless
  zindex = 1, -- base kitty z-index (> 0 => above pane text, like the old float)
  dir = nil, -- resolved in setup() to <config>/portrait/seps/
}

local portrait = require('baseline.portrait')

local state = {
  ready = false, -- the tiles are transmitted and resident
  loaded = {}, -- tile name -> true once transmitted
  groups = {}, -- group name -> { {img, pid}, ... } currently on screen
  next_pid = 2100, -- placement-id allocator (above portrait's 1000/1001)
}

-- True once a kitty terminal is confirmed and at least the run tiles are resident.
function M.active()
  return M.config.enabled and state.ready
end

-- Drop every placement in `group` (banners/panetabs call this before re-placing the
-- tiles that still exist). Each entry remembers its own image id so the delete is exact.
function M.clear(group)
  local g = state.groups[group]
  if not g then
    return
  end
  for _, e in ipairs(g) do
    portrait.kitty_remove(e.img, e.pid)
  end
  state.groups[group] = {}
end

-- Place a named tile into a cell box (0-based editor cells). Records the placement in
-- `group` for clear(). `z` overrides the base z-index (e.g. corners over a base run).
function M.place(group, tile, col, row, cols, rows, z)
  if not M.active() or cols < 1 or rows < 1 then
    return
  end
  local img = TILES[tile]
  if not (img and state.loaded[tile]) then
    return
  end
  local pid = state.next_pid
  state.next_pid = state.next_pid + 1
  local g = state.groups[group]
  if not g then
    g = {}
    state.groups[group] = g
  end
  g[#g + 1] = { img = img, pid = pid }
  portrait.kitty_place(img, pid, nil, { col = col, row = row, cols = cols, rows = rows }, z or M.config.zindex)
end

-- Convenience for the window frame (group 'frame'): one vertical / horizontal run.
function M.place_vrun(row, col, height)
  M.place('frame', 'tube_v', col, row, 1, height)
end

function M.place_hrun(row, col, width)
  M.place('frame', 'tube_h', col, row, width, 1)
end

-- Transmit every tile that exists on disk once a kitty terminal is confirmed, then ask
-- banners to repaint so the glyphs it drew before we were ready get replaced by tubes.
-- We require the run tiles (tube_v/h); junction tiles are best-effort.
local function go_ready()
  if state.ready or not M.config.enabled then
    return
  end
  if not portrait.kitty_is_ready() then
    return -- portrait hasn't confirmed kitty yet; PortraitReady will call us again
  end
  for name, id in pairs(TILES) do
    local path = M.config.dir .. name .. '.png'
    if not state.loaded[name] and vim.fn.filereadable(path) == 1 then
      if portrait.kitty_transmit_image(id, path) then
        state.loaded[name] = true
      end
    end
  end
  if state.loaded.tube_v then
    state.ready = true
    require('baseline.banners').refresh()
    require('baseline.panetabs').refresh()
  end
end

function M.setup()
  M.config.dir = M.config.dir or (vim.fn.stdpath('config') .. '/portrait/seps/')

  -- Portrait fires User PortraitReady once it has detected kitty and transmitted its
  -- own sheet; piggyback on that to transmit the tiles and flip on.
  api.nvim_create_autocmd('User', {
    pattern = 'PortraitReady',
    callback = function()
      vim.schedule(go_ready)
    end,
  })

  api.nvim_create_user_command('Seps3D', function(opts)
    if opts.args == 'off' then
      M.config.enabled = false
      M.clear('frame')
      M.clear('tabs')
    else
      M.config.enabled = true
      go_ready()
    end
    require('baseline.banners').refresh()
    require('baseline.panetabs').refresh()
  end, {
    nargs = '?',
    complete = function()
      return { 'on', 'off' }
    end,
  })
end

return M
