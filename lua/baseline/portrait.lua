-- Tree column = square "portrait" pane (top) / file tree (middle) / square
-- "portrait" pane (bottom).
--
--   +-----------+
--   |  PORTRAIT |   <- square pane: a 3D head that looks toward the mouse,
--   |  (square) |      pinned to the TOP of the column
--   +-----------+
--   | file tree |   <- nvim-tree (middle), grows to fill the space between
--   |           |
--   +-----------+
--   |  PORTRAIT |   <- square pane pinned to the BOTTOM of the column. RESPONSIVE:
--   |  (square) |      only present when the terminal WINDOW is >= config.min_bottom_height
--   +-----------+      pixels tall (CSI 14 t); on a shorter window it is removed and the
--                      tree reclaims its space, and it returns live if the window grows.
--
-- Both heads track the mouse live: 'mousemoveevent' + a <MouseMove> map feed
-- getmousepos() into a direction PER PANE (each relative to its own centre),
-- which selects the nearest precomputed viewing angle ("pose") and shows that
-- pose over that pane.
--
-- DESIGN -- one sheet, crop per frame. Poses are precomputed offline into a single
-- sprite SHEET: a yaw_steps x pitch_steps grid of head renders packed into one PNG
-- (portrait/render.lua + build.sh, a CPU rasterizer over an OBJ, montaged into
-- atlas/sheet.png). At runtime we:
--
--   1. TRANSMIT the sheet to the terminal ONCE, at attach (kitty graphics protocol,
--      f=100 raw PNG). It's the only expensive step and it happens before the user
--      interacts, so there is no warm-up, no background pre-fetch, no caching. Both
--      panes share that one resident image.
--   2. On every mouse move, emit ONE display escape PER PANE that crops the cell for
--      the chosen pose out of the sheet (source rect x,y,w,h) and scales it into the
--      pane's cell box (c,r). Each pane owns a distinct PLACEMENT id over the same
--      image id, so re-placing it REPLACES that pane's head in place -- one escape,
--      no transmit, no delete, no flicker, and the two panes never clobber each other.
--
-- Because the sheet is transmitted once and the terminal rescales at display time,
-- every pose is ready from the first frame and a resize is just a re-crop into the
-- new box -- never a re-transmit. That is the whole reason this file is small: there
-- is nothing to warm.
--
-- KITTY-ONLY. This needs a terminal that speaks the kitty graphics protocol
-- (kitty / Ghostty / WezTerm). If none is detected the panes are left blank.

local api = vim.api
local M = {}

M.config = {
  -- Atlas grid: how many discrete viewing angles the sheet packs. The grid also
  -- throttles work -- we only repaint when the cursor crosses into a new cell.
  yaw_steps = 15, -- horizontal angles (left..right) -> sheet columns
  pitch_steps = 9, -- vertical angles (up..down) -> sheet rows
  -- Terminal cells are ~twice as tall as wide; enforce_column uses this to size the
  -- portrait windows into true visual squares (rows ~= cols / aspect).
  cell_aspect = 2.0,
  sheet = nil, -- resolved in setup() to <config>/portrait/atlas/sheet.png
  image_id = 1000, -- kitty image id for the sheet (one resident image, shared by both panes)
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
  -- Idle "return to centre": if no <MouseMove> arrives for this long, the heads
  -- ease back to facing forward (the grid centre) instead of staying frozen at the
  -- last cursor pose. Reuses the same easer, so the swing back glides like any other.
  idle_return = 1500, -- ms
  -- Rows the tree pane keeps when the ideal squares would crush it: on a wide
  -- column width/2 (per square) can exceed the height available, so we cap the
  -- squares and let them be wider-than-tall rather than starve the tree between them.
  min_tree = 6,
  -- The bottom head is RESPONSIVE: it only shows when the terminal WINDOW is at least
  -- this tall in PIXELS (queried live via CSI 14 t). On a shorter screen the bottom
  -- head is removed and the tree reclaims its space; growing the window back past this
  -- adds the head again on the fly. 1080 => hide it on sub-1080p-tall windows.
  min_bottom_height = 1080,
}

-- engine state -------------------------------------------------------------
--
-- `state` holds what the two panes SHARE: the tree window between them, kitty
-- readiness, the single transmitted sheet and its per-pose cell size, plus the list
-- of panes. Everything that differs per head lives on the pane object (see new_pane).

