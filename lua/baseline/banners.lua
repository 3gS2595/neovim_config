-- ASCII-art "banner" separators between panes.
--
-- Every banner is made of four independently-customizable parts:
--
--     start  ->  filler filler ... filler  ->  middle  ->  filler ... filler  ->  end
--     (static)         (repeats to fill)      (centerpiece)   (repeats to fill)   (static)
--
--   * Horizontal dividers (pane tops) -> the parts laid left-to-right, filling
--     the window width, rendered on the native winbar (baseline.winbar calls
--     M.winbar() via baseline.panetabs' own fallback).
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

-- Winbar fallback for untagged panes (baseline.panetabs.winbar): fill `win`
-- (current window if omitted), leaving `reserve` columns for that caller's own
-- leading section (diagnostics/navic).
function M.winbar(win)
  win = win or 0
  local w = api.nvim_win_get_width(win) - M.config.reserve
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

-- ---------------------------------------------------------------------------
-- Edge windows (the outer left/right frame)
-- ---------------------------------------------------------------------------
--
-- The outer frame used to be two 1-column floats at column 0 and the last
-- column -- but the screen edges have no reserved column (unlike the interior
-- separators, which sit on columns Neovim reserves between windows), so those
-- floats COVERED pane content: the first column of the leftmost panes and the
-- last column of the rightmost (Claude) pane. Same class of bug as the tab row
-- that covered buffer line 1, and the same cure: give the frame REAL cells.
-- Each edge is a genuine width-1 window (top-level split, winfixwidth) showing
-- a column of hearts, so pane content truly starts inside the frame. The
-- separator column Neovim adds between an edge window and its neighbour is
-- left blank (fillchars vert=' ', and the vsep loop skips it) -- a deliberate
-- 1-column breathing gap between frame and content. Bonus: a real window sits
-- BESIDE the kitty portrait panes instead of floating OVER them, so the left
-- frame no longer needs to skip the portrait rows and is continuous for the
-- first time.
local edge = { left = nil, right = nil }

local function is_edge(win)
  local ok, tag = pcall(api.nvim_win_get_var, win, 'banner_edge')
  return ok and tag == true
end

local function destroy_edge(side)
  local win = edge[side]
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  edge[side] = nil
  if side == 'left' then
    edge.left_from = nil
  end
end

-- Blank the left edge's hearts ABOVE editor row `from` (0-based). The portrait
-- squares at the top of the tree column keep a clean top and left edge -- the
-- frame "begins" at the tree box's top corner (the seam row, where the tree's
-- heart cap meets it) and runs down from there. Buffer line i renders at
-- editor row i: the edge window sits at row 1, just below the tabline.
local function paint_left_edge(from)
  local win = edge.left
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  if edge.left_from == from then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  local lines = {}
  for i = 1, 500 do
    lines[i] = i < from and '' or '♡'
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  edge.left_from = from
end

local function destroy_edges()
  destroy_edge('left')
  destroy_edge('right')
end

local function make_edge(side)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local hearts = {}
  for i = 1, 500 do -- far more rows than any screen; EOB '~' never shows
    hearts[i] = '♡'
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, hearts)
  vim.bo[buf].modifiable = false
  -- Top-level split (win = -1): a full-height column at the frame's far edge.
  -- Not noautocmd: the WinNew/WinResized this fires is what tells panetabs and
  -- the winbar to reposition for the shifted pane columns.
  local ok, win = pcall(api.nvim_open_win, buf, false, {
    split = side, -- 'left' | 'right'
    win = -1,
    width = 1,
  })
  if not ok then
    return nil
  end
  api.nvim_win_set_var(win, 'banner_edge', true)
  local wo = vim.wo[win]
  wo.winfixwidth = true
  wo.winbar = ''
  wo.winhighlight = 'Normal:BannerVSep,NormalNC:BannerVSep'
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.statuscolumn = ''
  wo.wrap = false
  wo.scrolloff = 0
  wo.sidescrolloff = 0
  wo.cursorline = false
  return win
end

