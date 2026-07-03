-- Per-pane buffer tabs with a 2-row "classic tab" look.
--
--   Row 1 (overlay): ╭──────╮╭────╮                 <- on the free row ABOVE the pane
--   Row 2 (winbar):  │ a.lua ×││ b ×│ <celestial pattern fills the rest>
--
-- Row 2 is the native winbar (baseline.winbar sets a single global 'winbar'
-- whose %{%...%} expression Neovim evaluates per-window, with
-- vim.g.statusline_winid naming the window being drawn -- see M.winbar below):
-- the tab sides + title + × close button, plus the heart/celestial pattern
-- filling the leftover width. Neovim genuinely RESERVES the winbar row, so the
-- pane's buffer text starts on the row below it -- nothing covers content.
--
-- Row 1 is a 1-row floating overlay on the row directly ABOVE the pane, which
-- is never content: for a pane stacked below another it is the blank
-- horizontal-separator row (fillchars horiz=' ', baseline.banners), and for a
-- pane at the top edge it is the always-on blank tabline (showtabline=2, set
-- in M.setup). nvim_win_get_position includes the tabline row and
-- editor-relative floats may paint over it, so `position.row - 1` is always
-- that free row. This replaces the old scheme where row 2 was a float pinned
-- INSIDE the pane over its first text row, "reserved" by a virt_lines extmark
-- pad -- virtual lines above the topline aren't reliably rendered (and fight
-- terminal buffers entirely), so the float sat on real content.
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
  -- Inset the tabs by this many display columns, so the separator pattern shows
  -- to their LEFT too (a small gap from the pane edge before the first tab),
  -- matching the trailing fill. 0 = tabs flush against the left edge.
  lead = 4,
}

local TL, TR, TOP, SIDE, CLOSE = '╭', '╮', '─', '│', '×'

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