local state = {
  tree = nil, -- the file-tree window the squares sandwich
  panes = {}, -- list of pane objects (top + bottom), each an independent head
  active = false, -- attached and running
  ready = false, -- a kitty graphics terminal was detected
  transmitted = false, -- the sheet has been sent to the terminal
  cell = nil, -- {w, h} source pixels per pose, read from the sheet's dimensions
  idle_timer = nil, -- one-shot: fires config.idle_return ms after the last mouse move
  win_px_h = nil, -- last terminal WINDOW height in pixels (CSI 14 t report), drives the responsive bottom head
  px_known = false, -- whether the terminal has actually reported its pixel size yet (vs. our fallback guess)
  bottom = nil, -- the bottom pane object while it is shown; nil when hidden on a short window
}

local uv = vim.uv or vim.loop

-- A pane: one square window showing one head, with its own placement id, easer and
-- geometry cache so the two heads animate and re-crop fully independently.
local function new_pane(square, placement_id)
  return {
    square = square, -- the window the head is drawn over
    placement_id = placement_id, -- distinct kitty placement over the shared image
    pose = nil, -- {yi, pi} cell currently shown, so we can skip no-op repaints
    target = nil, -- {ty, tp} continuous index the head is easing toward (the cursor)
    cur = nil, -- {cy, cp} continuous index actually displayed (eased; rounds to `pose`)
    sgeo = nil, -- last square geometry {row,col,width,height}, to skip no-op redraws
    ease_timer = nil, -- uv timer driving the ease; runs only while unsettled
    easing = false, -- whether ease_timer is currently started
  }
end

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

local function square_geometry(pane)
  local pos = api.nvim_win_get_position(pane.square) -- {row, col}, 0-based, editor grid
  return {
    row = pos[1],
    col = pos[2],
    width = api.nvim_win_get_width(pane.square),
    height = api.nvim_win_get_height(pane.square),
  }
end

-- mouse -> pose ------------------------------------------------------------

-- Where is the cursor relative to THIS pane's centre, measured against the FULL
-- Neovim window? Returns normalized (nx, ny) in [-1, 1] with +x right and +y down:
-- 0 at the pane centre and ±1 only when the cursor reaches a window EDGE, so the head
-- ramps gradually across the whole window and hits full tilt only near the edges.
--
-- The portraits sit in the LEFT column, so the centre is off-centre in the window --
-- the gap to the right edge is much bigger than to the left. So each direction is
-- normalized by its OWN distance to the edge it's heading toward (right vs left, down
-- vs up); that pins full-left to the window's left edge and full-right to its right
-- edge, instead of the old code that maxed out within a pane-width of the portrait
-- (denominator was the tiny pane, not the window).
local function cursor_offset(pane)
  local mp = vim.fn.getmousepos()
  -- Reuse the square geometry cached by enforce_column (refreshed on every layout
  -- change) rather than re-querying the windowing layer on every mouse-move event.
  local g = pane.sgeo or square_geometry(pane)
  local cx = g.col + g.width / 2
  local cy = g.row + g.height / 2
  -- getmousepos is 1-based and screen-relative; with showtabline=0 the editor
  -- grid starts at screen row/col 1, so subtract 1 to match win position.
  local dx = (mp.screencol - 1) - cx
  local dy = (mp.screenrow - 1) - cy
  -- Distance from the centre to each window edge (vim.o.columns/lines = full editor
  -- size in cells). Guard against a zero gap when the centre sits on an edge, then
  -- normalize by the gap toward whichever edge the cursor is on so ±1 lands there.
  local right = math.max(1, vim.o.columns - cx)
  local left = math.max(1, cx)
  local down = math.max(1, vim.o.lines - cy)
  local up = math.max(1, cy)
  local nx = dx / (dx >= 0 and right or left)
  local ny = dy / (dy >= 0 and down or up)
  return nx, ny
end

-- The CONTINUOUS atlas index toward the cursor (the un-rounded grid position), so the
-- easer can interpolate through cells rather than snap. The head looks toward the
-- cursor: yaw follows it left/right (nx), pitch up/down (ny matches the atlas's pitch
-- direction, so cursor-above -> head looks up). Clamped to the grid.
local function target_for_cursor(pane)
  local nx, ny = cursor_offset(pane)
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

