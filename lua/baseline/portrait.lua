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
-- Poses are precomputed offline into an atlas of PNGs (portrait/render.lua +
-- build.sh, a CPU rasterizer over an OBJ). At runtime M.render_pose() converts
-- the chosen pose's PNG to truecolor "symbols" with chafa and streams it into a
-- terminal float, whose built-in emulator renders it -- no image protocol or
-- plugin required. (A 'debug' backend draws a pose/angle card instead, and is
-- the fallback when the atlas is missing.)
--
-- THIS FILE IS THE BACKEND-AGNOSTIC ENGINE: pane layout, square sizing, the
-- mouse->pose mapping, and the float overlay. The per-pose pixels come from
-- M.render_pose(win, buf, yaw_i, pitch_i); a sixel backend (image.nvim) could
-- drop in there for higher fidelity without touching the rest.

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
  -- Renderer: 'image' streams chafa truecolor symbols of the pose PNG into a
  -- terminal float (real rendered frames, any terminal); 'debug' draws a
  -- pose/angle text card. The atlas is built offline by portrait/build.sh.
  -- 'auto'   : probe the terminal once -- use 'kitty' if the kitty graphics
  --            protocol is supported, else 'image'. Resolved to a concrete value
  --            at attach time. The default.
  -- 'kitty'  : real pixels via image.nvim into the square window -- sharp,
  --            transparent, flicker-free. Needs a kitty-protocol terminal
  --            (kitty / WezTerm / Ghostty). (Sixel was tried and abandoned: on
  --            Windows Terminal it flickered the whole UI and had no alpha.)
  -- 'image'  : chafa truecolor symbols in a terminal float -- smooth, transparent,
  --            works in ANY terminal. The fallback.
  -- 'debug'  : pose/angle text card (also the fallback when a backend is missing).
  backend = 'auto',
  chafa = { 'chafa', '--format', 'symbols' }, -- size + path appended per render
  atlas_dir = nil, -- resolved in setup() to <config>/portrait/atlas
  prewarm = true, -- fill the frame cache in the background so motion is smooth
  warm_interval = 12, -- ms between background pre-warm conversions
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
  cache = {}, -- "yi_pi_WxH" -> rendered frame string (no trailing newline)
  size = nil, -- {w, h} the cache is keyed for; cleared when the pane resizes
  inflight = false, -- a chafa conversion is currently running (async)
  want = nil, -- newest pose requested while a conversion was inflight (coalesced)
  warm = { timer = nil }, -- background cache pre-warmer
  img = nil, -- current image.nvim object (kitty backend)
  kcache = {}, -- "yi_pi_WxH" -> image.nvim object, so each pose transmits once
  kwarm = false, -- a kitty pre-warm loop is currently running
  sgeo = nil, -- last square geometry, to skip no-op re-renders on layout events
}

-- Drop every cached kitty image (free the terminal-side pixels) -- used on resize,
-- since the cache is size-specific, and on teardown/backend switch.
local function clear_kcache()
  local ok, image = pcall(require, 'image')
  local supp = ok and image._portrait_suppress or nil
  for _, img in pairs(state.kcache) do
    if supp then
      supp[img.internal_id] = nil -- drop stale suppression for this image
    end
    pcall(function()
      img:clear()
    end)
  end
  state.kcache = {}
  state.kwarm = false -- a new size needs a fresh warm pass
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