-- Create/repair the edge windows. A plugin split with :topleft/:botright
-- (nvim-tree re-opened by hand, say) can slide inside them -- if an edge is no
-- longer at its extreme column, rebuild it. No-op while the cmdline window is
-- open (splits are forbidden there).
local function ensure_edges()
  if vim.fn.getcmdwintype() ~= '' then
    return
  end
  if not (overlay.enabled and M.config.border) then
    destroy_edges()
    return
  end
  if edge.left and api.nvim_win_is_valid(edge.left) and api.nvim_win_get_position(edge.left)[2] ~= 0 then
    destroy_edge('left')
  end
  if
    edge.right
    and api.nvim_win_is_valid(edge.right)
    and api.nvim_win_get_position(edge.right)[2] ~= vim.o.columns - 1
  then
    destroy_edge('right')
  end
  if not (edge.left and api.nvim_win_is_valid(edge.left)) then
    edge.left = make_edge('left')
    edge.left_from = edge.left and 1 or nil -- fresh window is hearts from row 1
  end
  if not (edge.right and api.nvim_win_is_valid(edge.right)) then
    edge.right = make_edge('right')
  end
end

-- Columns the frame takes out of the tiling: 2 heart columns + the 2 blank
-- separator columns beside them. baseline.layout subtracts this when sizing
-- the Claude pane so the left area keeps its fastfetch-fitted width.
function M.edge_overhead()
  if overlay.enabled and M.config.border then
    return 4
  end
  return 0
end