-- Escape statusline/winbar metacharacters in user-derived text (file names can
-- contain '%', which would otherwise start a winbar item).
local function esc(s)
  return (s:gsub('%%', '%%%%'))
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
--   tops  : {text, hl} plain-text row 1 (the ╭──╮ outlines) with
--           {byte0, byte1, group} highlight ranges, painted into the overlay
--   bodies: winbar string for row 2 (inline %#..# highlights)
--   clicks: {d0, d1, x0, x1, buf} display-column ranges per tab (0-based), row 2
local function build(win, role, width)
  local cur = vim.api.nvim_win_get_buf(win)
  local top, thl, bodies, clicks = {}, {}, {}, {}
  local disp, tb = 0, 0 -- display column / tops byte cursor
  -- Inset the tabs by config.lead columns so they start part way in, framed by
  -- the separator pattern. Row 1 (the tab-tops row) gets plain spaces -- it never
  -- carries the pattern -- while row 2 (the title row) gets the celestial fill,
  -- so the pattern shows to the LEFT of the tabs just as it does to their right.
  local lead = M.config.lead or 0
  if lead > 0 then
    top[#top + 1] = string.rep(' ', lead)
    tb = lead
    bodies[#bodies + 1] = '%#PaneTabFill#' .. esc(pattern(lead))
    disp = lead
  end
  for _, b in ipairs(buffers_for(role)) do
    local g = b == cur and 'PaneTabTop' or 'PaneTabTopNC'
    local name = ' ' .. label(b, role) .. ' '
    local body = name .. CLOSE .. ' ' -- ' name × '
    local bw = dw(body)

    -- Row 1: ╭───────╮
    local cell = TL .. string.rep(TOP, bw) .. TR
    top[#top + 1] = cell
    thl[#thl + 1] = { tb, tb + #cell, g }
    tb = tb + #cell

    -- Row 2: │ name × │
    bodies[#bodies + 1] = '%#' .. g .. '#' .. SIDE .. esc(name)
      .. '%#PaneTabClose#' .. CLOSE .. '%#' .. g .. '# ' .. SIDE

    -- Click ranges (display columns, 0-based)
    local xd = disp + dw(SIDE) + dw(name)
    clicks[#clicks + 1] = { d0 = disp, d1 = disp + bw + 2, x0 = xd, x1 = xd + dw(CLOSE), buf = b }

    disp = disp + bw + 2
  end

  -- Fill the leftover width with the celestial pattern (row 2 only).
  local fill = pattern(width - disp)
  if fill ~= '' then
    bodies[#bodies + 1] = '%#PaneTabFill#' .. esc(fill)
  end
  bodies[#bodies + 1] = '%#WinBar#'

  return { text = table.concat(top), hl = thl }, table.concat(bodies), clicks
end

-- State for the row-1 overlays and the row-2 click ranges. `tops` maps a
-- content window to its overlay {win, buf, sig}; `clicks` maps a content
-- window to the display-column ranges of the tabs its winbar currently shows
-- (refreshed both by M.winbar and by the overlay redraw).
local uv = vim.uv
local ns = vim.api.nvim_create_namespace('panetabs_tops')
local ov = { tops = {}, clicks = {}, timer = nil, in_redraw = false }

-- Winbar component baseline.winbar calls: the tab title row for tagged panes,
-- else the heart banner. `win` defaults to the current window; baseline.winbar
-- passes vim.g.statusline_winid explicitly since during winbar evaluation
-- that's the window being drawn, not necessarily the focused one.
function M.winbar(win)
  win = win or vim.api.nvim_get_current_win()
  local role = role_of(win)
  if role then
    local _, bodies, clicks = build(win, role, vim.api.nvim_win_get_width(win))
    ov.clicks[win] = clicks
    return bodies
  end
  ov.clicks[win] = nil
  return require('baseline.banners').winbar(win)
end

function M.is_tabbed(win)
  return role_of(win or vim.api.nvim_get_current_win()) ~= nil
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

-- Open a new tab in the focused pane: a fresh interactive terminal (which
-- auto-runs `f`) in a terminal pane, otherwise a blank [No Name] file buffer
-- (Chrome's Ctrl-T).
function M.new_tab()
  local win = vim.api.nvim_get_current_win()
  local role = role_of(win)
  if not role then
    return
  end
  if role == 'terms' then
    vim.cmd('terminal')
    -- "Type" `f` into the new shell (send to the channel rather than
    -- `:terminal f`: that would run a non-interactive `shell -c` that skips
    -- the rc, so the alias wouldn't resolve and the shell wouldn't stay alive).
    local job = vim.b.terminal_job_id
    vim.defer_fn(function()
      pcall(vim.api.nvim_chan_send, job, 'f\n')
    end, 200)
    vim.cmd('startinsert')
  else
    vim.cmd('enew')
  end
end

-- Click routing ---------------------------------------------------------------

-- Left-click router for the tab title row (wired as ONE global mapping in
-- M.setup). Row 2 lives in each tabbed pane's winbar, so a click there reports
-- the pane itself in getmousepos() with winrow == 1 (the winbar row) and
-- line == 0 (not on buffer text) -- crucially resolving to the pane UNDER THE
-- MOUSE, not the focused one, so tabs in unfocused panes work too. The click
-- column is matched against the ranges M.winbar cached for that pane.
--
-- Returns true when the click landed on a tab row (so the caller suppresses
-- the default click), false to let Neovim handle the click normally.
function M._click()
  local mp = vim.fn.getmousepos()
  local win = mp.winid
  if win == 0 or mp.winrow ~= 1 or mp.line ~= 0 then
    return false
  end
  local role = role_of(win)
  if not role then
    return false -- not a tabbed pane's winbar: default click behaviour
  end
  local col = mp.wincol - 1
  for _, c in ipairs(ov.clicks[win] or {}) do
    if col >= c.d0 and col < c.d1 then
      local buf = c.buf
      local close = col >= c.x0 and col < c.x1
      -- Defer the switch: this is called from an <expr> mapping, where changing
      -- the window/buffer is blocked by textlock (E565).
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        if close then
          M.close_buf(win, buf, role)
        elseif vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_win_set_buf, win, buf)
        end
        pcall(vim.api.nvim_set_current_win, win) -- focus the clicked pane
      end)
      break
    end
  end
  return true -- our tab row (even on the empty fill): swallow the default click
end

-- Row 1 floating overlay (the ╭──╮ tab tops) ---------------------------------

local function destroy_tops(cwin)
  local h = ov.tops[cwin]
  if h then
    if vim.api.nvim_win_is_valid(h.win) then
      pcall(vim.api.nvim_win_close, h.win, true)
    end
    ov.tops[cwin] = nil
  end
end

local function paint(buf, text, hl)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, h[1], { end_col = h[2], hl_group = h[3] })
  end
end

local function update_tops(cwin, role)
  local width = vim.api.nvim_win_get_width(cwin)
  local tops, _, clicks = build(cwin, role, width)
  ov.clicks[cwin] = clicks
  local pos = vim.api.nvim_win_get_position(cwin)
  -- The free row above the pane: the blank separator row for stacked panes,
  -- the blank tabline row (row 0) for top-edge panes.
  local row, col = pos[1] - 1, pos[2]
  if #clicks == 0 or width < 2 or row < 0 then
    destroy_tops(cwin)
    return
  end
  -- The overlay is only repainted when this signature changes. Include the
  -- pane's current buffer: switching the active tab moves the active-tab
  -- highlight even though the outline text is unchanged, so the text alone
  -- would skip the repaint and leave the tops' active colour stale. (Row 2's
  -- winbar carries inline highlights, so Neovim repaints it every redraw.)
  local sig = table.concat({ row, col, width, vim.api.nvim_win_get_buf(cwin), tops.text }, '|')
  local h = ov.tops[cwin]
  if h and vim.api.nvim_win_is_valid(h.win) then
    if h.sig ~= sig then
      pcall(vim.api.nvim_win_set_config, h.win, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = 1,
      })
      paint(h.buf, tops.text, tops.hl)
      h.sig = sig
    end
    return
  end
  destroy_tops(cwin)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  paint(buf, tops.text, tops.hl)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = 1,
    focusable = false, -- clicks live on the winbar row; this row has none
    zindex = 35,
    style = 'minimal',
    noautocmd = true,
  })
  if ok then
    vim.wo[win].winhighlight = 'Normal:PaneTabBar'
    ov.tops[cwin] = { win = win, buf = buf, sig = sig }
  end
end

local function redraw()
  local seen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == '' and role_of(win) then
      seen[win] = true
      update_tops(win, role_of(win))
    end
  end
  for cwin in pairs(ov.tops) do
    if not seen[cwin] then
      destroy_tops(cwin)
    end
  end
  for cwin in pairs(ov.clicks) do
    if not seen[cwin] then
      ov.clicks[cwin] = nil
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

  -- Every pane needs a free (non-content) row directly ABOVE it for the tab
  -- tops overlay: stacked panes have the blank horizontal-separator row
  -- (fillchars horiz=' ', baseline.banners), and top-edge panes get one from
  -- an always-on blank tabline. This overrides baseline.base's showtabline=0.
  -- With the tabline visible, nvim_win_get_position includes its row (a top
  -- pane sits at row 1), so update_tops' `pos.row - 1` lands on the tabline
  -- for top panes -- and editor-relative floats may paint over that row.
  vim.o.showtabline = 2
  vim.o.tabline = ' ' -- blank: no tab-page labels; TabLineFill is transparent

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
    'BufWritePost',
  }, { group = group, callback = schedule })

  -- THE global left-button router. Every clickable UI region is handled here,
  -- in one mapping: two modules each mapping <LeftMouse> globally would clobber
  -- each other (last setup wins), which is how the portrait's map used to
  -- silently disable tab clicks or vice versa. <expr> so we can fall through to
  -- a normal click (return the key) when the mouse isn't over any of our UI;
  -- buffer-local maps (nvim-tree etc.) still take precedence over this. Mapped
  -- in terminal-mode too so the terminal pane's tabs are clickable while typing
  -- (the click drops the terminal to normal mode; press i/a to resume).
  --
  -- Regions, in priority order:
  --  * The portrait pane doubles as a BUTTON: left-clicking it toggles live
  --    Claude-edit playback (baseline.follow / the statusline's "live:"
  --    indicator) instead of focusing the pane.
  --  * The tab title rows (M._click).
  --  * A click that falls through and lands in ANY terminal pane (Claude, the
  --    bottom shell, all of them) auto-enters terminal-mode, so clicking a
  --    terminal always drops you straight into typing
  --    rather than normal mode. Deferred via vim.schedule: the native
  --    '<LeftMouse>' return still has to move focus/cursor there first, and
  --    textlock blocks startinsert inline anyway. Plain single clicks only:
  --    double-clicks must keep their default word-select behaviour there.
  --
  -- Multi-clicks (<2-LeftMouse>...) route through the same handler: rapid
  -- clicking the portrait or a tab arrives as those keys, and their DEFAULT
  -- behaviour is select-word/line -- i.e. surprise visual mode.
  --
  -- `swallowed` tracks a press we consumed, so the <LeftDrag>/<LeftRelease>
  -- maps below can swallow the REST of that gesture too. The press being eaten
  -- doesn't stop Neovim delivering the drag events, and their default would
  -- start a visual selection from the 1-cell wiggle almost every click ships
  -- with. A press that fell through clears the flag, so dragging in pane
  -- content still selects text normally.
  local swallowed = false
  local function route(key)
    local mp = vim.fn.getmousepos()
    if
      mp.winid ~= 0
      and vim.api.nvim_win_is_valid(mp.winid)
      and vim.bo[vim.api.nvim_win_get_buf(mp.winid)].filetype == 'portrait'
    then
      -- Toggle scheduled out of the expr context (expr evaluation runs under
      -- textlock); consume the click so focus never lands on the portrait.
      vim.schedule(function()
        require('baseline.follow').toggle()
      end)
      swallowed = true
      return ''
    end
    if M._click() then
      swallowed = true
      return ''
    end
    swallowed = false
    if
      key == '<LeftMouse>'
      and mp.winid ~= 0
      and vim.api.nvim_win_is_valid(mp.winid)
      and vim.bo[vim.api.nvim_win_get_buf(mp.winid)].buftype == 'terminal'
    then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(mp.winid) and vim.api.nvim_get_current_win() == mp.winid then
          vim.cmd('startinsert')
        end
      end)
    end
    return key
  end
  for _, key in ipairs({ '<LeftMouse>', '<2-LeftMouse>', '<3-LeftMouse>', '<4-LeftMouse>' }) do
    vim.keymap.set({ 'n', 'i', 'v', 't' }, key, function()
      return route(key)
    end, { expr = true, desc = 'Left-click router (portrait / pane tabs / Claude)' })
  end
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<LeftDrag>', function()
    return swallowed and '' or '<LeftDrag>'
  end, { expr = true, desc = 'Swallow drags of consumed clicks' })
  vim.keymap.set({ 'n', 'i', 'v', 't' }, '<LeftRelease>', function()
    if swallowed then
      swallowed = false
      return ''
    end
    return '<LeftRelease>'
  end, { expr = true, desc = 'Swallow releases of consumed clicks' })

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
