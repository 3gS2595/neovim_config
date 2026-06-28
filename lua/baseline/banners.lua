-- ASCII-art "banner" separators between panes.
--
-- Every banner is made of four independently-customizable parts:
--
--     start  ->  filler filler ... filler  ->  middle  ->  filler ... filler  ->  end
--     (static)         (repeats to fill)      (centerpiece)   (repeats to fill)   (static)
--
--   * Horizontal dividers (pane tops) -> the parts laid left-to-right, filling
--     the window width, rendered on the lualine winbar (wiring in
--     lua/plugins/ui.lua, which calls M.winbar()).
--   * Vertical separators (side-by-side panes) -> the SAME four parts stacked
--     top-to-bottom. 'fillchars' only paints one cell, so there is no native
--     way to do this; instead we draw a 1-column floating window over each
--     separator (the "overlay" below). This is a hack: the floats are
--     repositioned on every layout change, and row alignment vs the winbar may
--     need a nudge via v_row_offset / v_height_offset. Toggle with :BannerVSep.
--
-- >>> TO CHANGE THE PATTERN, edit M.config just below. <<<
--   Horizontal parts are strings (h_start/h_filler/h_middle/h_end).
--   Vertical parts are lists of single-cell glyphs, one per row
--   (v_top/v_filler/v_middle/v_bot). Set a part to '' or {} to omit it.

local api = vim.api
local M = {}

M.config = {
  -- Horizontal banner parts (strings).
  h_start = ' ♡ ',
  h_middle = ' ♡ ', -- centerpiece, kept in the middle ('' to omit)
  h_filler = ' ♡ ', -- repeated on both sides of the centerpiece
  h_middle = ' ♡ ', -- centerpiece, kept in the middle ('' to omit)
  h_end = ':⋆ .⋆',
  -- Columns kept free for the winbar's own sections when filling the banner.
  reserve = 30,

  -- Vertical banner parts (lists; each entry MUST be a single display cell,
  -- because a 1-column float clips wider glyphs).
  v_top = {'♡' }, -- static top sequence
  v_filler ={'♡'}, -- repeated above and below the centerpiece
  v_middle = {'♡'}, -- centerpiece, centered vertically ({} to omit)
  v_bot = {'♡'}, -- static bottom sequence
  -- Single glyph for the NATIVE vertical line when the overlay is off (fallback).
  v_glyph = '⋆',
  -- Manual alignment nudges if the overlay sits a row off from the separator.
  v_row_offset = 0,
  v_height_offset = 0,

  -- Foreground colour for everything.
  fg = '#be19e8',
}

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

-- Build a horizontal banner that fits within `width` display columns: static
-- start/end, the centerpiece kept in the middle, filler repeated on each side.
function M.build(width)
  local c = M.config
  local sw, ew, mw, fw = dw(c.h_start), dw(c.h_end), dw(c.h_middle), dw(c.h_filler)
  local avail = width - sw - ew - mw
  if avail < 0 then
    -- Not even room for the fixed parts: show the start if it fits, else nothing.
    return width >= sw and c.h_start or ''
  end
  local reps = fw > 0 and math.floor(avail / fw) or 0
  local left = math.floor(reps / 2)
  return c.h_start
    .. string.rep(c.h_filler, left)
    .. c.h_middle
    .. string.rep(c.h_filler, reps - left)
    .. c.h_end
end

-- lualine winbar component: fill the current window, leaving `reserve` columns.
function M.winbar()
  local w = api.nvim_win_get_width(0) - M.config.reserve
  return M.build(math.max(0, w))
end

-- ---------------------------------------------------------------------------
-- Vertical overlay
-- ---------------------------------------------------------------------------

-- `busy` guards against the WinClosed events our own teardown fires; `pending`
-- coalesces bursts of layout events into a single scheduled redraw.
local overlay = { enabled = true, wins = {}, busy = false, pending = false }

