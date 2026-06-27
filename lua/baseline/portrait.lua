-- Middle column = file tree (top) / square "portrait" pane (middle) / empty (bottom).
--
--   +-----------+
--   | file tree |   <- nvim-tree (top)
--   +-----------+
--   |  PORTRAIT |   <- square pane: a 3D head that looks toward the mouse
--   |  (square) |
--   +-----------+
--   |  (empty)  |   <- spare pane (bottom)
--   +-----------+
--
-- The head tracks the mouse live: 'mousemoveevent' + a <MouseMove> map feed
-- getmousepos() into a direction, which selects the nearest precomputed viewing
-- angle ("pose") and blits that frame into a float pinned over the square pane.
--
-- THIS FILE IS THE BACKEND-AGNOSTIC ENGINE: pane layout, square sizing, the
-- mouse->pose mapping, and the float overlay. The actual per-pose pixels are
-- produced by M.render_pose(win, buf, yaw_i, pitch_i) -- currently a DEBUG text
-- stub so the interactive loop is verifiable on its own. The sixel renderer
-- (precomputed atlas shown via image.nvim) drops in there next, unchanged
-- elsewhere.

local api = vim.api
local M = {}

M.config = {
  -- Atlas grid: how many discrete viewing angles we precompute. The grid also
  -- throttles work -- we only repaint when the cursor crosses into a new cell.
  yaw_steps = 15, -- horizontal angles (left..right)
  pitch_steps = 9, -- vertical angles (up..down)
  -- How far the head turns when the cursor is at the pane edge (degrees). Only
  -- used to label the debug overlay for now; the renderer will consume these.
  max_yaw = 35,
  max_pitch = 25,
  -- Cells are ~twice as tall as wide; scale vertical mouse delta into the same
  -- visual units as horizontal so a "square" of cursor travel maps evenly.
  cell_aspect = 2.0,
  debug = true, -- true: draw pose/angle text instead of an image (skeleton mode)
  zindex = 40, -- above the banner/tab overlays (30/35), below telescope/noice
  -- Rows the tree/empty panes keep when the ideal square would crush them: on a
  -- wide column width/2 can exceed the height available, so we cap the square and
  -- let it be wider-than-tall rather than starve its neighbours.
  min_tree = 6,
  min_empty = 3,
}

-- engine state -------------------------------------------------------------

local state = {
  tree = nil, -- top window (nvim-tree)
  square = nil, -- middle window (portrait content; float sits over it)
  empty = nil, -- bottom window
  float = { win = nil, buf = nil },
  pose = nil, -- {yi, pi} currently shown, so we can skip no-op repaints
  active = false,
}

-- A throwaway, unlisted scratch buffer for a structural pane.
local function scratch()
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'wipe'
  vim.bo[b].swapfile = false
  return b
end

-- mouse -> pose ------------------------------------------------------------

-- Map a normalized coordinate n in [-1, 1] to an atlas index in [0, steps-1].
local function bucket(n, steps)
  n = math.max(-1, math.min(1, n))
  local i = math.floor((n + 1) / 2 * (steps - 1) + 0.5)
  return math.max(0, math.min(steps - 1, i))
end

-- Where is the cursor relative to the square pane's centre? Returns normalized
-- (nx, ny) in [-1, 1] in *visual* space (vertical corrected for cell aspect),
-- with +x right and +y down. Computed from screen cells, so it tracks the mouse
-- anywhere on screen, not just inside the pane.
local function cursor_offset()
  local mp = vim.fn.getmousepos()
  local pos = api.nvim_win_get_position(state.square) -- {row, col}, 0-based, editor grid
  local w = api.nvim_win_get_width(state.square)
  local h = api.nvim_win_get_height(state.square)
  local cx = pos[2] + w / 2
  local cy = pos[1] + h / 2
  -- getmousepos is 1-based and screen-relative; with showtabline=0 the editor
  -- grid starts at screen row/col 1, so subtract 1 to match win position.
  local dx = (mp.screencol - 1) - cx
  local dy = ((mp.screenrow - 1) - cy) * M.config.cell_aspect
  local nx = dx / math.max(1, w / 2)
  local ny = dy / math.max(1, h) -- half-visual-height = h cells (h*aspect/2)
  return nx, ny
end

-- Pick the atlas pose for the current cursor position. yaw grows rightward,
-- pitch grows upward (so cursor-above -> head looks up).
local function pose_for_cursor()
  local nx, ny = cursor_offset()
  local yi = bucket(nx, M.config.yaw_steps)
  local pi = bucket(-ny, M.config.pitch_steps)
  return yi, pi
end

-- Convert an atlas index back to a signed angle, for the debug label.
local function angle(i, steps, max)
  return (i / (steps - 1) * 2 - 1) * max
end

-- overlay float ------------------------------------------------------------

local function float_geometry()
  local pos = api.nvim_win_get_position(state.square)
  return {
    relative = 'editor',
    row = pos[1],
    col = pos[2],
    width = api.nvim_win_get_width(state.square),
    height = api.nvim_win_get_height(state.square),
  }
end

local function ensure_float()
  local h = state.float
  if h.win and api.nvim_win_is_valid(h.win) then
    pcall(api.nvim_win_set_config, h.win, vim.tbl_extend('force', float_geometry(), {}))
    return h
  end
  h.buf = scratch()
  local g = float_geometry()
  local ok, win = pcall(api.nvim_open_win, h.buf, false, vim.tbl_extend('force', g, {
    focusable = false,
    style = 'minimal',
    zindex = M.config.zindex,
    noautocmd = true,
  }))
  if not ok then
    return nil
  end
  h.win = win
  vim.wo[win].winhighlight = 'Normal:Portrait,NormalNC:Portrait'
  return h