-- Pick the atlas pose for the current cursor position. The head looks toward the
-- cursor: yaw follows it left/right (nx), pitch follows it up/down (ny matches the
-- atlas's pitch direction, so cursor-above -> head looks up).
local function pose_for_cursor()
  local nx, ny = cursor_offset()
  local yi = bucket(nx, M.config.yaw_steps)
  local pi = bucket(ny, M.config.pitch_steps)
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
    -- Already up; repositioning is done in enforce_square on layout changes, NOT
    -- here, so the per-mouse-move path stays free of window reconfigs.
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

local function atlas_path(yi, pi)
  return string.format('%s/pose_%d_%d.png', M.config.atlas_dir, yi, pi)
end

-- Lazily turn the float buffer into a terminal we can stream frames into.
-- Neovim's built-in terminal emulator renders chafa's truecolor symbol output
-- natively, so no image protocol or plugin is needed.
local function ensure_term()
  local h = state.float
  if h.chan and h.term_buf == h.buf then
    return h.chan
  end
  h.chan = api.nvim_open_term(h.buf, {})
  h.term_buf = h.buf
  -- Keep this internal terminal out of the terminal-pane tab list.
  pcall(function()
    require('baseline.panetabs').exclude_buf(h.buf)
  end)
  return h.chan
end

-- IMAGE renderer ------------------------------------------------------------
--
-- Converting a PNG to symbols is the only expensive step, so we (1) run chafa
-- ASYNCHRONOUSLY (vim.system) so it never blocks the UI, (2) CACHE each frame by
-- pose+size so a revisited angle is an instant terminal write, and (3) COALESCE:
-- while one conversion is inflight, newer mouse poses just overwrite `want`, so
-- a fast sweep spawns one chafa at a time and always lands on the latest pose. A
-- background pre-warmer fills the cache for the current size while idle, after
-- which every angle is cache-hit and motion is uniformly smooth.

local function frame_key(yi, pi, w, h)
  return yi .. '_' .. pi .. '_' .. w .. 'x' .. h
end

local function float_size()
  return api.nvim_win_get_width(state.float.win), api.nvim_win_get_height(state.float.win)
end

-- Write a cached frame to the terminal in place (clear + home, no scroll).
local function send_frame(s)
  local chan = ensure_term()
  pcall(api.nvim_chan_send, chan, '\27[2J\27[H' .. s)
end

local schedule_warm -- fwd decl (spawn -> schedule_warm -> spawn)

-- Spawn chafa for one pose, cache the result, and (when display) show it if it's
-- still the current pose at the same size. On completion, render any coalesced
-- `want`, else resume warming.
local function spawn(yi, pi, w, h, display)
  local path = atlas_path(yi, pi)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  state.inflight = true
  local cmd = vim.list_extend(vim.deepcopy(M.config.chafa), { '--size', w .. 'x' .. h, path })
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      state.inflight = false
      if res.code == 0 and res.stdout and res.stdout ~= '' then
        -- Strip the trailing newline (else the terminal scrolls a row per frame).
        local s = res.stdout:gsub('[\r\n]+$', '')
        state.cache[frame_key(yi, pi, w, h)] = s
        if
          display
          and state.pose
          and state.pose[1] == yi
          and state.pose[2] == pi
          and state.float.win
          and api.nvim_win_is_valid(state.float.win)
        then
          local cw, ch = float_size()
          if cw == w and ch == h then
            send_frame(s)
          end
        end
      end
      local want = state.want
      state.want = nil
      if want then
        M.render_pose(want[1], want[2]) -- render the latest requested pose
      else
        schedule_warm()
      end
    end)
  end)
  return true
end

local function next_uncached(w, h)
  for pi = 0, M.config.pitch_steps - 1 do
    for yi = 0, M.config.yaw_steps - 1 do
      if not state.cache[frame_key(yi, pi, w, h)] then
        return yi, pi
      end
    end
  end
end

-- Fill the cache for the current size in the background, one pose at a time,
-- yielding to any interactive render (inflight/want take priority).
schedule_warm = function()
  if not (M.config.prewarm and state.active and state.float.win) then
    return
  end
  if state.inflight or state.want or not api.nvim_win_is_valid(state.float.win) then
    return
  end
  local w, h = float_size()
  local yi, pi = next_uncached(w, h)
  if not yi then
    return -- fully warmed for this size
  end
  vim.defer_fn(function()
    if not state.inflight and not state.want then
      spawn(yi, pi, w, h, false)
    end
  end, M.config.warm_interval)
end

-- Returns false only when the atlas/chafa is unavailable (so render_pose can
-- fall back to the debug card). A cache hit displays instantly; a miss spawns
-- one async conversion (or, if busy, records the pose to render next).
local function render_image(yi, pi)
  if not (state.float.win and api.nvim_win_is_valid(state.float.win)) then
    return false
  end
  local w, h = float_size()
  local cached = state.cache[frame_key(yi, pi, w, h)]
  if cached then
    send_frame(cached)
    schedule_warm()
    return true
  end
  if vim.fn.filereadable(atlas_path(yi, pi)) == 0 then
    return false
  end
  if state.inflight then
    state.want = { yi, pi }
    return true
  end
  return spawn(yi, pi, w, h, true)
