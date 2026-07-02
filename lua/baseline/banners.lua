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

  -- Draw an outer heart frame on the window-facing pane edges (left column,
  -- right column, bottom row) so every edge pane closes into a rectangle. The
  -- top is left to the tab/banner row, which already caps the top panes.
  border = true,

  -- Foreground colour for everything.
  fg = '#ff5f87',
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

local function draw_one(row, col, height, zindex)
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
    -- 30 keeps separators below typical plugin floats (telescope/noice) so those
    -- cover us; a junction float is bumped to 36 (just above the pane-tab overlay
    -- at 35) so its heart wins at the crossing column. Both stay below plugins.
    zindex = zindex or 30,
    style = 'minimal',
    noautocmd = true, -- creating the float must not retrigger our own redraw
  })
  if ok then
    vim.wo[win].winhighlight = 'Normal:BannerVSep,NormalNC:BannerVSep'
    overlay.wins[#overlay.wins + 1] = win
  end
end

-- A horizontal heart-fill row (the bottom window-edge border): '♡ ' tiled to
-- `width` display columns, drawn as a 1-row float -- the horizontal counterpart
-- of draw_one. The verticals (solid hearts) cross it at the corners.
local function draw_hrow(row, col, width, zindex)
  if width < 1 then
    return
  end
  local line = string.rep('♡ ', math.floor(width / 2))
  if width % 2 == 1 then
    line = line .. '♡'
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  local ok, win = pcall(api.nvim_open_win, buf, false, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = 1,
    focusable = false,
    zindex = zindex or 36,
    style = 'minimal',
    noautocmd = true,
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

    -- Snapshot every non-floating window's rectangle up front, so a separator can
    -- tell what sits directly BELOW its bottom edge: a wider pane spanning ACROSS
    -- its column (a horizontal divider it should meet), versus just the next pane
    -- stacked in the same column (whose own separator already continues the line).
    local rects = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' then
        local pos = api.nvim_win_get_position(win)
        rects[#rects + 1] = {
          top = pos[1],
          left = pos[2],
          width = api.nvim_win_get_width(win),
          winbar = api.nvim_get_option_value('winbar', { win = win }) ~= '',
        }
      end
    end

    -- The pane that the separator ending at `row`, column `col` runs into below.
    -- Take the NEAREST window beneath whose horizontal span reaches `col` (a same-
    -- column neighbour has `col` as its own right edge; a wider pane contains it).
    -- Only a wider one (col strictly inside) is a horizontal divider crossing our
    -- column -- a same-column neighbour just continues the line via its own
    -- separator, so return nil for it (and for the screen edge).
    local function pane_below(row, col)
      local best
      for _, r in ipairs(rects) do
        if r.top > row and r.left <= col and col <= r.left + r.width then
          if not best or r.top < best.top then
            best = r
          end
        end
      end
      if best and col < best.left + best.width then
        return best
      end
      return nil
    end

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
          -- At the editor's top edge the neighbouring panes open with a 2-row tab
          -- whose heart-fill divider is the SECOND row (the first is just the tab
          -- tops, ╭──╮). Drop this separator's first row so it begins on that heart
          -- line and meets the horizontal tab there, rather than poking a lone glyph
          -- up beside the tab tops. (Only separators touching row 0 -- the ones
          -- bordering the top tabs -- not the stacked tree-column ones.)
          if pos[1] == 0 then
            top = top + 1
          end
          -- If a wider pane sits below this separator spanning across its column
          -- (e.g. the full-width bottom terminal under the tree|code split), the
          -- vertical line otherwise dies a few rows short of that pane's
          -- horizontal heart divider -- across the blank inter-window divider row
          -- and the pane's own winbar (a 2-row tab puts the heart FILL on its
          -- overlay row, = winbar + 1). Extend the separator down onto that heart
          -- row so the two meet on the same line, and lift it above the pane-tab
          -- overlay so the heart shows at the crossing.
          local zindex
          local w = pane_below(bottom, col)
          if w then
            local heart = w.winbar and (w.top + 1) or w.top
            bottom = math.min(heart, last)
            zindex = 36
          end
          draw_one(top + c.v_row_offset, col, bottom - top + 1 + c.v_height_offset, zindex)
        end
      end
    end

    -- Outer window-edge border: close every edge-facing pane into a heart
    -- rectangle. Left & right are solid heart columns (like the interior
    -- separators). The bottom row is NOT drawn here: it is the lualine status
    -- line, whose middle is heart-filled (see heart_fill in plugins/ui.lua), so
    -- the status line and the bottom separator are the same row. The verticals
    -- therefore run all the way DOWN ONTO that status-line row (last = the very
    -- bottom row, not one above it) so the frame closes onto the heart line at the
    -- bottom corners. The TOP is intentionally left to the tab/banner row (its
    -- heart line already caps the top panes); both verticals start at row 1 --
    -- matching the interior separators' top trim -- so they meet the tab cap at
    -- the top corners. Drawn at 36 (above pane content AND the pane-tab overlays)
    -- so the frame stays unbroken over the terminals.
    if c.border then
      local cols = vim.o.columns
      local last = vim.o.lines - 1

      -- The left edge (col 0) runs over the kitty PORTRAIT panes. A float on top
      -- of a kitty graphics placement makes some terminals (notably WezTerm over
      -- SSH) drop the image entirely, blanking the head -- so split the left border
      -- to SKIP those panes' rows, leaving the portrait squares untouched (their
      -- own image edge stands in for the border there). Right & bottom never cross
      -- a portrait, so they stay whole.
      local skip = {}
      local term_top -- top row of the bottom-left terminal pane (col 0), if any
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' then
          local pos = api.nvim_win_get_position(win)
          if pos[2] == 0 then
            local buf = api.nvim_win_get_buf(win)
            if vim.bo[buf].filetype == 'portrait' then
              local hgt = api.nvim_win_get_height(win)
              skip[#skip + 1] = { top = pos[1], bot = pos[1] + hgt - 1 }
            elseif vim.bo[buf].buftype == 'terminal' then
              term_top = pos[1]
            end
          end
        end
      end
      table.sort(skip, function(a, b)
        return a.top < b.top
      end)
      local r = 1 -- next un-drawn row of the left edge
      for _, s in ipairs(skip) do
        if s.top > r then
          draw_one(r, 0, s.top - r, 36) -- segment above this portrait
        end
        r = math.max(r, s.bot + 1)
      end
      if r <= last then
        -- If the bottom-left pane is the terminal, start the edge on its heart
        -- tab row (winbar + 1) rather than at the top of its 2-row tab, so the
        -- left vertical meets the horizontal tab divider at the corner instead
        -- of poking up past it through the ╭──╮ tab-tops row above.
        local seg_top = r
        if term_top and term_top + 1 > seg_top then
          seg_top = term_top + 1
        end
        if seg_top <= last then
          draw_one(seg_top, 0, last - seg_top + 1, 36) -- segment below the last portrait
        end
      end

      draw_one(1, cols - 1, last, 36) -- right edge (last column), rows 1..last
      -- No bottom edge row: the heart-filled status line is the bottom separator.

      -- File-tree box. The tree sits sandwiched between the two portraits in the
      -- left column; the outer frame above already gives it a left edge (the col 0
      -- segment drawn between the portraits) and the interior loop draws its right
      -- edge (the tree|code separator), but its top and bottom seams are open. Add
      -- a heart row across each so the tree closes into a rectangle while the
      -- portraits stay open (separators only where they meet another pane).
      --
      -- Draw on the blank inter-window divider row just outside the tree (top-1 /
      -- bottom+1) when one exists, so we cover the gap rather than eat a tree line.
      -- If a portrait abuts the tree with no divider, fall back onto the tree's own
      -- edge row -- never onto a portrait row, where a float would drop the kitty
      -- head. Span just the tree's own columns (0..tw-1): the vertical connector
      -- below owns the separator column (tw), so the heart row must STOP one short
      -- of it -- the row tiles "♡ " and its blank cell would otherwise land on the
      -- separator column and overwrite the connector's heart at the corner.
      local function in_portrait(row)
        for _, s in ipairs(skip) do
          if row >= s.top and row <= s.bot then
            return true
          end
        end
        return false
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if
          api.nvim_win_is_valid(win)
          and api.nvim_win_get_config(win).relative == ''
          and api.nvim_win_get_position(win)[2] == 0
          and vim.bo[api.nvim_win_get_buf(win)].filetype == 'NvimTree'
        then
          local pos = api.nvim_win_get_position(win)
          local tw = api.nvim_win_get_width(win)
          local th = api.nvim_win_get_height(win)
          local top_row = in_portrait(pos[1] - 1) and pos[1] or pos[1] - 1
          local bot_row = in_portrait(pos[1] + th) and (pos[1] + th - 1) or (pos[1] + th)
          if top_row >= 0 then
            draw_hrow(top_row, 0, tw, 36)
          end
          if bot_row <= last then
            draw_hrow(bot_row, 0, tw, 36)
          end
          -- Close the tree box's right side. The tree|code separator is otherwise
          -- drawn only piecewise -- the interior loop gives each stacked tree-column
          -- window (portrait / tree / portrait) a separator over its OWN rows only,
          -- so the two divider rows between them (= the tree's top and bottom seam
          -- rows) are left uncovered and the heart rows hit a void at the corner.
          -- Draw one continuous vertical at the tree's right-edge column (tw)
          -- spanning both seam rows. The heart rows stop at tw-1, so this column
          -- is the connector's alone -- its solid hearts fill the corners with no
          -- blank cell from the heart-row tiling to overwrite them.
          local sep = pos[2] + tw
          local v_top = math.max(0, top_row)
          local v_bot = math.min(bot_row, last)
          if v_bot >= v_top then
            draw_one(v_top, sep, v_bot - v_top + 1, 36)
          end
          break
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
  vim.api.nvim_set_hl(0, 'WinSeparator', { fg = M.config.fg, bg = 'NONE', bold = true })
  vim.api.nvim_set_hl(0, 'BannerVSep', { fg = M.config.fg, bg = 'NONE', bold = true })
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