-- Send a PNG to the terminal under `image_id` exactly once and return ok. Size-
-- independent (the terminal scales at display time), so this never repeats on resize.
-- Over SSH we ship the file bytes (direct); locally we hand over the path (file).
--
-- We build the chunked transmit by hand instead of calling image.nvim's
-- write_graphics because that helper does uv.sleep(1) BETWEEN every 4 KB chunk,
-- which for a multi-megabyte sheet would freeze the UI for ~a second. The kitty
-- protocol forbids interleaving other graphics commands mid-transmit, so the chunks
-- stay consecutive -- we just drop the artificial per-chunk sleeps.
--
-- NB: do NOT paint anything (splash repaint, redraw, etc.) between the chunks below.
-- The chunks stream to the terminal fd via the kitty libuv tty handle, and a Neovim
-- UI flush writes to that SAME fd through a different, unsynchronised path -- forcing
-- one mid-loop splices Neovim's bytes into the middle of the in-flight PNG, so it
-- fails to decode and the image vanishes (intermittently, since it's timing-
-- dependent). A previous progress hook here did exactly that; keep this a pure write.
local function kitty_transmit(image_id, path)
  if not kitty_load() then
    return false
  end
  if vim.fn.filereadable(path) == 0 then
    return false
  end
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
        image_id,
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
  return true
end

-- Transmit the portrait sheet once and record the per-pose cell size from its PNG
-- dimensions (so we can crop a cell without spawning magick). The byte transmit is
-- kitty_transmit; here we just add the sheet-specific bookkeeping.
local function transmit_sheet()
  if state.transmitted then
    return true
  end
  local path = M.config.sheet
  local sw, sh = png_size(path)
  if not sw or not sh then
    return false
  end
  state.cell = { math.floor(sw / M.config.yaw_steps), math.floor(sh / M.config.pitch_steps) }
  if not kitty_transmit(M.config.image_id, path) then
    return false
  end
  state.transmitted = true
  return true
end