end

local kitty_warm -- fwd decl: kick the pre-warmer once a pose has rendered

-- Delete EVERY on-screen kitty PLACEMENT in one command (a=d, d=a -- lowercase a:
-- drop all placements but KEEP the image data resident on the terminal, so revisits
-- never force a base64 RE-TRANSMIT over SSH). The probe established that the stacking
-- was caused by orphaned placements -- ones beyond the single "previous" pose that
-- our per-pose hide lost track of -- and that this terminal honors deletes. A single
-- global delete is the robust, cheap (one escape) way to guarantee a clean slate; we
-- pair it with a redraw inside one synchronized-output frame (see render_kitty) so
-- the blank intermediate state is never presented -- no flicker.
local function kitty_delete_all()
  local ok, helpers = pcall(require, 'image/backends/kitty/helpers')
  local ok2, codes = pcall(require, 'image/backends/kitty/codes')
  if not (ok and ok2) then
    return false
  end
  pcall(function()
    helpers.write_graphics({
      action = codes.control.action.delete,
      display_delete = 'a', -- all placements; lowercase keeps image data resident
      quiet = 2,
    })
  end)
  return true
end

-- KITTY renderer: real pixels via image.nvim (kitty graphics protocol), drawn
-- into the square window (a normal window, which image.nvim handles more reliably
-- than a float). image.nvim owns the redraw lifecycle and uses the magick CLI
-- processor, so no luarock is needed. Returns false if image.nvim or the atlas is
-- missing (falls back to the debug card).
local function render_kitty(yi, pi)
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    return false
  end
  local ok, image = pcall(require, 'image')
  if not ok then
    return false
  end
  local path = atlas_path(yi, pi)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  local win = state.square
  local w = api.nvim_win_get_width(win)
  local h = api.nvim_win_get_height(win)
  -- One image object per pose+size, kept alive in kcache. The first visit to a
  -- pose transmits its pixels; every later visit is a placement-only :render()
  -- (image.nvim skips the transmit once the id+size is already on the terminal),
  -- so swapping angles costs two escape codes, not a base64 re-upload over SSH.
  -- A unique id per pose is what lets them all stay transmitted at once.
  local key = frame_key(yi, pi, w, h)
  local img = state.kcache[key]
  if not img then
    img = image.from_file(path, { id = 'portrait_' .. key, window = win, x = 0, y = 0, width = w, height = h })
    if not img then
      return false
    end
    state.kcache[key] = img
  end
  -- This pose is being shown for real now: lift any warm-time display suppression
  -- on it (it may have been transmitted-but-hidden by the pre-warmer) so its async
  -- re-render is allowed to paint. A warmed pose was marked is_rendered by the
  -- (suppressed) warm render even though nothing reached the screen, which would
  -- make image.nvim skip this paint as a no-op; clear that so it actually displays.
  -- The pixels are already transmitted, so this is just a cheap placement.
  if image._portrait_suppress then
    image._portrait_suppress[img.internal_id] = nil
  end
  img.is_rendered = false
  -- Tell the image.lua patch the exact cell box to scale into: the pane itself, so
  -- the portrait fills it (image.nvim would otherwise aspect-fit/clamp it smaller).
  image._portrait_box = { cols = w, rows = h }
  -- Repaint as ONE synchronized-output frame: delete every existing placement, then
  -- draw the current pose. Wrapping both in DEC mode 2026 means the terminal buffers
  -- the whole sequence and presents it atomically -- the blank moment between the
  -- delete and the redraw is never shown, so there's no flicker -- while the global
  -- delete guarantees no stacked/orphaned placements survive. img:render() emits its
  -- own 2026 wrapper internally, so we open sync, delete, render, and close sync
  -- ourselves (the extra trailing 2026l is a harmless no-op that also ensures sync is
  -- closed even if render is skipped). is_rendered was cleared above so the draw is a
  -- real (placement-only, pixels already transmitted) repaint, not a no-op.
  local ok2, helpers = pcall(require, 'image/backends/kitty/helpers')
  local sync = ok2 and helpers.update_sync_start ~= nil
  if sync then
    pcall(helpers.update_sync_start)
  end
  kitty_delete_all()
  state.img = img
  pcall(function()
    img:render()
  end)
  if sync then
    pcall(helpers.update_sync_end)
  end
  kitty_warm() -- transmit the remaining poses in the background
  return true