end

-- DEBUG renderer: draw the current pose + angles, centred. This is the seam the
-- sixel atlas renderer replaces -- it gets the same (win, buf, yaw_i, pitch_i).
function M.render_pose(_, buf, yi, pi)
  local w = api.nvim_win_get_width(state.float.win)
  local h = api.nvim_win_get_height(state.float.win)
  local lines = {
    'portrait :: skeleton',
    '',
    string.format('pose  %d,%d', yi, pi),
    string.format('yaw   %+.0f°', angle(yi, M.config.yaw_steps, M.config.max_yaw)),
    string.format('pitch %+.0f°', angle(pi, M.config.pitch_steps, M.config.max_pitch)),
    '',
    'move the mouse →',
  }
  -- vertical + horizontal centring
  local out = {}
  local top = math.max(0, math.floor((h - #lines) / 2))
  for _ = 1, top do
    out[#out + 1] = ''
  end
  for _, l in ipairs(lines) do
    local pad = math.max(0, math.floor((w - vim.fn.strdisplaywidth(l)) / 2))
    out[#out + 1] = string.rep(' ', pad) .. l
  end
  pcall(api.nvim_buf_set_lines, buf, 0, -1, false, out)
end

-- Repaint only when the chosen pose actually changed (the grid throttles us).
local function update(force)
  if not (state.active and state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local h = ensure_float()
  if not h then
    return
  end
  local yi, pi = pose_for_cursor()
  if not force and state.pose and state.pose[1] == yi and state.pose[2] == pi then
    return
  end
  state.pose = { yi, pi }
  M.render_pose(h.win, h.buf, yi, pi)
end

-- square sizing ------------------------------------------------------------

-- Force the middle window to a true visual square: rows ~= cols / aspect. Run on
-- every layout change so `wincmd =` (which the startup layout calls) can't undo
-- it. The float is re-pinned to match.
local function enforce_square()
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local w = api.nvim_win_get_width(state.square)
  local target = math.max(3, math.floor(w / M.config.cell_aspect + 0.5))
  -- The three panes share the column, so their heights sum to its usable height.
  -- Cap the square so the tree/empty keep their minimums, then set heights
  -- top-down (tree, then square) -- setting one window only steals from the
  -- window below it, so a deterministic layout needs the explicit order; the
  -- bottom (empty) absorbs whatever remains.
  local function hh(win)
    return (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_height(win) or 0
  end
  local col_h = hh(state.tree) + hh(state.square) + hh(state.empty)
  if col_h > 0 then
    target = math.max(3, math.min(target, col_h - M.config.min_tree - M.config.min_empty))
  end
  -- winfixheight (set in attach) makes 'equalalways' leave the square alone and
  -- split the remaining rows between tree/empty, so this explicit height sticks.
  pcall(api.nvim_win_set_height, state.square, target)
  -- Re-balance the unfixed panes (tree/empty) around the now-fixed square.
  pcall(vim.cmd, 'wincmd =')
  if state.float.win and api.nvim_win_is_valid(state.float.win) then
    pcall(api.nvim_win_set_config, state.float.win, float_geometry())
  end
  update(true)
end

-- wiring -------------------------------------------------------------------

local function setup_autocmds()
  local group = api.nvim_create_augroup('Portrait', { clear = true })
  api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'WinClosed', 'WinScrolled', 'TabEnter' }, {
    group = group,
    callback = function()
      vim.schedule(enforce_square)
    end,
  })
  -- Live mouse tracking. mousemoveevent makes the UI deliver <MouseMove>; the map
  -- is cheap (compute pose, compare, maybe repaint) so firing on every motion is
  -- fine. Mapped across modes since the event arrives in whatever mode is active.
  vim.o.mousemoveevent = true
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<MouseMove>', function()
    update(false)
    return '<Nop>'
  end, { expr = true, desc = 'Portrait: follow cursor' })
end

-- Attach the engine to an existing window as the square pane.
function M.attach(square)
  state.square = square
  state.active = true
  vim.wo[square].winbar = '' -- keep the portrait pane clean (no heart banner)
  vim.wo[square].winfixheight = true -- 'equalalways' must not resize the square
  api.nvim_set_hl(0, 'Portrait', { bg = 'NONE', fg = require('baseline.banners').config.fg })
  setup_autocmds()
  vim.schedule(function()
    enforce_square()
    update(true)
  end)
end

-- Build the three-window middle column inside `center` (assumed empty/current),
-- then attach the engine to the square. Order with splitbelow=true: the window
-- we start in stays on top, each :split drops a new window below it.
function M.setup_center(center)
  api.nvim_set_current_win(center)
  vim.cmd('split') -- middle (square)
  local square = api.nvim_get_current_win()
  api.nvim_win_set_buf(square, scratch())
  vim.cmd('split') -- bottom (empty)
  local empty = api.nvim_get_current_win()
  api.nvim_win_set_buf(empty, scratch())

  -- Top window gets the file tree.
  api.nvim_set_current_win(center)
  require('nvim-tree.api').tree.open({ current_window = true })

  state.tree, state.empty = center, empty
  M.attach(square)
  api.nvim_set_current_win(square)
end

function M.setup()
  api.nvim_create_user_command('Portrait', function(opts)
    if opts.args == 'debug' then
      M.config.debug = not M.config.debug
      update(true)
      vim.notify('Portrait debug ' .. (M.config.debug and 'on' or 'off'))
    else
      -- Build the panes from the current window, for ad-hoc testing.
      M.setup_center(api.nvim_get_current_win())
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'debug' }
    end,
  })
end

return M
