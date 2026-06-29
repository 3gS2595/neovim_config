-- Per-pane buffer tabs with a 2-row "classic tab" look.
--
--   Row 1 (winbar):  ╭──────╮╭────╮   <celestial pattern fills the rest>
--   Row 2 (overlay): │ a.lua ×││ b ×│  <celestial pattern fills the rest>
--
-- Row 1 is the winbar (lualine renders each window's winbar via nvim_win_call,
-- so the window being drawn is the current window): the top outline of each
-- tab, plus the heart/celestial separator pattern filling the leftover width.
--
-- Row 2 is a 1-row floating overlay pinned at the pane's first text row (same
-- machinery as the heart separators): the tab sides + title + × close button,
-- plus the pattern fill. The title row carries the clicks (mouse handler on the
-- float) since the winbar can't sit below it.
--
-- Panes are tagged with a window-local role by baseline.layout:
--   'files' -> listed file buffers   (code pane)
--   'terms' -> terminal buffers       (bottom-left terminal pane)
-- Untagged panes fall back to the heart banner in the winbar.

local M = {}

M.config = {
  fg = '#ff5f87', -- inactive tab + pattern fill colour
  active = '#ff6600', -- active tab
  close = '#ff5555', -- × button
  fill = '♡ ', -- repeated to fill row 2 beside the tabs
  -- Row 2 sits at the pane's first text row, directly under the winbar tabs
  -- (nvim_win_get_position's row IS the winbar row, so +1 = first text row).
  row_offset = 1,
  col_offset = 0,
}

local TL, TR, TOP, SIDE, CLOSE = '╭', '╮', '─', '│', '×'

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

-- Truncate/pad `s` to exactly `w` display columns.
local function trunc(s, w)
  local out, used = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = dw(ch)
    if used + cw > w then
      break
    end
    out[#out + 1], used = ch, used + cw
  end
  if used < w then
    out[#out + 1] = string.rep(' ', w - used)
  end
  return table.concat(out)
end

-- The tab fill (M.config.fill), repeated to `w` display columns.
local function pattern(w)
  if w <= 0 then
    return ''
  end
  local f = M.config.fill
  if not f or f == '' then
    return string.rep(' ', w)
  end
  return trunc(f:rep(math.ceil(w / math.max(1, dw(f)))), w)
end

-- Window/buffer tagging -----------------------------------------------------

-- Force a window's role, or false to opt it out of tabs entirely. Optional --
-- roles are normally auto-derived from the buffer (see role_of), so tabs appear
-- on every pane without tagging; this just overrides that.
function M.set_role(win, role)
  pcall(vim.api.nvim_win_set_var, win, 'pane_tabs', role)
end

-- A pane's role is derived from the buffer it currently shows, so tabs appear
-- automatically on every normal pane (and any split opened later):
--   terminal buffer          -> 'terms'  (terminal tabs)
--   normal file buffer ('')  -> 'files'  (file tabs)
--   anything else            -> nil      (no tabs)
-- "Anything else" covers floats (our overlays, telescope, noice) and special
-- buffers -- the file tree, help, quickfix, prompts -- which all carry a
-- non-empty buftype. set_role overrides this (a role string, or false to opt
-- out).
local function role_of(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local ok, override = pcall(vim.api.nvim_win_get_var, win, 'pane_tabs')
  if ok and override ~= nil then
    return override or nil -- string forces a role; false opts out
  end
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return nil
  end
  local bt = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
  if bt == 'terminal' then
    return 'terms'
  end
  if bt ~= '' then
    return nil
  end
  return 'files'
end

function M.exclude_buf(buf)
  pcall(vim.api.nvim_buf_set_var, buf, 'pane_tabs_exclude', true)
end

local function excluded(buf)
  local ok, v = pcall(vim.api.nvim_buf_get_var, buf, 'pane_tabs_exclude')
  return ok and v == true
end

local function buffers_for(role)
  local want = role == 'terms' and 'terminal' or ''
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buflisted
      and vim.bo[b].buftype == want
      and not excluded(b)
    then
      out[#out + 1] = b
    end
  end
  return out
end

local function label(buf, role)
  if role == 'terms' then
    -- Derived from the (stable) buffer name, not b:term_title which a live TUI
    -- rewrites constantly and would make the tab flicker.
    local cmd = vim.api.nvim_buf_get_name(buf):match('//%d+:(.+)$')
    if cmd and cmd ~= '' then
      return vim.fn.fnamemodify((cmd:gsub('%s.*$', '')), ':t'):sub(1, 18)
    end
    return 'term'
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':t')
end

-- Rendering -----------------------------------------------------------------

-- Build both rows for window `win`. Returns:
--   top   : winbar string (row 1, inline %#..# highlights)
--   title : overlay string (row 2, plain text)
--   thl   : {byte0, byte1, group} highlight ranges for the overlay
--   clicks: {d0, d1, x0, x1, buf} display-column ranges per tab (0-based)
local function build(win, role, width)
  local cur = vim.api.nvim_win_get_buf(win)
  local top, title, thl, clicks = {}, {}, {}, {}
  local disp, tb = 0, 0 -- display column / title byte cursor
  for _, b in ipairs(buffers_for(role)) do
    local g = b == cur and 'PaneTabTop' or 'PaneTabTopNC'
    local body = ' ' .. label(b, role) .. ' ' .. CLOSE .. ' ' -- ' name × '
    local bw = dw(body)

    -- Row 1: ╭───────╮
    top[#top + 1] = '%#' .. g .. '#' .. TL .. string.rep(TOP, bw) .. TR

    -- Row 2: │ name × │
    local cell = SIDE .. body .. SIDE
    title[#title + 1] = cell
    thl[#thl + 1] = { tb, tb + #cell, g }
    local xb = tb + #SIDE + #(' ' .. label(b, role) .. ' ') -- byte pos of ×
    thl[#thl + 1] = { xb, xb + #CLOSE, 'PaneTabClose' }

    -- Click ranges (display columns, 0-based)
    local xd = disp + dw(SIDE) + dw(' ' .. label(b, role) .. ' ')
    clicks[#clicks + 1] = { d0 = disp, d1 = disp + bw + 2, x0 = xd, x1 = xd + dw(CLOSE), buf = b }

    disp = disp + bw + 2
    tb = tb + #cell
  end

  -- Fill the leftover width with the celestial pattern (row 2 only).
  local fill = pattern(width - disp)
  if fill ~= '' then
    title[#title + 1] = fill
    thl[#thl + 1] = { tb, tb + #fill, 'PaneTabFill' }
  end

  return table.concat(top) .. '%#WinBar#', table.concat(title), thl, clicks
end

-- Winbar component lualine calls: top-outline row for tagged panes, else banner.
function M.winbar()
  local win = vim.api.nvim_get_current_win()
  local role = role_of(win)
  if role then
    return (build(win, role, vim.api.nvim_win_get_width(win)))
  end
  return require('baseline.banners').winbar()
end

function M.is_tabbed()
  return role_of(vim.api.nvim_get_current_win()) ~= nil
end

-- Closing -------------------------------------------------------------------

function M.close_buf(win, buf, role)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if vim.api.nvim_win_get_buf(win) == buf then
    local others = {}
    for _, b in ipairs(buffers_for(role)) do
      if b ~= buf then
        others[#others + 1] = b
      end
    end
    vim.api.nvim_win_set_buf(win, others[#others] or vim.api.nvim_create_buf(true, false))
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = vim.bo[buf].buftype == 'terminal' })
end

-- Keyboard navigation (Chrome-style) ----------------------------------------
--
-- These act on the tabs of whatever pane is focused -- the same per-pane buffer
-- lists the click router uses -- so the Chrome shortcuts (next/prev, jump-to-N,
-- close, new) drive whichever pane you're in (file pane or terminal pane).

-- The buffers shown as tabs in `win` (display order), the index of the one it
-- currently shows, and the pane's role. nil when `win` isn't a tabbed pane.
local function tabs_of(win)
  local role = role_of(win)
  if not role then
    return nil
  end
  local bufs = buffers_for(role)
  local cur = vim.api.nvim_win_get_buf(win)
  local idx
  for i, b in ipairs(bufs) do
    if b == cur then
      idx = i
      break
    end
  end
  return bufs, idx, role
end

-- Show `buf` in `win`. If it's a terminal and `win` is focused, resume insert so
-- typing keeps working (terminal panes are normally driven from terminal mode).
local function show(win, buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  pcall(vim.api.nvim_win_set_buf, win, buf)
  if vim.bo[buf].buftype == 'terminal' and win == vim.api.nvim_get_current_win() then
    vim.cmd('startinsert')
  end
end

-- Move `delta` tabs (wrapping) within the focused pane: -1 = previous, +1 = next.
function M.nav(delta)
  local win = vim.api.nvim_get_current_win()
  local bufs, idx = tabs_of(win)
  if not bufs or #bufs == 0 or not idx then
    return
  end
  show(win, bufs[((idx - 1 + delta) % #bufs) + 1])
end

-- Jump to the nth tab (1-based) of the focused pane; n == -1 means the last tab.
function M.goto_tab(n)
  local win = vim.api.nvim_get_current_win()
  local bufs = tabs_of(win)
  if not bufs then
    return
  end
  show(win, bufs[n == -1 and #bufs or n])
end

-- Close the focused pane's current tab (Chrome's Ctrl-W).
function M.close_current()
  local win = vim.api.nvim_get_current_win()
  M.close_buf(win, vim.api.nvim_get_current_buf(), role_of(win))
end

-- Open a new tab in the focused pane: a fresh interactive terminal in a terminal
-- pane, otherwise a blank [No Name] file buffer (Chrome's Ctrl-T).
function M.new_tab()
  local win = vim.api.nvim_get_current_win()
  local role = role_of(win)
  if not role then
    return
  end
  if role == 'terms' then
    vim.cmd('terminal')
    vim.cmd('startinsert')
  else
    vim.cmd('enew')
  end
end

-- Row 2 floating overlay (the clickable title row) --------------------------

local uv = vim.uv
local ns = vim.api.nvim_create_namespace('panetabs_title')
local ov = { headers = {}, timer = nil, in_redraw = false } -- cwin -> {win,buf,sig,content,role,clicks}

local function destroy_header(cwin)
  local h = ov.headers[cwin]
  if h then
    if vim.api.nvim_win_is_valid(h.win) then
      pcall(vim.api.nvim_win_close, h.win, true)
    end
    ov.headers[cwin] = nil
  end
end

-- Left-click router for the title floats (wired as ONE global mapping in
-- M.setup). A click is resolved by matching the moused-over window
-- (getmousepos) to a header float, then the click column to that float's tab
-- ranges -- crucially using the window UNDER THE MOUSE, not the focused one.
--
-- This must be global, not a buffer-local map on each float: a buffer-local
-- <LeftMouse> only fires once its buffer is already the current one, so clicking
-- a tab in an *unfocused* pane never triggered that pane's handler -- it acted on
-- whichever pane happened to be focused (the "wrong pane/tab" confusion).
--
-- Returns true when the click landed on one of our floats (so the caller
-- suppresses the default click and we don't focus the 1-row overlay), false to
-- let Neovim handle the click normally.
function M._click()
  local mp = vim.fn.getmousepos()
  local h
  for _, hh in pairs(ov.headers) do
    if hh.win == mp.winid then
      h = hh
      break
    end
  end
  if not h then
    return false -- not one of our floats: default click behaviour
  end
  local col = mp.wincol - 1
  for _, c in ipairs(h.clicks) do
    if col >= c.d0 and col < c.d1 then
      local content, buf, role = h.content, c.buf, h.role
      local close = col >= c.x0 and col < c.x1
      -- Defer the switch: this is called from an <expr> mapping, where changing
      -- the window/buffer is blocked by textlock (E565).
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(content) then
          return
        end
        if close then
          M.close_buf(content, buf, role)
        elseif vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_win_set_buf, content, buf)
        end
        pcall(vim.api.nvim_set_current_win, content) -- focus the clicked pane
      end)
      break
    end
  end
  return true -- our float (even on the empty fill): swallow the default click
end

local function paint(buf, title, thl)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { title })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(thl) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, h[1], { end_col = h[2], hl_group = h[3] })
  end
end

local function update_header(cwin, role)
  local _, title, thl, clicks = build(cwin, role, vim.api.nvim_win_get_width(cwin))
  local pos = vim.api.nvim_win_get_position(cwin)
  local width = vim.api.nvim_win_get_width(cwin)
  local row, col = pos[1] + M.config.row_offset, pos[2] + M.config.col_offset
  if title == '' or width < 2 or row < 0 then
    destroy_header(cwin)
    return
  end
  -- The float is only repainted when this signature changes. Include the pane's
  -- current buffer: switching the active tab moves the active-tab highlight even
  -- though the tab *text* (title) is unchanged, so title alone would skip the
  -- repaint and leave the bottom row's active colour stale. (Row 1's winbar
  -- carries inline highlights, so lualine repaints it every redraw regardless.)
  local sig = table.concat({ row, col, width, vim.api.nvim_win_get_buf(cwin), title }, '|')
  local h = ov.headers[cwin]
  if h and vim.api.nvim_win_is_valid(h.win) then
    h.content, h.role, h.clicks = cwin, role, clicks
    if h.sig ~= sig then
      pcall(vim.api.nvim_win_set_config, h.win, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = 1,
      })
      paint(h.buf, title, thl)
      h.sig = sig
    end
    return
  end
  destroy_header(cwin)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  paint(buf, title, thl)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = 1,
    focusable = true, -- required so getmousepos() resolves clicks to this float
    zindex = 35,
    style = 'minimal',
    noautocmd = true,
  })
  if ok then
    vim.wo[win].winhighlight = 'Normal:PaneTabBar'
    ov.headers[cwin] = { win = win, buf = buf, sig = sig, content = cwin, role = role, clicks = clicks }
    -- Clicks are handled by the single global <LeftMouse> map (see M.setup),
    -- which routes by getmousepos(); a buffer-local map here would only fire
    -- when this float is already focused.
  end
end

local function redraw()
  local seen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == '' and role_of(win) then
      seen[win] = true
      update_header(win, role_of(win))
    end
  end
  for cwin in pairs(ov.headers) do
    if not seen[cwin] then
      destroy_header(cwin)
    end
  end
end

local function schedule()
  if ov.in_redraw or ov.timer then
    return
  end
  ov.timer = uv.new_timer()
  ov.timer:start(
    40,
    0,
    vim.schedule_wrap(function()
      if ov.timer then
        ov.timer:stop()
        pcall(function()
          ov.timer:close()
        end)
        ov.timer = nil
      end
      ov.in_redraw = true
      pcall(redraw)
      ov.in_redraw = false
    end)
  )
end

-- Setup ---------------------------------------------------------------------

local function apply_hl()
  local c = M.config
  vim.api.nvim_set_hl(0, 'PaneTabTop', { fg = c.active, bg = 'NONE', bold = true })
  vim.api.nvim_set_hl(0, 'PaneTabTopNC', { fg = c.fg, bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'PaneTabClose', { fg = c.close, bg = 'NONE', bold = true })
  vim.api.nvim_set_hl(0, 'PaneTabFill', { fg = c.fg, bg = 'NONE', bold = true })
  vim.api.nvim_set_hl(0, 'PaneTabBar', { bg = 'NONE' })
end

function M.setup()
  apply_hl()
  local group = vim.api.nvim_create_augroup('PaneTabs', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      apply_hl()
      schedule()
    end,
  })
  vim.api.nvim_create_autocmd({
    'BufWinEnter',
    'BufEnter',
    'WinResized',
    'VimResized',
    'WinNew',
    'WinClosed',
    'TabEnter',
    'BufAdd',
    'BufDelete',
    'TermOpen',
    'BufModifiedSet',
  }, { group = group, callback = schedule })

  -- One global click router for the tab floats. <expr> so we can fall through
  -- to a normal click (return '<LeftMouse>') when the mouse isn't over a float;
  -- buffer-local maps (nvim-tree etc.) still take precedence over this. Mapped
  -- in terminal-mode too so the terminal pane's tabs are clickable while typing
  -- (the click drops the terminal to normal mode; press i/a to resume).
  vim.keymap.set({ 'n', 't' }, '<LeftMouse>', function()
    return M._click() and '' or '<LeftMouse>'
  end, { expr = true, desc = 'Pane tab click' })

  vim.keymap.set('n', '<leader>bd', function()
    local w = vim.api.nvim_get_current_win()
    M.close_buf(w, vim.api.nvim_get_current_buf(), role_of(w))
  end, { desc = 'Close current buffer/tab' })

  -- Chrome-style tab shortcuts, on the focused pane's tabs. Mapped in both normal
  -- and terminal mode ({'n','t'}) so they work whichever pane you're in -- file
  -- panes (normal mode) and the Claude/shell terminal panes (terminal mode). The
  -- work is deferred via vim.schedule: from a terminal-mode mapping, switching the
  -- buffer/window inline can hit textlock, and scheduling also lets terminal mode
  -- settle before we (maybe) startinsert into the newly shown terminal.
  local function map(lhs, fn, desc)
    vim.keymap.set({ 'n', 't' }, lhs, function()
      vim.schedule(fn)
    end, { desc = desc })
  end

  -- Next / previous tab: Ctrl-Tab / Ctrl-Shift-Tab, plus Ctrl-PageDown/PageUp
  -- (the same Chrome bindings, and more reliably distinguishable in terminals).
  map('<C-Tab>', function() M.nav(1) end, 'Next tab (Chrome)')
  map('<C-S-Tab>', function() M.nav(-1) end, 'Previous tab (Chrome)')
  map('<C-PageDown>', function() M.nav(1) end, 'Next tab (Chrome)')
  map('<C-PageUp>', function() M.nav(-1) end, 'Previous tab (Chrome)')

  -- Ctrl-1..8 jump to that tab; Ctrl-9 jumps to the last tab (Chrome behaviour).
  for n = 1, 8 do
    map('<C-' .. n .. '>', function() M.goto_tab(n) end, 'Go to tab ' .. n .. ' (Chrome)')
  end
  map('<C-9>', function() M.goto_tab(-1) end, 'Go to last tab (Chrome)')

  -- Close / new tab: Ctrl-W / Ctrl-T (full parity -- in terminal panes this
  -- shadows the shell's Ctrl-W word-erase and any TUI Ctrl-T).
  map('<C-w>', function() M.close_current() end, 'Close tab (Chrome)')
  map('<C-t>', function() M.new_tab() end, 'New tab (Chrome)')

  schedule()
end

return M