end

-- KITTY pre-warm: transmit every pose for the current pane size up front so the
-- FIRST visit to any angle is a flash-free placement, not a base64 transmit stall
-- over SSH. The display is suppressed during the warm (plugins/image.lua honors
-- _portrait_suppress), so poses transmit without flashing over the visible one.
-- One pose per tick, yielding between ticks; clear_kcache() resets it so a resize
-- starts a fresh pass.
local function kitty_warm_tick()
  if not (M.config.prewarm and M.config.backend == 'kitty' and state.active) then
    state.kwarm = false
    return
  end
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    state.kwarm = false
    return
  end
  local ok, image = pcall(require, 'image')
  if not ok then
    state.kwarm = false
    return
  end
  local win = state.square
  local w = api.nvim_win_get_width(win)
  local h = api.nvim_win_get_height(win)
  for pi = 0, M.config.pitch_steps - 1 do
    for yi = 0, M.config.yaw_steps - 1 do
      local key = frame_key(yi, pi, w, h)
      if not state.kcache[key] then
        local path = atlas_path(yi, pi)
        if vim.fn.filereadable(path) == 1 then
          local img = image.from_file(path, { id = 'portrait_' .. key, window = win, x = 0, y = 0, width = w, height = h })
          if img then
            state.kcache[key] = img
            -- Suppress this pose's DISPLAY (by id) so the render only transmits;
            -- the id stays suppressed (across the async resize/re-render) until the
            -- pose is actually visited, which clears it (see render_kitty).
            image._portrait_suppress = image._portrait_suppress or {}
            image._portrait_suppress[img.internal_id] = true
            pcall(function()
              img:render()
            end)
          end
        end
        vim.defer_fn(kitty_warm_tick, M.config.warm_interval) -- next pose
        return
      end
    end
  end
  state.kwarm = false -- every pose for this size is transmitted
end

kitty_warm = function()
  if state.kwarm or not (M.config.prewarm and M.config.backend == 'kitty') then
    return
  end
  state.kwarm = true
  vim.defer_fn(kitty_warm_tick, M.config.warm_interval)
end