local function redraw()
  overlay.busy = true
  clear_overlay()
  if overlay.enabled then
    -- pcall: creating a split fires WinNew synchronously, and a third-party
    -- handler that errors must not leave overlay.busy stuck.
    pcall(ensure_edges)
    local c = M.config

    -- Snapshot every non-floating window's rectangle up front, so a separator can
    -- tell what sits directly BELOW its bottom edge: a wider pane spanning ACROSS
    -- its column (a horizontal divider it should meet), versus just the next pane
    -- stacked in the same column (whose own separator already continues the line).
    local rects = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' and not is_edge(win) then
        local pos = api.nvim_win_get_position(win)
        rects[#rects + 1] = {
          top = pos[1],
          left = pos[2],
          width = api.nvim_win_get_width(win),
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

    -- The separator columns beside the edge windows stay BLANK (the breathing
    -- gap between frame and content): skip the edge windows themselves (left
    -- gap) and any separator whose right-hand neighbour is the right edge
    -- window (right gap).
    local rgap = edge.right
      and api.nvim_win_is_valid(edge.right)
      and api.nvim_win_get_position(edge.right)[2] - 1
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' and not is_edge(win) then
        local pos = api.nvim_win_get_position(win)
        local col = pos[2] + api.nvim_win_get_width(win)
        -- Only windows with a neighbour to the right have a separator.
        if col < vim.o.columns and col ~= rgap then
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
          -- (Top-edge panes sit at row 1, below the always-on tabline. Their
          -- winbar is the heart tab-fill row -- baseline.panetabs draws the tab
          -- TITLE row there -- so the separator already begins on the heart line;
          -- the ╭──╮ tab-tops overlay lives above it on the tabline row, which
          -- stays clear of separator glyphs.)
          -- If a wider pane sits below this separator spanning across its column
          -- (e.g. the full-width bottom terminal under the tree|code split), the
          -- vertical line otherwise dies a row short of that pane's horizontal
          -- heart divider -- across the inter-window divider row (which carries
          -- that pane's ╭──╮ tab-tops overlay) and onto its winbar, where a
          -- 2-row tab puts the heart FILL. Extend the separator down onto that
          -- heart row so the two meet on the same line, and lift it above the
          -- pane-tab overlay so the heart shows at the crossing.
          local zindex
          local w = pane_below(bottom, col)
          if w then
            bottom = math.min(w.top, last)
            zindex = 36
          end
          draw_one(top + c.v_row_offset, col, bottom - top + 1 + c.v_height_offset, zindex)
        end
      end
    end

    -- Outer window-edge frame: the left/right heart columns are the REAL edge
    -- windows (see ensure_edges above), so they never cover pane content the
    -- way the old col-0 / last-col floats did. The bottom row is the
    -- heart-filled status line; the top is the tab rows. Only the file-tree
    -- box seams still need floats here.
    if c.border then
      -- The leftmost CONTENT column (the tree/portrait column): just inside
      -- the left edge window and its blank gap column.
      local content_left = (edge.left and api.nvim_win_is_valid(edge.left)) and 2 or 0

      -- Portrait rows in the left column: a float on top of a kitty graphics
      -- placement makes some terminals (notably WezTerm over SSH) drop the
      -- image entirely -- the tree-box seam row below must never land on one.
      local skip = {}
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == '' then
          local pos = api.nvim_win_get_position(win)
          if pos[2] == content_left then
            local buf = api.nvim_win_get_buf(win)
            if vim.bo[buf].filetype == 'portrait' then
              local hgt = api.nvim_win_get_height(win)
              skip[#skip + 1] = { top = pos[1], bot = pos[1] + hgt - 1 }
            end
          end
        end
      end

      -- File-tree box. The tree sits directly below the portrait in the left
      -- column, and directly above the bottom terminal that spans the whole left
      -- area -- the interior loop's own separator for the tree (extended down via
      -- pane_below) already meets that terminal, so there is no bottom seam to
      -- close here and deliberately no bottom heart row: the tree runs straight
      -- into the terminal with no divider between them. Only the TOP seam (between
      -- the portrait and the tree) is left open by the per-window loop -- add a
      -- heart row there so the box closes at the top.
      --
      -- Draw on the blank inter-window divider row just above the tree (top-1)
      -- when one exists, so we cover the gap rather than eat a tree line. If the
      -- portrait abuts the tree with no divider, fall back onto the tree's own top
      -- row -- never onto a portrait row, where a float would drop the kitty head.
      -- Span just the tree's own columns: the vertical connector below owns the
      -- separator column at its right edge, so the heart row must STOP one short
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
      -- The left edge's hearts start at the tree box's top corner (seam row),
      -- so the portrait squares above it get no left border. Falls back to the
      -- full column (row 1) when there is no tree to anchor to.
      local ledge_from = 1
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if
          api.nvim_win_is_valid(win)
          and api.nvim_win_get_config(win).relative == ''
          and api.nvim_win_get_position(win)[2] == content_left
          and vim.bo[api.nvim_win_get_buf(win)].filetype == 'NvimTree'
        then
          local pos = api.nvim_win_get_position(win)
          local tw = api.nvim_win_get_width(win)
          local top_row = in_portrait(pos[1] - 1) and pos[1] or pos[1] - 1
          if top_row >= 0 then
            -- Start at column 0 so the row runs from the edge window's own
            -- heart, across the blank gap column, along the tree's top -- one
            -- unbroken cap whose left end IS the frame corner.
            draw_hrow(top_row, 0, content_left + tw, 36)
            ledge_from = math.max(1, top_row)
          end
          -- Close the tree box's top-right corner. The tree|code separator is
          -- otherwise drawn only from the tree's own top row down (the interior
          -- loop gives the portrait and the tree separators over their OWN rows
          -- only), so the divider row between them (the tree's top seam row) is
          -- left uncovered and the heart row above would hit a void at the corner.
          -- Draw a vertical at the tree's right-edge column spanning just that
          -- seam gap (a no-op when the portrait abuts the tree with no gap row).
          local sep = pos[2] + tw
          if top_row >= 0 then
            draw_one(top_row, sep, pos[1] - top_row, 36)
          end
          break
        end
      end
      paint_left_edge(ledge_from)
    end
  else
    destroy_edges()
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

  -- The edge windows are chrome, not places to land: bounce focus off them
  -- (wincmd hjkl, mouse clicks, wincmd w cycling) back to the last real window,
  -- falling back to any non-edge split if 'previous' is an edge too.
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not is_edge(win) then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_get_current_win() ~= win then
          return -- something else already moved focus
        end
        vim.cmd('wincmd p')
        if is_edge(vim.api.nvim_get_current_win()) then
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(w).relative == '' and not is_edge(w) then
              vim.api.nvim_set_current_win(w)
              break
            end
          end
        end
      end)
    end,
  })

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