-- Place a crop of `image_id` into a screen-cell box, replacing any prior placement
-- with `placement_id` in place. src = {x,y,w,h} source pixels (nil = the whole
-- image); dst = {col,row,cols,rows} in 0-based editor cells; zindex follows kitty's
-- convention (negative => below text, >= 0 => above it).
--
-- We build the framed display escape by hand instead of calling image.nvim's
-- write_graphics_at because that helper parks the cursor with CSI s / CSI u
-- (\x1b[s, \x1b[u). Those SCO save/restore sequences don't round-trip on some
-- terminals (notably WezTerm on Windows): the cursor is left sitting over the pane,
-- so the kitty placement re-anchors a row lower on every move and the head WALKS
-- OFF THE BOTTOM. The unambiguous DEC pair ESC 7 / ESC 8 (DECSC/DECRC) restores
-- correctly everywhere. Still one synchronized (DEC 2026) frame, so the swap is gapless.
function M.kitty_place(image_id, placement_id, src, dst, zindex)
  if not state.ready or not kitty_load() then
    return
  end
  local c = kitty.codes.control
  -- screen cursor is 1-based; with showtabline=0 the editor grid starts at 1,1.
  local x, y = dst.col + 1, dst.row + 1
  -- Inside tmux the graphics cursor is pane-relative; shift to absolute screen cells.
  if kitty.utils and kitty.utils.tmux and kitty.utils.tmux.is_tmux then
    local p = kitty.utils.tmux.get_pane_position()
    x, y = x + p.left, y + p.top
  end
  local keys = {
    c.keys.action .. '=' .. c.action.display,
    c.keys.image_id .. '=' .. image_id,
    c.keys.placement_id .. '=' .. placement_id,
  }
  if src then
    keys[#keys + 1] = c.keys.display_x .. '=' .. src.x -- source crop: left edge
    keys[#keys + 1] = c.keys.display_y .. '=' .. src.y -- source crop: top edge
    keys[#keys + 1] = c.keys.display_width .. '=' .. src.w -- source crop width
    keys[#keys + 1] = c.keys.display_height .. '=' .. src.h -- source crop height
  end
  keys[#keys + 1] = c.keys.display_columns .. '=' .. dst.cols -- scale into this cell box
  keys[#keys + 1] = c.keys.display_rows .. '=' .. dst.rows
  keys[#keys + 1] = c.keys.display_zindex .. '=' .. (zindex or 0)
  keys[#keys + 1] = c.keys.display_cursor_policy .. '=' .. c.display_cursor_policy.do_not_move
  keys[#keys + 1] = c.keys.quiet .. '=2'
  local ESC = '\27'
  local seq = ESC .. '[?2026h' .. ESC .. '7' -- sync on, DEC save cursor
    .. ESC .. '[' .. y .. ';' .. x .. 'H' -- park over the box (absolute, 1-based)
    .. ESC .. '_G' .. table.concat(keys, ',') .. ESC .. '\\' -- the display escape
    .. ESC .. '8' .. ESC .. '[?2026l' -- DEC restore cursor, sync off
  pcall(kitty.helpers.write, seq, kitty.ssh and kitty.tty or nil, true)
end

-- Delete a single placement (d=i keeps the image data resident; uppercase would free
-- it), so one head can be dropped without re-transmitting the sheet.
function M.kitty_remove(image_id, placement_id)
  if not (kitty and kitty.ok) then
    return
  end
  local seq = '\27_Ga=d,d=i,i=' .. image_id .. ',p=' .. placement_id .. ',q=2\27\\'
  pcall(kitty.helpers.write, seq, kitty.ssh and kitty.tty or nil, true)
end

-- The file-tree window sandwiched between the two portrait heads, or nil if the
-- portrait column was never built (e.g. the `nvim <file>` side-panel fallback).
-- baseline.maps uses it as the fallback focus target when directional navigation
-- would otherwise strand the cursor on a portrait pane.
function M.tree_win()
  return (state.tree and api.nvim_win_is_valid(state.tree)) and state.tree or nil
end

-- Show pose (yi,pi) on `pane`: crop its cell out of the sheet and scale it into the
-- pane's box via the generic placement above. Re-placing THIS PANE's placement id
-- (over the shared image id) REPLACES only this pane's head -- the other is untouched.
-- The head sits BELOW text (zindex -1) and its pane is a blank scratch buffer, so it
-- shows through.
local function kitty_show(pane, yi, pi)
  local g = pane.sgeo or square_geometry(pane)
  local cw, ch = state.cell[1], state.cell[2]
  M.kitty_place(
    M.config.image_id,
    pane.placement_id,
    { x = yi * cw, y = pi * ch, w = cw, h = ch },
    { col = g.col, row = g.row, cols = g.width, rows = g.height },
    M.config.zindex
  )
end

-- Free the sheet from the terminal (d=A frees image DATA, not just placements, so it
-- drops both panes' placements too). Used on teardown / atlas rebuild -- NOT on
-- resize, since transmits are size-free.
local function kitty_clear()
  if kitty and kitty.ok then
    pcall(kitty.helpers.write_graphics, { action = kitty.codes.control.action.delete, display_delete = 'A', quiet = 2 })
  end
  state.transmitted = false
  for _, pane in ipairs(state.panes) do
    pane.pose = nil
  end
end

-- The render seam: ensure the sheet is resident, then show the pose on `pane`.
-- Silently does nothing until a kitty terminal is confirmed (state.ready).
function M.render_pose(pane, yi, pi)
  if not state.ready then
    return
  end
  if not state.transmitted and not transmit_sheet() then
    return -- sheet missing / no kitty -> leave the panes blank
  end
  kitty_show(pane, yi, pi)
end

-- easing -------------------------------------------------------------------
--
-- The grid is discrete, so a fast cursor sweep would jump several cells between two
-- mouse events and read as jitter. Instead <MouseMove> only sets a continuous TARGET
-- (target_for_cursor); a timer walks the DISPLAYED index toward it a fraction per tick
-- (exponential smoothing, time-constant config.ease_tau), so a big swing GLIDES through
-- the intermediate poses we already have, with natural head inertia. Each pane runs its
-- own timer, renders only when its rounded cell changes, and stops once settled, so an
-- idle head costs nothing.

-- Round a continuous index to its atlas cell, clamped to the grid.
local function cell(x, steps)
  return math.max(0, math.min(steps - 1, math.floor(x + 0.5)))
end

local stop_ease -- fwd decl (ease_tick stops the pane's timer once settled)

local function ease_tick(pane)
  if not (state.active and pane.cur and pane.target) then
    stop_ease(pane)
    return
  end
  -- Framerate-independent smoothing: fraction of the remaining gap to close this tick.
  local a = 1 - math.exp(-M.config.frame_interval / M.config.ease_tau)
  local cy = pane.cur[1] + (pane.target[1] - pane.cur[1]) * a
  local cp = pane.cur[2] + (pane.target[2] - pane.cur[2]) * a
  -- Snap + settle within a fraction of a cell, so the timer can idle until the next move.
  local settled = math.abs(pane.target[1] - cy) < 0.02 and math.abs(pane.target[2] - cp) < 0.02
  if settled then
    cy, cp = pane.target[1], pane.target[2]
  end
  pane.cur = { cy, cp }
  local yi, pi = cell(cy, M.config.yaw_steps), cell(cp, M.config.pitch_steps)
  if not pane.pose or pane.pose[1] ~= yi or pane.pose[2] ~= pi then
    pane.pose = { yi, pi }
    M.render_pose(pane, yi, pi)
  end
  if settled then
    stop_ease(pane)
  end
end

local function start_ease(pane)
  if not pane.ease_timer then
    pane.ease_timer = uv.new_timer()
  end
  if not pane.easing then
    pane.easing = true
    pane.ease_timer:start(0, M.config.frame_interval, vim.schedule_wrap(function()
      ease_tick(pane)
    end))
  end
end

stop_ease = function(pane)
  if pane.ease_timer and pane.easing then
    pane.ease_timer:stop()
    pane.easing = false
  end
end

-- After config.idle_return ms with no mouse movement, point every head's target at the
-- grid centre (facing forward) and let the easers glide them back -- so an abandoned
-- cursor doesn't leave the heads frozen mid-glance. Reuses the same target/easer path
-- as a real move, so the return swing is eased identically.
local function face_forward()
  if not state.active then
    return
  end
  local cy = (M.config.yaw_steps - 1) / 2
  local cp = (M.config.pitch_steps - 1) / 2
  for _, pane in ipairs(state.panes) do
    if pane.square and api.nvim_win_is_valid(pane.square) then
      pane.target = { cy, cp }
      if not pane.cur then
        pane.cur = { cy, cp }
      end
      start_ease(pane)
    end
  end
end

-- (Re)arm the one-shot idle timer: every mouse move pushes the "return to centre" back
-- another full idle_return window, so the heads only face forward once the cursor has
-- genuinely stopped moving for that long.
local function arm_idle()
  if not state.idle_timer then
    state.idle_timer = uv.new_timer()
  end
  state.idle_timer:stop()
  state.idle_timer:start(M.config.idle_return, 0, vim.schedule_wrap(face_forward))
end

-- Live mouse feed -- cheap. For each pane, just point its target at the cursor and let
-- its easer run; the timers bound the render rate, so the event itself needs no throttle.
local function on_mouse()
  if not state.active then
    return
  end
  for _, pane in ipairs(state.panes) do
    if pane.square and api.nvim_win_is_valid(pane.square) then
      local ty, tp = target_for_cursor(pane)
      pane.target = { ty, tp }
      if not pane.cur then
        pane.cur = { ty, tp } -- first ever sample: start at the target, no opening swing
      end
      start_ease(pane)
    end
  end
  arm_idle() -- cursor moved: reset the idle clock so the heads stay tracking
end

-- Show the pane's current pose into its (possibly new) geometry, seeding a centred pose
-- the first time so attach/rebuild paint something before the mouse moves.
local function redraw(pane)
  if not pane.pose then
    local yi = math.floor((M.config.yaw_steps - 1) / 2)
    local pi = math.floor((M.config.pitch_steps - 1) / 2)
    pane.pose = { yi, pi }
    pane.cur = pane.cur or { yi, pi }
    pane.target = pane.target or { yi, pi }
  end
  M.render_pose(pane, pane.pose[1], pane.pose[2])
end

-- square sizing ------------------------------------------------------------

local function hh(win)
  return (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_height(win) or 0
end

-- Re-show a pane's head into its square's CURRENT geometry, whatever size it now is,
-- WITHOUT forcing any heights. This is the only thing that runs on a user drag, so
-- manual resizes are respected rather than fought -- the head just re-crops into
-- the box the user chose. A true no-op when the geometry hasn't actually moved
-- (transmits are size-independent, so a resize is only a re-crop -- redraw() does
-- exactly that), so unrelated layout events cost nothing.
local function refresh_square(pane)
  if not (pane.square and api.nvim_win_is_valid(pane.square)) then
    return
  end
  local g = square_geometry(pane)
  local sg = pane.sgeo
  if sg and sg.row == g.row and sg.col == g.col and sg.width == g.width and sg.height == g.height then
    return
  end
  pane.sgeo = g
  redraw(pane)
end

-- Force the portrait windows back to true visual squares (rows ~= cols / aspect) by
-- handing the tree the leftover height. This necessarily OVERRIDES whatever heights the
-- squares currently have, so it must NOT run on a plain WinResized (a user drag) -- only
-- on events that reflow the whole layout anyway (terminal resize, window close, tab
-- switch) and on the initial attach. It only ever resizes the tree + square panes (never
-- a global `wincmd =`), so other columns keep the size the user gave them.
--
-- Both squares sit in the SAME column as the tree (top square / tree / bottom square),
-- so they share a width; each square's natural height is width/aspect. We size each
-- square to that target and let the tree (between them) absorb the remainder. Because the
-- squares bracket the tree, setting their heights pushes the delta into the tree, which
-- pins one head to the top of the column and the other to the bottom.
local function enforce_column()
  if not (state.tree and api.nvim_win_is_valid(state.tree)) then
    return
  end
  local panes = {}
  for _, p in ipairs(state.panes) do
    if p.square and api.nvim_win_is_valid(p.square) then
      panes[#panes + 1] = p
    end
  end
  if #panes == 0 then
    return
  end

  -- All windows in the column share a width; derive the square target from it.
  local w = api.nvim_win_get_width(panes[1].square)
  local target = math.max(3, math.floor(w / M.config.cell_aspect + 0.5))

  -- Total column height = tree + all squares. Cap each square so the tree keeps its
  -- minimum once every square has been carved out of the column.
  local col_h = hh(state.tree)
  for _, p in ipairs(panes) do
    col_h = col_h + hh(p.square)
  end
  if col_h > 0 then
    local max_total = math.max(0, col_h - M.config.min_tree)
    target = math.max(3, math.min(target, math.floor(max_total / #panes)))
  end

  -- Size each square to `target`; the tree between them absorbs the remainder. We set
  -- heights directly with equalalways off (so the change stays in this column) and the
  -- tree flexible (winfixheight off) so it -- not some other column -- takes the delta.
  if col_h > 0 then
    local ea = vim.o.equalalways
    vim.o.equalalways = false
    vim.wo[state.tree].winfixheight = false
    for _, p in ipairs(panes) do
      if hh(p.square) ~= target then
        vim.wo[p.square].winfixheight = false
        pcall(api.nvim_win_set_height, p.square, target)
        vim.wo[p.square].winfixheight = true
      end
    end
    vim.o.equalalways = ea
  end

  for _, p in ipairs(panes) do
    refresh_square(p)
  end
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

-- Resolve whether this terminal can show the portraits: env fast-path, else probe.
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

-- Forward decls: the responsive bottom-portrait helpers are defined after add_pane
-- (they need it), but the autocmds wired up below reference them.
local query_win_pixels, apply_bottom_visibility

local function setup_autocmds()
  local group = api.nvim_create_augroup('Portrait', { clear = true })
  -- Re-square only on events that reflow the whole layout anyway. WinResized is
  -- intentionally NOT here: it fires on every border drag, and re-squaring there
  -- would fight the user's manual resize. WinScrolled is also excluded -- it fires
  -- on every scroll and never moves the squares.
  api.nvim_create_autocmd({ 'VimResized', 'WinClosed', 'TabEnter' }, {
    group = group,
    callback = function()
      vim.schedule(function()
        enforce_column()
        -- A terminal resize can cross the bottom-head height threshold: re-ask the
        -- terminal for its pixel size. The reply lands on TermResponse below, which
        -- re-applies the bottom head's visibility.
        query_win_pixels()
      end)
    end,
  })
  -- The window's pixel size, reported by the terminal in response to query_win_pixels'
  -- CSI 14 t (format: ESC [ 4 ; height ; width t). We cache the height and add/remove
  -- the bottom head accordingly, so the layout responds live to a resize.
  api.nvim_create_autocmd('TermResponse', {
    group = group,
    callback = function(ev)
      local seq = (type(ev.data) == 'table' and ev.data.sequence)
        or (type(ev.data) == 'string' and ev.data)
        or vim.v.termresponse
        or ''
      if type(seq) ~= 'string' then
        return
      end
      local h = seq:match('\27%[4;(%d+);%d+t')
      if h then
        state.win_px_h = tonumber(h)
        state.px_known = true
        apply_bottom_visibility()
      end
    end,
  })
  -- A user dragging a border (WinResized) only re-crops the heads into their new boxes;
  -- it never forces a height, so manual resizing is respected.
  api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, pane in ipairs(state.panes) do
          refresh_square(pane)
        end
      end)
    end,
  })
  -- Live mouse tracking. mousemoveevent makes the UI deliver <MouseMove>; the map
  -- is cheap (compute pose, compare, maybe one escape per pane) so firing on every
  -- motion is fine. Mapped across modes since the event arrives in whatever mode is active.
  vim.o.mousemoveevent = true
  -- Plain (non-expr) map: the function runs and the key is consumed, so nothing is
  -- typed. (An <expr> map returning '<Nop>' literally inserted "<Nop>".)
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<MouseMove>', function()
    on_mouse() -- cheap: just retarget the heads; the easers bound the render rate
  end, { desc = 'Portrait: follow cursor' })
end

-- Register a square window as a head, keeping the structural pane clean. Returns the
-- pane object; the engine starts driving it once M.attach_column runs.
local function add_pane(square)
  vim.wo[square].winbar = '' -- keep the portrait pane clean (no heart banner)
  vim.wo[square].winfixheight = true -- 'equalalways' must not resize the square
  -- Distinct placement id per pane over the shared image id, so the two heads can be
  -- displayed (and replaced) independently without clobbering each other.
  local pane = new_pane(square, M.config.image_id + #state.panes)
  state.panes[#state.panes + 1] = pane
  return pane
end

-- responsive bottom head ----------------------------------------------------
--
-- The bottom head only earns its space on a tall enough window. We learn the window's
-- PIXEL height by asking the terminal (CSI 14 t), not by guessing from cells -- rows say
-- nothing about the physical height a head needs. When the reported height crosses
-- config.min_bottom_height we add or remove the bottom pane in place, so growing or
-- shrinking the window reflows the tree column live.

-- Ask the terminal for its window size in pixels; the reply arrives asynchronously on
-- TermResponse (parsed in setup_autocmds), so we never block on it. Same io.stdout path
-- probe_kitty uses, which reaches the real terminal even over SSH.
query_win_pixels = function()
  pcall(function()
    io.stdout:write('\27[14t')
    io.stdout:flush()
  end)
end

-- Split a fresh bottom square off the BOTTOM of the tree, wire it as a head, and let
-- enforce_column re-square the column (the tree gives up the height). Idempotent: does
-- nothing if the bottom head already exists or the column was never built.
local function add_bottom_pane()
  if state.bottom then
    return
  end
  if not (state.tree and api.nvim_win_is_valid(state.tree)) then
    return
  end
  local cur = api.nvim_get_current_win()
  api.nvim_set_current_win(state.tree)
  vim.cmd('belowright split') -- new window drops in below the tree -> the bottom square
  local square = api.nvim_get_current_win()
  local sbuf = scratch()
  api.nvim_win_set_buf(square, sbuf)
  vim.bo[sbuf].filetype = 'portrait'
  blank_win(square)
  state.bottom = add_pane(square)
  if api.nvim_win_is_valid(cur) then
    api.nvim_set_current_win(cur) -- adding the head must not steal focus
  end
  enforce_column() -- size the new square and hand the tree back the remainder
end

-- Tear the bottom head back out: drop its placement from the terminal, unregister the
-- pane, close its window, and re-square the column so the tree reclaims the space.
local function remove_bottom_pane()
  local pane = state.bottom
  if not pane then
    return
  end
  state.bottom = nil
  for i, p in ipairs(state.panes) do
    if p == pane then
      table.remove(state.panes, i)
      break
    end
  end
  stop_ease(pane)
  M.kitty_remove(M.config.image_id, pane.placement_id) -- drop this head from the terminal
  if pane.square and api.nvim_win_is_valid(pane.square) then
    pcall(api.nvim_win_close, pane.square, true)
  end
  enforce_column()
end

-- Reconcile the bottom head with the last reported window height: show it at/above the
-- threshold, hide it below. A no-op until we actually know the height (state.px_known),
-- so we never flap the layout on a stale/guessed value. Idempotent, so it is safe to
-- call from every resize and every terminal report.
apply_bottom_visibility = function()
  if not (state.active and state.win_px_h) then
    return
  end
  local want = state.win_px_h >= M.config.min_bottom_height
  if want and not state.bottom then
    add_bottom_pane()
  elseif not want and state.bottom then
    remove_bottom_pane()
  end
end

-- Detect kitty once, then start driving every registered pane: size the column and
-- paint each head's first pose. Detection/transmit are shared, so this runs once for
-- the whole column regardless of how many heads it holds.
local function attach_column()
  api.nvim_set_hl(0, 'Portrait', { bg = 'NONE', fg = require('baseline.banners').config.fg })
  setup_autocmds()
  vim.schedule(function()
    detect_kitty(function(ok)
      state.ready = ok
      state.active = true
      enforce_column() -- sizes the squares and shows the first pose on each (if ready)
      -- Learn the window's pixel height so the bottom head can decide whether to show;
      -- the reply lands on TermResponse and calls apply_bottom_visibility. If the
      -- terminal never reports (no CSI 14 t support), fall back to showing the bottom
      -- head after a short grace period so we don't strand the column headless.
      query_win_pixels()
      vim.defer_fn(function()
        if state.active and not state.px_known then
          state.win_px_h = M.config.min_bottom_height
          apply_bottom_visibility()
        end
      end, 400)
      if not ok then
        vim.notify('[portrait] no kitty graphics protocol detected; panes left blank', vim.log.levels.WARN)
      end
      -- Signal the startup splash that the sprite sheet is resident (or that we
      -- gave up on it), so its loading bar can advance. Fires either way.
      pcall(api.nvim_exec_autocmds, 'User', { pattern = 'PortraitReady', modeline = false })
    end)
  end)
end

-- Build the tree column inside `center` (assumed empty/current): a square portrait
-- pinned to the TOP, the file tree BELOW it, then start the engine. The BOTTOM head is
-- NOT built here -- it is added responsively (apply_bottom_visibility) once the terminal
-- reports a window tall enough for it, and removed again if the window shrinks. We split
-- the top square off `center` with aboveleft, leaving `center` as the tree window.
function M.setup_center(center)
  -- Top square: split above `center`, focus moves to the new (upper) window. `center`
  -- stays put below it as the tree window.
  api.nvim_set_current_win(center)
  vim.cmd('aboveleft split')
  local top = api.nvim_get_current_win()

  local sbuf = scratch()
  api.nvim_win_set_buf(top, sbuf)
  -- Tag as 'portrait' so lualine skips its winbar (disabled_filetypes in plugins/ui.lua)
  -- -- otherwise the heart-banner winbar reads as a separator line above the portrait.
  vim.bo[sbuf].filetype = 'portrait'
  blank_win(top) -- the head is drawn over this pane, so keep it visually empty
  add_pane(top)

  -- Middle window (`center`) gets the file tree.
  api.nvim_set_current_win(center)
  require('nvim-tree.api').tree.open({ current_window = true })

  state.tree = center
  -- nvim-tree pins its window winfixwidth/winfixheight=true (a sidebar default).
  -- Here the tree is a STRUCTURAL pane, so those pins make dragging its border fight
  -- a fixed-size neighbour: Neovim keeps the tree's size and shoves the delta into
  -- other separators (the drag "jumps" and untouched borders move). Release them so
  -- the tree column resizes like any other. (The squares keep winfixheight, set in
  -- add_pane(), so enforce_column owns their heights.)
  pcall(api.nvim_set_option_value, 'winfixwidth', false, { win = center })
  pcall(api.nvim_set_option_value, 'winfixheight', false, { win = center })
  attach_column()
  api.nvim_set_current_win(center)
end

-- Drop the sheet from the terminal and reset every pane's geometry, so a rebuilt atlas
-- (e.g. after swapping the model) is picked up on the next show without restarting.
local function reset()
  kitty_clear()
  state.cell = nil
  if state.idle_timer then
    state.idle_timer:stop()
  end
  for _, pane in ipairs(state.panes) do
    stop_ease(pane)
    pane.sgeo = nil
    pane.pose = nil -- force redraw() to reseed and re-show after a rebuild
    pane.cur = nil
    pane.target = nil
  end
end

function M.setup()
  M.config.sheet = M.config.sheet or (vim.fn.stdpath('config') .. '/portrait/atlas/sheet.png')
  api.nvim_create_user_command('Portrait', function(opts)
    if opts.args == 'rebuild' then
      reset()
      for _, pane in ipairs(state.panes) do
        redraw(pane)
      end
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