-- DEBUG renderer: the pose + angles card. Also the fallback when a backend is
-- missing; it owns its own float surface.
local function render_debug(yi, pi)
  local h = ensure_float()
  if not h then
    return
  end
  local w = api.nvim_win_get_width(h.win)
  local rows = api.nvim_win_get_height(h.win)
  local lines = {
    'portrait :: ' .. M.config.backend,
    '',
    string.format('pose  %d,%d', yi, pi),
    string.format('yaw   %+.0f°', angle(yi, M.config.yaw_steps, M.config.max_yaw)),
    string.format('pitch %+.0f°', angle(pi, M.config.pitch_steps, M.config.max_pitch)),
    '',
    'move the mouse →',
  }
  local out = {}
  local top = math.max(0, math.floor((rows - #lines) / 2))
  for _ = 1, top do
    out[#out + 1] = ''
  end
  for _, l in ipairs(lines) do
    local pad = math.max(0, math.floor((w - vim.fn.strdisplaywidth(l)) / 2))
    out[#out + 1] = string.rep(' ', pad) .. l
  end
  pcall(api.nvim_buf_set_lines, h.buf, 0, -1, false, out)
end

-- The render seam: pick a backend, falling back to the debug card.
function M.render_pose(yi, pi)
  if M.config.backend == 'kitty' and render_kitty(yi, pi) then
    return
  end
  if M.config.backend == 'image' and render_image(yi, pi) then
    return
  end
  render_debug(yi, pi)
end

-- Repaint only when the chosen pose actually changed (the grid throttles us).
local function update(force)
  if not (state.active and state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  -- 'kitty' renders into the square window itself; the other backends use a float.
  if M.config.backend ~= 'kitty' and not ensure_float() then
    return
  end
  local yi, pi = pose_for_cursor()
  if not force and state.pose and state.pose[1] == yi and state.pose[2] == pi then
    return
  end
  state.pose = { yi, pi }
  M.render_pose(yi, pi)
end

-- square sizing ------------------------------------------------------------

-- Keep the middle window a true visual square (rows ~= cols / aspect) and the
-- float pinned over it. Runs on every layout change, so it must be a NO-OP when
-- nothing relevant changed -- otherwise dragging an unrelated border (e.g. the
-- bottom-left terminal) would be fought. Critically it only ever resizes the
-- THREE middle-column panes (never a global `wincmd =`), so other columns are
-- left exactly as the user sized them.
local function hh(win)
  return (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_height(win) or 0
end

local function enforce_square()
  if not (state.square and api.nvim_win_is_valid(state.square)) then
    return
  end
  local w = api.nvim_win_get_width(state.square)
  local target = math.max(3, math.floor(w / M.config.cell_aspect + 0.5))
  -- The three panes share the column; cap the square so tree/empty keep their
  -- minimums on a wide column.
  local col_h = hh(state.tree) + hh(state.square) + hh(state.empty)
  if col_h > 0 then
    target = math.max(3, math.min(target, col_h - M.config.min_tree - M.config.min_empty))
  end

  -- Only restructure when the square isn't already the right height. We set the
  -- tree and empty heights directly (with equalalways off so the change stays in
  -- this column); the square absorbs the remainder to land on `target`.
  if hh(state.square) ~= target and col_h > 0 then
    local remain = math.max(0, col_h - target)
    local empty_h = math.max(M.config.min_empty, math.floor(remain / 2))
    local tree_h = math.max(M.config.min_tree, remain - empty_h)
    local ea = vim.o.equalalways
    vim.o.equalalways = false
    vim.wo[state.square].winfixheight = false
    pcall(api.nvim_win_set_height, state.tree, tree_h)
    pcall(api.nvim_win_set_height, state.empty, empty_h)
    vim.wo[state.square].winfixheight = true
    vim.o.equalalways = ea
  end

  -- Re-pin/re-render only when the square's geometry actually moved or resized
  -- (so unrelated layout events are a true no-op). Works for every backend: the
  -- float is repinned when present, and update() re-renders into square/float.
  local g = float_geometry()
  local sg = state.sgeo
  local changed = not sg or sg.row ~= g.row or sg.col ~= g.col or sg.width ~= g.width or sg.height ~= g.height
  if not changed then
    return
  end
  local size_changed = not state.size or state.size[1] ~= g.width or state.size[2] ~= g.height
  state.sgeo = g
  state.size = { g.width, g.height }
  if size_changed then
    state.cache = {} -- symbols frames are size-specific
    clear_kcache() -- so is the kitty image cache
  end
  if state.float.win and api.nvim_win_is_valid(state.float.win) then
    pcall(api.nvim_win_set_config, state.float.win, g)
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
  -- Plain (non-expr) map: the function runs and the key is consumed, so nothing
  -- is typed. (An <expr> map returning '<Nop>' literally inserted "<Nop>".)
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<MouseMove>', function()
    update(false)
  end, { desc = 'Portrait: follow cursor' })
end

-- Pick the backend when config.backend == 'auto' (defined after reset_float,
-- which it needs); forward-declared so attach can call it.
local resolve_backend

-- Attach the engine to an existing window as the square pane.
function M.attach(square)
  state.square = square
  state.active = true
  vim.wo[square].winbar = '' -- keep the portrait pane clean (no heart banner)
  vim.wo[square].winfixheight = true -- 'equalalways' must not resize the square
  api.nvim_set_hl(0, 'Portrait', { bg = 'NONE', fg = require('baseline.banners').config.fg })
  setup_autocmds()
  vim.schedule(function()
    resolve_backend() -- pick kitty/image before the first paint
    enforce_square() -- sizes the square and renders with the chosen backend
  end)
end

-- Build the three-window middle column inside `center` (assumed empty/current),
-- then attach the engine to the square. Order with splitbelow=true: the window
-- we start in stays on top, each :split drops a new window below it.
function M.setup_center(center)
  api.nvim_set_current_win(center)
  vim.cmd('split') -- middle (square)
  local square = api.nvim_get_current_win()
  local sbuf = scratch()
  api.nvim_win_set_buf(square, sbuf)
  vim.cmd('split') -- bottom (empty)
  local empty = api.nvim_get_current_win()
  local ebuf = scratch()
  api.nvim_win_set_buf(empty, ebuf)
  -- Tag both as 'portrait' so lualine skips their winbar (disabled_filetypes in
  -- plugins/ui.lua) -- otherwise the empty pane's heart-banner winbar reads as a
  -- separator line directly beneath the portrait.
  vim.bo[sbuf].filetype = 'portrait'
  vim.bo[ebuf].filetype = 'portrait'
  blank_win(square) -- the portrait sits under a float, but blank it too for safety
  blank_win(empty) -- removes the stray line-number '1' under the portrait

  -- Top window gets the file tree.
  api.nvim_set_current_win(center)
  require('nvim-tree.api').tree.open({ current_window = true })

  state.tree, state.empty = center, empty
  M.attach(square)
  api.nvim_set_current_win(square)
end

-- Tear down the float (and its terminal) so the next update() rebuilds it. Used
-- when switching backends, since an 'image' float is a terminal buffer that the
-- 'debug' renderer can't write text into.
local function reset_float()
  local h = state.float
  if h.win and api.nvim_win_is_valid(h.win) then
    pcall(api.nvim_win_close, h.win, true)
  end
  h.win, h.buf, h.chan, h.term_buf = nil, nil, nil, nil
  if state.img then
    pcall(function()
      state.img:clear()
    end)
    state.img = nil
  end
  clear_kcache()
  state.pose = nil
  -- Drop cached frames + geometry too, so a rebuilt atlas (e.g. after swapping the
  -- model) or a backend switch is picked up without restarting.
  state.cache = {}
  state.size = nil
  state.sgeo = nil
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
-- works over SSH (the real terminal is queried) and never disturbs the display
-- (the query draws nothing).
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

-- NOTE on sizing: over SSH the kernel can't report the terminal's pixel size
-- (TIOCGWINSZ gives 0), so image.nvim assumes 8x16-px cells and would draw the
-- portrait bitmap at that size -- smaller than WezTerm's real cells, leaving the
-- pane letterboxed. We can't probe the real pixel size (Neovim doesn't surface
-- the CSI 16t reply), but we don't need to: plugins/image.lua patches the kitty
-- backend to send the pane's CELL count (c=cols, r=rows) so the terminal scales
-- the image into the cell box we already know -- filling the pane at any cell px.

-- Resolve config.backend == 'auto' to 'kitty' or 'image'. Defaults to 'image'
-- immediately (so something shows at once) and upgrades to 'kitty' if detected.
resolve_backend = function()
  if M.config.backend ~= 'auto' then
    return
  end
  if env_kitty() then
    M.config.backend = 'kitty'
    reset_float()
    update(true)
    return
  end
  M.config.backend = 'image' -- safe default while we probe
  reset_float()
  update(true)
  probe_kitty(function(ok)
    if ok and M.config.backend == 'image' then
      M.config.backend = 'kitty'
      reset_float()
      update(true)
    end
  end)
end

function M.setup()
  M.config.atlas_dir = M.config.atlas_dir or (vim.fn.stdpath('config') .. '/portrait/atlas')
  api.nvim_create_user_command('Portrait', function(opts)
    if opts.args == 'auto' then
      M.config.backend = 'auto'
      resolve_backend()
      vim.notify('Portrait backend: auto -> ' .. M.config.backend)
    elseif opts.args == 'kitty' or opts.args == 'debug' or opts.args == 'image' then
      M.config.backend = opts.args
      reset_float()
      update(true)
      vim.notify('Portrait backend: ' .. M.config.backend)
    elseif opts.args == 'rebuild' then
      reset_float()
      update(true)
    else
      -- Build the panes from the current window, for ad-hoc testing.
      M.setup_center(api.nvim_get_current_win())
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'auto', 'kitty', 'image', 'debug', 'rebuild' }
    end,
  })
end

return M