-- Build the column of glyphs for a separator `height` rows tall: static top and
-- bottom, the centerpiece centered, filler cycled to fill the space between.
local function vsep_lines(height)
  local c = M.config
  local lines = {}
  local function emit(list)
    for _, g in ipairs(list) do
      lines[#lines + 1] = g
    end
  end
  local fill_rows = math.max(0, height - #c.v_top - #c.v_middle - #c.v_bot)
  local left = math.floor(fill_rows / 2)
  local function emit_filler(n)
    for i = 0, n - 1 do
      lines[#lines + 1] = c.v_filler[(i % #c.v_filler) + 1]
    end
  end

  emit(c.v_top)
  if #c.v_filler > 0 then
    emit_filler(left)
  end
  emit(c.v_middle)
  if #c.v_filler > 0 then
    emit_filler(fill_rows - left)
  end
  emit(c.v_bot)

  while #lines > height do -- tiny windows: drop the overflow tail
    table.remove(lines)
  end
  return lines
end

local function clear_overlay()
  for _, w in ipairs(overlay.wins) do
    if api.nvim_win_is_valid(w) then
      pcall(api.nvim_win_close, w, true)
    end
  end
  overlay.wins = {}
end

local function draw_one(row, col, height)
  if height < 1 then
    return
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, vsep_lines(height))
  local ok, win = pcall(api.nvim_open_win, buf, false, {
    relative = 'editor',
    row = row,
    col = col,
    width = 1,
    height = height,
    focusable = false,
    zindex = 30, -- below typical plugin floats (telescope/noice) so they cover us
    style = 'minimal',
    noautocmd = true, -- creating the float must not retrigger our own redraw
  })
  if ok then
    vim.wo[win].winhighlight = 'Normal:BannerVSep,NormalNC:BannerVSep'
    overlay.wins[#overlay.wins + 1] = win
  end
end

local function redraw()
  overlay.busy = true
  clear_overlay()
  if overlay.enabled then
    local c = M.config
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' then
        local pos = api.nvim_win_get_position(win)
        local col = pos[2] + api.nvim_win_get_width(win)
        -- Only windows with a neighbour to the right have a separator.
        if col < vim.o.columns then
          -- pos[1] is the window's TOP row -- already the winbar row when the
          -- window has a winbar (text sits one below), so the separator starts
          -- right there. The old code subtracted a row here on the assumption
          -- pos[1] was the text row; that drew every winbar pane a row too high
          -- (onto the tabline) and a row short at the bottom, and misaligned it
          -- against winbar-less panes like the file tree.
          local top = pos[1]
          local height = api.nvim_win_get_height(win)
          if api.nvim_get_option_value('winbar', { win = win }) ~= '' then
            height = height + 1 -- cover the winbar row above the text
          end
          -- Stop above a global statusline (laststatus=3): nvim_win_get_height
          -- doesn't subtract it, so a bottom-band pane would otherwise spill a
          -- glyph onto the statusline row.
          local last = vim.o.lines - 1 - (vim.o.laststatus == 3 and 1 or 0)
          local bottom = math.min(top + height - 1, last)
          draw_one(top + c.v_row_offset, col, bottom - top + 1 + c.v_height_offset)
        end
      end
    end
  end
  overlay.busy = false
  overlay.pending = false
end

local function schedule_redraw()
  if overlay.busy or overlay.pending then
    return
  end
  overlay.pending = true
  vim.schedule(redraw)
end

function M.enable_overlay(on)
  overlay.enabled = on
  -- Hide the native vertical line when the overlay owns it; restore the
  -- fallback glyph when the overlay is off.
  vim.opt.fillchars:append({ vert = on and ' ' or M.config.v_glyph })
  schedule_redraw()
end

function M.toggle_overlay()
  M.enable_overlay(not overlay.enabled)
end

-- ---------------------------------------------------------------------------

local function apply_hl()
  vim.api.nvim_set_hl(0, 'WinSeparator', { fg = M.config.fg, bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'BannerVSep', { fg = M.config.fg, bg = 'NONE' })
end

function M.setup()
  -- Blank the native horizontal pieces so the winbar banner is the only
  -- horizontal divider; vert is managed by enable_overlay().
  vim.opt.fillchars:append({
    horiz = ' ',
    horizup = ' ',
    horizdown = ' ',
  })

  apply_hl()
  local group = vim.api.nvim_create_augroup('BannerSeparators', { clear = true })
  -- The colorscheme is applied after this runs and repaints our groups.
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply_hl })

  -- Reposition the vertical overlay whenever the window layout can change.
  vim.api.nvim_create_autocmd(
    { 'WinNew', 'WinClosed', 'WinResized', 'VimResized', 'TabEnter', 'BufWinEnter' },
    { group = group, callback = schedule_redraw }
  )

  vim.api.nvim_create_user_command('BannerVSep', function(opts)
    local arg = opts.args
    if arg == 'on' then
      M.enable_overlay(true)
    elseif arg == 'off' then
      M.enable_overlay(false)
    else
      M.toggle_overlay()
    end
  end, {
    nargs = '?',
    complete = function()
      return { 'on', 'off', 'toggle' }
    end,
  })

  M.enable_overlay(overlay.enabled)
end

return M
