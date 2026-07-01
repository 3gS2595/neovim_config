-- splash_images — draw real images (kitty graphics protocol) OVER the fastfetch
-- splash terminal pane, at cell coordinates the composer exported.
--
-- This is the Neovim runtime half of the flowerfetch composer's "kitty (real
-- image)" layers. The composer writes:
--   ~/.config/fastfetch/kitty/placements.lua   -- where each image goes (cells)
--   ~/.config/fastfetch/kitty/<name>.png        -- the image bytes
-- and this module transmits each PNG to the terminal once and draws it scaled
-- into a cell box over the splash pane, with a z-index, exactly the way
-- baseline.portrait draws the head sprites. The kitty mechanics here deliberately
-- MIRROR portrait.lua (transmit chunked f=100 PNG; display escape with crop/scale
-- at a parked cursor, DECSC/DECRC + DEC 2026 sync) rather than reaching into it,
-- so portrait stays untouched. If the two ever need to share, lift the common core
-- into a baseline.kitty module then.
--
-- SAFE BY CONSTRUCTION: every entry point is wrapped so that a missing placements
-- file, a non-kitty terminal, image.nvim not being present, or no splash pane all
-- result in a silent no-op. It NEVER alters the splash text or the startup path;
-- you invoke it with :SplashImages. Alignment is calibrated live with
-- :SplashImagesNudge and persisted, so you can dial it in without me guessing the
-- pane-tab offset.

local api = vim.api
local M = {}

M.config = {
  dir = vim.fn.expand('~/.config/fastfetch'),
  placements = 'kitty/placements.lua', -- relative to dir
  offset_file = 'kitty/offset.txt',    -- persisted calibration nudge ("row col")
  base_image_id = 2000, -- per-image ids start here (portrait owns 1000)
}

-- ---- kitty core (mirrors portrait.lua; see note above) --------------------
local kitty = nil -- { ok, helpers, codes, tty, ssh }
local function kitty_load()
  if kitty then return kitty.ok end
  kitty = { ok = false }
  pcall(require, 'image') -- install image.nvim's SSH get_tty patch
  local ok1, helpers = pcall(require, 'image/backends/kitty/helpers')
  local ok2, codes = pcall(require, 'image/backends/kitty/codes')
  if not (ok1 and ok2) then return false end
  local oku, utils = pcall(require, 'image/utils')
  kitty.helpers = helpers
  kitty.codes = codes
  kitty.utils = oku and utils or nil
  kitty.tty = (oku and utils.term and utils.term.get_tty) and utils.term.get_tty() or nil
  kitty.ssh = (vim.env.SSH_CLIENT ~= nil) or (vim.env.SSH_TTY ~= nil)
  kitty.ok = true
  return true
end

-- env fast-path detection (same terminals portrait supports)
local function env_kitty()
  local e = vim.env
  local term = (e.TERM or ''):lower()
  if term:find('kitty') or term:find('ghostty') then return true end
  local tp = (e.TERM_PROGRAM or ''):lower()
  if tp == 'ghostty' or tp == 'wezterm' then return true end
  return e.KITTY_WINDOW_ID ~= nil or e.GHOSTTY_RESOURCES_DIR ~= nil or e.WEZTERM_PANE ~= nil
end

local KITTY_CHUNK = 4096
local transmitted = {} -- file -> image_id, so each PNG is sent at most once

