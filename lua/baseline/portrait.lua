-- Tree column = file tree (top) / square "portrait" pane (bottom).
--
--   +-----------+
--   | file tree |   <- nvim-tree (top), grows to fill the space above
--   |           |
--   +-----------+
--   |  PORTRAIT |   <- square pane: a 3D head that looks toward the mouse,
--   |  (square) |      pinned to the BOTTOM of the column
--   +-----------+
--
-- The head tracks the mouse live: 'mousemoveevent' + a <MouseMove> map feed
-- getmousepos() into a direction, which selects the nearest precomputed viewing
-- angle ("pose") and shows that pose over the square pane.
--
-- DESIGN -- one sheet, crop per frame. Poses are precomputed offline into a single
-- sprite SHEET: a yaw_steps x pitch_steps grid of head renders packed into one PNG
-- (portrait/render.lua + build.sh, a CPU rasterizer over an OBJ, montaged into
-- atlas/sheet.png). At runtime we:
--
--   1. TRANSMIT the sheet to the terminal ONCE, at attach (kitty graphics protocol,
--      f=100 raw PNG). It's the only expensive step and it happens before the user
--      interacts, so there is no warm-up, no background pre-fetch, no caching.
--   2. On every mouse move, emit ONE display escape that crops the cell for the
--      chosen pose out of the sheet (source rect x,y,w,h) and scales it into the
--      pane's cell box (c,r). Re-placing the same placement id REPLACES in place,
--      so a frame is a single escape -- no transmit, no delete, no flicker.
--
-- Because the sheet is transmitted once and the terminal rescales at display time,
-- every pose is ready from the first frame and a resize is just two escapes (re-crop
-- into the new box) -- never a re-transmit. That is the whole reason this file is
-- small: there is nothing to warm.
--
-- KITTY-ONLY. This needs a terminal that speaks the kitty graphics protocol
-- (kitty / Ghostty / WezTerm). If none is detected the pane is left blank.

local api = vim.api
local M = {}

M.config = {
  -- Atlas grid: how many discrete viewing angles the sheet packs. The grid also
  -- throttles work -- we only repaint when the cursor crosses into a new cell.
  yaw_steps = 15, -- horizontal angles (left..right) -> sheet columns
  pitch_steps = 9, -- vertical angles (up..down) -> sheet rows
  -- Cells are ~twice as tall as wide; scale vertical mouse delta into the same
  -- visual units as horizontal so a "square" of cursor travel maps evenly.
  cell_aspect = 2.0,
  sheet = nil, -- resolved in setup() to <config>/portrait/atlas/sheet.png
  image_id = 1000, -- kitty image id + placement id for the sheet (one resident image)
  -- kitty display z-index: negative => drawn BELOW text. The square pane shows a
  -- blank scratch buffer, so the head shows through; any real text would occlude it.
  zindex = -1,
  -- The easer's tick rate. <MouseMove> only sets a target; this timer walks the head
  -- toward it and renders at most once per tick, always on the latest target -- so it
  -- also bounds the display rate (<MouseMove> fires far faster than a terminal repaints).
  frame_interval = 16, -- ms (~60fps); raise toward 33 if the link is slow
  -- Easing time-constant: how fast the head chases the cursor. Lower = snappier,
  -- higher = floatier. ~70ms reads as natural head inertia without feeling laggy. The
  -- grid is discrete, so easing makes a fast swing GLIDE through the in-between poses
  -- we already have instead of jumping cells (which read as jitter).
  ease_tau = 70, -- ms
  -- Rows the tree pane keeps when the ideal square would crush it: on a wide
  -- column width/2 can exceed the height available, so we cap the square and let
  -- it be wider-than-tall rather than starve the tree above it.
  min_tree = 6,
}

-- engine state -------------------------------------------------------------