-- Transmit a PNG to the terminal once; returns its image id (or nil on failure).
local function transmit(file, image_id)
  if transmitted[file] then return transmitted[file] end
  if vim.fn.filereadable(file) == 0 then return nil end
  local c = kitty.codes.control
  local medium = kitty.ssh and c.transmit_medium.direct or c.transmit_medium.file
  local payload
  if kitty.ssh then
    local fd = io.open(file, 'rb'); if not fd then return nil end
    payload = fd:read('*all'); fd:close()
  else
    payload = file
  end
  payload = vim.base64.encode(payload):gsub('%-', '/') -- url-safe, like image.nvim
  local tty = kitty.ssh and kitty.tty or nil
  -- Pure, uninterrupted write loop (see portrait.lua's transmit_sheet note): do not
  -- let a Neovim UI flush splice into the middle of the in-flight transmission.
  local first = true
  for i = 1, #payload, KITTY_CHUNK do
    local piece = payload:sub(i, i + KITTY_CHUNK - 1):gsub('%s', '')
    local more = (i + KITTY_CHUNK <= #payload) and 1 or 0
    local control
    if first then
      control = string.format('a=%s,i=%d,f=%d,t=%s,q=2,m=%d',
        c.action.transmit, image_id, c.transmit_format.png, medium, more)
      first = false
    else
      control = 'm=' .. more
    end
    pcall(kitty.helpers.write, '\27_G' .. control .. ';' .. piece .. '\27\\', tty, true)
  end
  transmitted[file] = image_id
  return image_id
end

-- Display image `image_id` scaled into a `cols`x`rows` cell box at screen cell
-- (sx, sy) (1-based), at z-index z. Whole-image source (no crop).
local function display(image_id, sx, sy, cols, rows, z)
  local c = kitty.codes.control
  if kitty.utils and kitty.utils.tmux and kitty.utils.tmux.is_tmux then
    local p = kitty.utils.tmux.get_pane_position()
    sx, sy = sx + p.left, sy + p.top
  end
  local control = table.concat({
    c.keys.action .. '=' .. c.action.display,
    c.keys.image_id .. '=' .. image_id,
    c.keys.placement_id .. '=1',
    c.keys.display_columns .. '=' .. cols,
    c.keys.display_rows .. '=' .. rows,
    c.keys.display_zindex .. '=' .. z,
    c.keys.display_cursor_policy .. '=' .. c.display_cursor_policy.do_not_move,
    c.keys.quiet .. '=2',
  }, ',')
  local ESC = '\27'
  local seq = ESC .. '[?2026h' .. ESC .. '7'
    .. ESC .. '[' .. sy .. ';' .. sx .. 'H'
    .. ESC .. '_G' .. control .. ESC .. '\\'
    .. ESC .. '8' .. ESC .. '[?2026l'
  local tty = kitty.ssh and kitty.tty or nil
  pcall(kitty.helpers.write, seq, tty, true)
end

-- Free all images this module transmitted (drops their placements too).
local function clear_all()
  if not (kitty and kitty.ok) then return end
  for _, image_id in pairs(transmitted) do
    pcall(kitty.helpers.write_graphics, { action = kitty.codes.control.action.delete, image_id = image_id, display_delete = 'i', quiet = 2 })
  end
  transmitted = {}
end

-- ---- placements + calibration --------------------------------------------
local function path(rel) return M.config.dir .. '/' .. rel end

local function load_placements()
  local p = path(M.config.placements)
  if vim.fn.filereadable(p) == 0 then return nil end
  local ok, data = pcall(dofile, p)
  if not ok or type(data) ~= 'table' then return nil end
  return data
end

local function load_offset()
  local p = path(M.config.offset_file)
  local fd = io.open(p, 'r')
  if not fd then return { row = 0, col = 0 } end
  local s = fd:read('*l') or ''; fd:close()
  local r, c = s:match('^%s*(-?%d+)%s+(-?%d+)')
  return { row = tonumber(r) or 0, col = tonumber(c) or 0 }
end

local function save_offset(off)
  pcall(vim.fn.mkdir, path('kitty'), 'p')
  local fd = io.open(path(M.config.offset_file), 'w')
  if fd then fd:write(off.row .. ' ' .. off.col .. '\n'); fd:close() end
end

-- Find the splash terminal pane. Prefer the handle layout.lua remembers; fall back
-- to scanning for the bottom-left terminal window so the module still works if the
-- layout wasn't built (e.g. you opened a file).
local function splash_win()
  local ok, layout = pcall(require, 'baseline.layout')
  if ok and type(layout.splash_win) == 'function' then
    local w = layout.splash_win()
    if w and api.nvim_win_is_valid(w) then return w end
  end
  -- fallback: the lowest-left terminal window
  local best, best_score
  for _, w in ipairs(api.nvim_list_wins()) do
    local b = api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == 'terminal' then
      local pos = api.nvim_win_get_position(w)
      local score = pos[1] * 1000 - pos[2] -- lower-most, then left-most
      if not best_score or score > best_score then best, best_score = w, score end
    end
  end
  return best
end

-- ---- public --------------------------------------------------------------
function M.available()
  return kitty_load() and env_kitty()
end

-- Draw all placements over the splash pane. Returns count drawn, or nil + reason.
function M.render(opts)
  opts = opts or {}
  if not kitty_load() then return nil, 'image.nvim/kitty helpers not found' end
  if not (env_kitty() or opts.force) then return nil, 'no kitty-graphics terminal detected (use :SplashImages! to force)' end
  local data = load_placements()
  if not data then return nil, 'no placements file at ' .. path(M.config.placements) end
  local win = splash_win()
  if not (win and api.nvim_win_is_valid(win)) then return nil, 'splash terminal pane not found' end
  local pos = api.nvim_win_get_position(win) -- {row,col} 0-based
  local off = load_offset()
  -- file-level base_offset (from the placements file) + persisted calibration nudge
  local base = data.base_offset or {}
  local brow = (base.row or 0) + off.row
  local bcol = (base.col or 0) + off.col
  local n = 0
  for idx, im in ipairs(data.images or {}) do
    local file = im.file
    if file and not file:match('^/') then file = path(file) end
    local image_id = M.config.base_image_id + idx
    if transmit(file, image_id) then
      -- window top-left is (pos+1) in 1-based screen cells (showtabline=0), like portrait
      local sy = pos[1] + 1 + brow + (im.row or 0)
      local sx = pos[2] + 1 + bcol + (im.col or 0)
      display(image_id, sx, sy, im.cols or 10, im.rows or 6, im.z or 1)
      n = n + 1
    end
  end
  return n
end

function M.clear()
  clear_all()
end

-- Nudge the calibration offset by (dcol, drow) cells, persist, and redraw.
function M.nudge(dcol, drow)
  local off = load_offset()
  off.col = off.col + (dcol or 0)
  off.row = off.row + (drow or 0)
  save_offset(off)
  M.clear()
  local n, err = M.render()
  if err then vim.notify('[splash_images] ' .. err, vim.log.levels.WARN)
  else vim.notify(string.format('[splash_images] offset = (col %d, row %d), %d image(s)', off.col, off.row, n or 0)) end
end

function M.setup()
  api.nvim_create_user_command('SplashImages', function(a)
    local n, err = M.render({ force = a.bang })
    if err then vim.notify('[splash_images] ' .. err, vim.log.levels.WARN)
    else vim.notify('[splash_images] drew ' .. (n or 0) .. ' image(s)') end
  end, { bang = true, desc = 'Draw composer kitty images over the splash pane' })

  api.nvim_create_user_command('SplashImagesClear', function() M.clear() end,
    { desc = 'Remove the splash kitty images' })

  api.nvim_create_user_command('SplashImagesNudge', function(a)
    local dx, dy = a.fargs[1], a.fargs[2]
    M.nudge(tonumber(dx) or 0, tonumber(dy) or 0)
  end, { nargs = '*', desc = 'Nudge splash-image alignment: :SplashImagesNudge <dcol> <drow>' })
end

return M