local state = {
  tree = nil, -- top window (nvim-tree)
  square = nil, -- bottom window (the head is drawn over this pane)
  pose = nil, -- {yi, pi} cell currently shown, so we can skip no-op repaints
  target = nil, -- {ty, tp} continuous index the head is easing toward (the cursor)
  cur = nil, -- {cy, cp} continuous index actually displayed (eased; rounds to `pose`)
  active = false, -- attached and running
  ready = false, -- a kitty graphics terminal was detected
  transmitted = false, -- the sheet has been sent to the terminal
  cell = nil, -- {w, h} source pixels per pose, read from the sheet's dimensions
  sgeo = nil, -- last square geometry {row,col,width,height}, to skip no-op redraws
  ease_timer = nil, -- uv timer driving the ease; runs only while unsettled
  easing = false, -- whether ease_timer is currently started
}

local uv = vim.uv or vim.loop

-- A throwaway, unlisted scratch buffer for a structural pane.
local function scratch()
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'wipe'
  vim.bo[b].swapfile = false
  return b
end

-- Strip the gutter chrome from a structural pane so it reads as a clean blank
-- area: the line-number '1', sign/fold columns, cursorline and the ~ end-of-buffer
-- markers all go.
local function blank_win(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local o = { number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', cursorline = false, list = false }
  for k, v in pairs(o) do
    pcall(api.nvim_set_option_value, k, v, { win = win })
  end
  -- Append eob (hide ~) WITHOUT replacing the window's fillchars: a plain set
  -- would clobber the global horiz=' ' that banners.lua uses to hide horizontal
  -- dividers, leaving a '─' line between the portrait and the empty pane.
  pcall(api.nvim_win_call, win, function()
    vim.opt_local.fillchars:append({ eob = ' ' })
  end)
end

-- geometry -----------------------------------------------------------------

local function square_geometry()
  local pos = api.nvim_win_get_position(state.square) -- {row, col}, 0-based, editor grid
  return {
    row = pos[1],
    col = pos[2],
    width = api.nvim_win_get_width(state.square),
    height = api.nvim_win_get_height(state.square),
  }
end

-- mouse -> pose ------------------------------------------------------------

-- Where is the cursor relative to the square pane's centre? Returns normalized
-- (nx, ny) in [-1, 1] in *visual* space (vertical corrected for cell aspect),
-- with +x right and +y down. Computed from screen cells, so it tracks the mouse
-- anywhere on screen, not just inside the pane.
local function cursor_offset()
  local mp = vim.fn.getmousepos()
  -- Reuse the square geometry cached by enforce_square (refreshed on every layout
  -- change) rather than re-querying the windowing layer on every mouse-move event.
  local g = state.sgeo or square_geometry()
  local cx = g.col + g.width / 2
  local cy = g.row + g.height / 2
  -- getmousepos is 1-based and screen-relative; with showtabline=0 the editor
  -- grid starts at screen row/col 1, so subtract 1 to match win position.
  local dx = (mp.screencol - 1) - cx
  local dy = ((mp.screenrow - 1) - cy) * M.config.cell_aspect
  local nx = dx / math.max(1, g.width / 2)
  local ny = dy / math.max(1, g.height) -- half-visual-height = h cells (h*aspect/2)
  return nx, ny
end

-- The CONTINUOUS atlas index toward the cursor (the un-rounded grid position), so the
-- easer can interpolate through cells rather than snap. The head looks toward the
-- cursor: yaw follows it left/right (nx), pitch up/down (ny matches the atlas's pitch
-- direction, so cursor-above -> head looks up). Clamped to the grid.
local function target_for_cursor()
  local nx, ny = cursor_offset()
  local function idx(n, steps)
    n = math.max(-1, math.min(1, n))
    return (n + 1) / 2 * (steps - 1)
  end
  return idx(nx, M.config.yaw_steps), idx(ny, M.config.pitch_steps)
end

-- kitty graphics -----------------------------------------------------------
--
-- We speak the kitty graphics protocol directly, reusing image.nvim's escape
-- helpers (and its SSH tty patch) for the chunked transmit and the display escape.
-- The sheet is transmitted ONCE (f=100, the raw PNG -- no magick) and the terminal
-- crops + scales a cell out of it at DISPLAY time, so transmits are size-independent
-- and the interactive path is display-only: it can never block on a transmit.

local kitty = nil -- { ok, helpers, codes, tty, ssh } -- loaded once, lazily

local function kitty_load()
  if kitty then
    return kitty.ok
  end
  kitty = { ok = false }
  pcall(require, 'image') -- trigger image.nvim's lazy-load so its SSH get_tty patch installs
  local ok1, helpers = pcall(require, 'image/backends/kitty/helpers')
  local ok2, codes = pcall(require, 'image/backends/kitty/codes')
  if not (ok1 and ok2) then
    return false
  end
  local oku, utils = pcall(require, 'image/utils')
  kitty.helpers = helpers
  kitty.codes = codes
  kitty.utils = oku and utils or nil -- kept for the tmux pane offset in kitty_show
  kitty.tty = (oku and utils.term and utils.term.get_tty) and utils.term.get_tty() or nil
  kitty.ssh = (vim.env.SSH_CLIENT ~= nil) or (vim.env.SSH_TTY ~= nil)
  kitty.ok = true
  return true
end

-- Read a PNG's pixel dimensions straight from its IHDR (bytes 17-24, big-endian),
-- so we can derive the per-pose cell size from the sheet without spawning magick.
local function png_size(path)
  local fd = io.open(path, 'rb')
  if not fd then
    return nil
  end
  local hdr = fd:read(24)
  fd:close()
  if not hdr or #hdr < 24 then
    return nil
  end
  local function be(s)
    local n = 0
    for i = 1, #s do
      n = n * 256 + s:byte(i)
    end
    return n
  end
  return be(hdr:sub(17, 20)), be(hdr:sub(21, 24))
end

local KITTY_CHUNK = 4096 -- raw base64 bytes per transmit chunk (matches image.nvim)

-- Transmit the sheet to the terminal exactly once and record the per-pose cell size.
-- Size-independent (the terminal scales at display time), so this never repeats on
-- resize. Over SSH we send the file bytes (direct); locally we hand over the path.
--
-- We build the chunked transmit by hand instead of calling image.nvim's
-- write_graphics because that helper does uv.sleep(1) BETWEEN every 4 KB chunk,
-- which for a multi-megabyte sheet would freeze the UI for ~a second. The kitty
-- protocol forbids interleaving other graphics commands mid-transmit, so the chunks
-- stay consecutive -- we just drop the artificial per-chunk sleeps.
local function transmit_sheet()
  if state.transmitted then
    return true
  end
  if not kitty_load() then
    return false
  end
  local path = M.config.sheet
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  local sw, sh = png_size(path)
  if not sw or not sh then
    return false
  end
  state.cell = { math.floor(sw / M.config.yaw_steps), math.floor(sh / M.config.pitch_steps) }

  local c = kitty.codes.control
  -- Over SSH the terminal can't read our filesystem, so we ship the PNG bytes
  -- (direct); locally we hand it the path and let it read the file itself.
  local medium = kitty.ssh and c.transmit_medium.direct or c.transmit_medium.file
  local payload
  if kitty.ssh then
    local fd = io.open(path, 'rb')
    if not fd then
      return false
    end
    payload = fd:read('*all')
    fd:close()
  else
    payload = path -- file medium: the terminal opens this path
  end
  -- kitty wants URL-safe base64 (image.nvim maps '-' -> '/' for the same reason).
  payload = vim.base64.encode(payload):gsub('%-', '/')
  local tty = kitty.ssh and kitty.tty or nil
  local first = true
  for i = 1, #payload, KITTY_CHUNK do
    local piece = payload:sub(i, i + KITTY_CHUNK - 1):gsub('%s', '')
    local more = (i + KITTY_CHUNK <= #payload) and 1 or 0
    local control
    if first then
      -- f=100 raw PNG (no magick, ~1/7th the bytes of RGBA); q=2 silences the ack.
      control = string.format(
        'a=%s,i=%d,f=%d,t=%s,q=2,m=%d',
        c.action.transmit,
        M.config.image_id,
        c.transmit_format.png,
        medium,
        more
      )
      first = false
    else
      control = 'm=' .. more -- continuation chunks carry only the more-data flag
    end
    pcall(kitty.helpers.write, '\27_G' .. control .. ';' .. piece .. '\27\\', tty, true)
  end
  state.transmitted = true
  return true
end

-- Show pose (yi,pi): crop its cell out of the sheet (source rect x,y,w,h, in sheet
-- pixels) and scale it into the pane's cell box (c=cols, r=rows). Re-placing the
-- sheet's own placement id REPLACES the previous placement in place -- one escape,
-- no transmit, no delete.
--
-- We build the framed display escape by hand instead of calling image.nvim's
-- write_graphics_at because that helper parks the cursor with CSI s / CSI u
-- (\x1b[s, \x1b[u). Those SCO save/restore sequences don't round-trip on some
-- terminals (notably WezTerm on Windows): the cursor is left sitting over the pane,
-- so the kitty placement re-anchors a row lower on every move and the head WALKS
-- OFF THE BOTTOM. The unambiguous DEC pair ESC 7 / ESC 8 (DECSC/DECRC) restores
-- correctly everywhere, so the head stays pinned. Still one synchronized (DEC 2026)
-- frame, so the swap is gapless.
local function kitty_show(yi, pi)
  local g = state.sgeo or square_geometry()
  local cw, ch = state.cell[1], state.cell[2]
  local c = kitty.codes.control
  -- screen cursor is 1-based; with showtabline=0 the editor grid starts at 1,1.
  local x, y = g.col + 1, g.row + 1
  -- Inside tmux the graphics cursor is pane-relative; shift to absolute screen
  -- cells exactly as write_graphics_at did.
  if kitty.utils and kitty.utils.tmux and kitty.utils.tmux.is_tmux then
    local p = kitty.utils.tmux.get_pane_position()
    x, y = x + p.left, y + p.top
  end
  local control = table.concat({
    c.keys.action .. '=' .. c.action.display,
    c.keys.image_id .. '=' .. M.config.image_id,
    c.keys.placement_id .. '=' .. M.config.image_id,
    c.keys.display_x .. '=' .. (yi * cw), -- source crop: left edge of this pose's cell
    c.keys.display_y .. '=' .. (pi * ch), -- source crop: top edge of this pose's cell
    c.keys.display_width .. '=' .. cw, -- source crop: one cell wide
    c.keys.display_height .. '=' .. ch, -- source crop: one cell tall
    c.keys.display_columns .. '=' .. g.width, -- scale the crop into the pane's cell box
    c.keys.display_rows .. '=' .. g.height,
    c.keys.display_zindex .. '=' .. M.config.zindex,
    c.keys.display_cursor_policy .. '=' .. c.display_cursor_policy.do_not_move,
    c.keys.quiet .. '=2',
  }, ',')
  local ESC = '\27'
  local seq = ESC .. '[?2026h' .. ESC .. '7' -- sync on, DEC save cursor
    .. ESC .. '[' .. y .. ';' .. x .. 'H' -- park over the pane (absolute, 1-based)
    .. ESC .. '_G' .. control .. ESC .. '\\' -- the display escape
    .. ESC .. '8' .. ESC .. '[?2026l' -- DEC restore cursor, sync off
  local tty = kitty.ssh and kitty.tty or nil
  pcall(kitty.helpers.write, seq, tty, true)
end

-- Free the sheet from the terminal (d=A frees image DATA, not just placements).
-- Used on teardown / atlas rebuild -- NOT on resize, since transmits are size-free.
local function kitty_clear()
  if kitty and kitty.ok then
    pcall(kitty.helpers.write_graphics, { action = kitty.codes.control.action.delete, display_delete = 'A', quiet = 2 })
  end
  state.transmitted = false
  state.pose = nil
end

-- The render seam: ensure the sheet is resident, then show the pose. Silently does
-- nothing until a kitty terminal is confirmed (state.ready).
function M.render_pose(yi, pi)
  if not state.ready then
    return
  end
  if not state.transmitted and not transmit_sheet() then
    return -- sheet missing / no kitty -> leave the pane blank
  end
  kitty_show(yi, pi)
end

-- easing -------------------------------------------------------------------
--
-- The grid is discrete, so a fast cursor sweep would jump several cells between two
-- mouse events and read as jitter. Instead <MouseMove> only sets a continuous TARGET
-- (target_for_cursor); a timer walks the DISPLAYED index toward it a fraction per tick
-- (exponential smoothing, time-constant config.ease_tau), so a big swing GLIDES through
-- the intermediate poses we already have, with natural head inertia. The timer renders
-- only when the rounded cell changes and stops once settled, so an idle head costs nothing.

-- Round a continuous index to its atlas cell, clamped to the grid.
local function cell(x, steps)
  return math.max(0, math.min(steps - 1, math.floor(x + 0.5)))
end

local stop_ease -- fwd decl (ease_tick stops the timer once settled)

local function ease_tick()
  if not (state.active and state.cur and state.target) then
    stop_ease()
    return
  end
  -- Framerate-independent smoothing: fraction of the remaining gap to close this tick.
  local a = 1 - math.exp(-M.config.frame_interval / M.config.ease_tau)
  local cy = state.cur[1] + (state.target[1] - state.cur[1]) * a
  local cp = state.cur[2] + (state.target[2] - state.cur[2]) * a
  -- Snap + settle within a fraction of a cell, so the timer can idle until the next move.
  local settled = math.abs(state.target[1] - cy) < 0.02 and math.abs(state.target[2] - cp) < 0.02
  if settled then
    cy, cp = state.target[1], state.target[2]
  end
  state.cur = { cy, cp }
  local yi, pi = cell(cy, M.config.yaw_steps), cell(cp, M.config.pitch_steps)
  if not state.pose or state.pose[1] ~= yi or state.pose[2] ~= pi then
    state.pose = { yi, pi }
    M.render_pose(yi, pi)
  end
  if settled then
    stop_ease()
  end
end

local function start_ease()
  if not state.ease_timer then
    state.ease_timer = uv.new_timer()
  end
  if not state.easing then
    state.easing = true
    state.ease_timer:start(0, M.config.frame_interval, vim.schedule_wrap(ease_tick))
  end
end

stop_ease = function()
  if state.ease_timer and state.easing then
    state.ease_timer:stop()
    state.easing = false
  end
end

-- Live mouse feed -- cheap. Just point the target at the cursor and let the easer run;
-- the timer bounds the render rate, so the event itself needs no throttle.
local function on_mouse()
  if not (state.active and state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local ty, tp = target_for_cursor()
  state.target = { ty, tp }
  if not state.cur then
    state.cur = { ty, tp } -- first ever sample: start at the target, no opening swing
  end
  start_ease()
end

-- Show the current pose into the (possibly new) geometry, seeding a centred pose the
-- first time so attach/rebuild paint something before the mouse moves.
local function redraw()
  if not state.pose then
    local yi = math.floor((M.config.yaw_steps - 1) / 2)
    local pi = math.floor((M.config.pitch_steps - 1) / 2)
    state.pose = { yi, pi }
    state.cur = state.cur or { yi, pi }
    state.target = state.target or { yi, pi }
  end
  M.render_pose(state.pose[1], state.pose[2])
end

-- square sizing ------------------------------------------------------------

local function hh(win)
  return (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_height(win) or 0
end

-- Re-show the head into the square's CURRENT geometry, whatever size it now is,
-- WITHOUT forcing any heights. This is the only thing that runs on a user drag, so
-- manual resizes are respected rather than fought -- the head just re-crops into
-- the box the user chose. A true no-op when the geometry hasn't actually moved
-- (transmits are size-independent, so a resize is only a re-crop -- redraw() does
-- exactly that), so unrelated layout events cost nothing.
local function refresh_square()
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local g = square_geometry()
  local sg = state.sgeo
  if sg and sg.row == g.row and sg.col == g.col and sg.width == g.width and sg.height == g.height then
    return
  end
  state.sgeo = g
  redraw()
end

-- Force the bottom window back to a true visual square (rows ~= cols / aspect) by
-- handing the tree the leftover height. This necessarily OVERRIDES whatever height
-- the square currently has, so it must NOT run on a plain WinResized (a user drag) --
-- only on events that reflow the whole layout anyway (terminal resize, window close,
-- tab switch) and on the initial attach. It only ever resizes the tree + square panes
-- (never a global `wincmd =`), so other columns keep the size the user gave them.
local function enforce_square()
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local w = api.nvim_win_get_width(state.square)
  local target = math.max(3, math.floor(w / M.config.cell_aspect + 0.5))
  -- Tree (top) + square (bottom) share the column; cap the square so the tree
  -- keeps its minimum on a wide column.
  local col_h = hh(state.tree) + hh(state.square)
  if col_h > 0 then
    target = math.max(3, math.min(target, col_h - M.config.min_tree))
  end

  -- Only restructure when the square isn't already the right height. We set the
  -- tree height directly (with equalalways off so the change stays in this
  -- column); the square below absorbs the remainder to land on `target`.
  if hh(state.square) ~= target and col_h > 0 then
    local tree_h = math.max(M.config.min_tree, col_h - target)
    local ea = vim.o.equalalways
    vim.o.equalalways = false
    vim.wo[state.square].winfixheight = false
    pcall(api.nvim_win_set_height, state.tree, tree_h)
    vim.wo[state.square].winfixheight = true
    vim.o.equalalways = ea
  end

  refresh_square()
end

-- kitty-protocol detection --------------------------------------------------

-- Fast path: terminals that advertise the kitty graphics protocol via env. TERM
-- is forwarded over SSH, so kitty/Ghostty are caught even remotely; WezTerm often
-- isn't (generic TERM) and relies on the probe below.
local function env_kitty()
  local e = vim.env
  local term = (e.TERM or ''):lower()
  if term:find('kitty') or term:find('ghostty') then
    return true
  end
  local tp = (e.TERM_PROGRAM or ''):lower()
  if tp == 'ghostty' or tp == 'wezterm' then
    return true
  end
  return e.KITTY_WINDOW_ID ~= nil or e.GHOSTTY_RESOURCES_DIR ~= nil or e.WEZTERM_PANE ~= nil
end

-- General path: ask the terminal. Send a kitty graphics *query* (a=q); only a
-- kitty-capable terminal answers with an APC '...;OK...' response, which Neovim
-- surfaces via TermResponse. Others ignore the unknown APC, so we time out. This
-- works over SSH (the real terminal is queried) and never disturbs the display.
local function probe_kitty(cb)
  local done = false
  local grp = api.nvim_create_augroup('PortraitKittyProbe', { clear = true })
  local function finish(ok)
    if done then
      return
    end
    done = true
    pcall(api.nvim_del_augroup_by_id, grp)
    cb(ok)
  end
  api.nvim_create_autocmd('TermResponse', {
    group = grp,
    callback = function(ev)
      local seq = (type(ev.data) == 'table' and ev.data.sequence)
        or (type(ev.data) == 'string' and ev.data)
        or vim.v.termresponse
        or ''
      if type(seq) == 'string' and seq:find('\27_G', 1, true) and seq:find('OK', 1, true) then
        finish(true)
      end
    end,
  })
  pcall(function()
    io.stdout:write('\27_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\27\\')
    io.stdout:flush()
  end)
  vim.defer_fn(function()
    finish(false)
  end, 250)
end

-- Resolve whether this terminal can show the portrait: env fast-path, else probe.
local function detect_kitty(cb)
  if not kitty_load() then
    cb(false)
    return
  end
  if env_kitty() then
    cb(true)
    return
  end
  probe_kitty(cb)
end

-- wiring -------------------------------------------------------------------

local function setup_autocmds()
  local group = api.nvim_create_augroup('Portrait', { clear = true })
  -- Re-square only on events that reflow the whole layout anyway. WinResized is
  -- intentionally NOT here: it fires on every border drag, and re-squaring there
  -- would fight the user's manual resize. WinScrolled is also excluded -- it fires
  -- on every scroll and never moves the square.
  api.nvim_create_autocmd({ 'VimResized', 'WinClosed', 'TabEnter' }, {
    group = group,
    callback = function()
      vim.schedule(enforce_square)
    end,
  })
  -- A user dragging a border (WinResized) only re-crops the head into the new box;
  -- it never forces a height, so manual resizing is respected.
  api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      vim.schedule(refresh_square)
    end,
  })
  -- Live mouse tracking. mousemoveevent makes the UI deliver <MouseMove>; the map
  -- is cheap (compute pose, compare, maybe one escape) so firing on every motion is
  -- fine. Mapped across modes since the event arrives in whatever mode is active.
  vim.o.mousemoveevent = true
  -- Plain (non-expr) map: the function runs and the key is consumed, so nothing is
  -- typed. (An <expr> map returning '<Nop>' literally inserted "<Nop>".)
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<MouseMove>', function()
    on_mouse() -- cheap: just retarget the head; the easer bounds the render rate
  end, { desc = 'Portrait: follow cursor' })
end

-- Attach the engine to an existing window as the square pane.
function M.attach(square)
  state.square = square
  vim.wo[square].winbar = '' -- keep the portrait pane clean (no heart banner)
  vim.wo[square].winfixheight = true -- 'equalalways' must not resize the square
  api.nvim_set_hl(0, 'Portrait', { bg = 'NONE', fg = require('baseline.banners').config.fg })
  setup_autocmds()
  vim.schedule(function()
    detect_kitty(function(ok)
      state.ready = ok
      state.active = true
      enforce_square() -- sizes the square and shows the first pose (if ready)
      if not ok then
        vim.notify('[portrait] no kitty graphics protocol detected; pane left blank', vim.log.levels.WARN)
      end
    end)
  end)
end

-- Build the two-window tree column inside `center` (assumed empty/current): file
-- tree on top, square portrait pinned to the bottom, then attach the engine to
-- the square. With splitbelow=true the window we start in stays on top and :split
-- drops the square below it.
function M.setup_center(center)
  api.nvim_set_current_win(center)
  vim.cmd('split') -- bottom (square)
  local square = api.nvim_get_current_win()
  local sbuf = scratch()
  api.nvim_win_set_buf(square, sbuf)
  -- Tag as 'portrait' so lualine skips its winbar (disabled_filetypes in
  -- plugins/ui.lua) -- otherwise the heart-banner winbar reads as a separator
  -- line above the portrait.
  vim.bo[sbuf].filetype = 'portrait'
  blank_win(square) -- the head is drawn over this pane, so keep it visually empty

  -- Top window gets the file tree.
  api.nvim_set_current_win(center)
  require('nvim-tree.api').tree.open({ current_window = true })

  state.tree = center
  -- nvim-tree pins its window winfixwidth/winfixheight=true (a sidebar default).
  -- Here the tree is a STRUCTURAL pane whose right edge is Claude's left border, so
  -- those pins make dragging that border fight a fixed-size neighbour: Neovim keeps
  -- the tree's size and shoves the delta into other separators (the drag "jumps" and
  -- untouched borders move). Release them so the tree column resizes like any other.
  -- (The square keeps winfixheight, set in attach(), so enforce_square owns its height.)
  pcall(api.nvim_set_option_value, 'winfixwidth', false, { win = center })
  pcall(api.nvim_set_option_value, 'winfixheight', false, { win = center })
  M.attach(square)
  api.nvim_set_current_win(square)
end

-- Drop the sheet from the terminal and reset geometry, so a rebuilt atlas (e.g.
-- after swapping the model) is picked up on the next show without restarting.
local function reset()
  stop_ease()
  kitty_clear()
  state.cell = nil
  state.sgeo = nil
  state.pose = nil -- force redraw() to reseed and re-show after a rebuild
  state.cur = nil
  state.target = nil
end

function M.setup()
  M.config.sheet = M.config.sheet or (vim.fn.stdpath('config') .. '/portrait/atlas/sheet.png')
  api.nvim_create_user_command('Portrait', function(opts)
    if opts.args == 'rebuild' then
      reset()
      redraw()
    else
      -- Build the panes from the current window, for ad-hoc testing.
      M.setup_center(api.nvim_get_current_win())
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'rebuild' }
    end,
  })
end

return M
