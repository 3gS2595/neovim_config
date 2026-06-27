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
  fg = '#be19e8', -- inactive tab + pattern fill colour
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

function M.set_role(win, role)
  pcall(vim.api.nvim_win_set_var, win, 'pane_tabs', role)
end

local function role_of(win)
  local ok, r = pcall(vim.api.nvim_win_get_var, win, 'pane_tabs')
  return ok and r or nil
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

-- Click handler bound to each title float; resolves the click column to a tab.
function M._click(cwin)
  local h = ov.headers[cwin]
  if not h then
    return
  end
  local mp = vim.fn.getmousepos()
  if mp.winid == h.win then
    local col = mp.wincol - 1
    for _, c in ipairs(h.clicks) do
      if col >= c.d0 and col < c.d1 then
        if col >= c.x0 and col < c.x1 then
          M.close_buf(h.content, c.buf, h.role)
        else
          pcall(vim.api.nvim_win_set_buf, h.content, c.buf)
        end
        break
      end
    end
  end
  if vim.api.nvim_win_is_valid(h.content) then
    pcall(vim.api.nvim_set_current_win, h.content) -- never rest focus in the float
  end
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
  local sig = table.concat({ row, col, width, title }, '|')
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
    focusable = true, -- needed to receive the click; focus is bounced back
    zindex = 35,
    style = 'minimal',
    noautocmd = true,
  })
  if ok then
    vim.wo[win].winhighlight = 'Normal:PaneTabBar'
    ov.headers[cwin] = { win = win, buf = buf, sig = sig, content = cwin, role = role, clicks = clicks }
    vim.keymap.set('n', '<LeftMouse>', function()
      M._click(cwin)
    end, { buffer = buf, nowait = true, silent = true })
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
  vim.api.nvim_set_hl(0, 'PaneTabFill', { fg = c.fg, bg = 'NONE' })
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

  vim.keymap.set('n', '<leader>bd', function()
    local w = vim.api.nvim_get_current_win()
    M.close_buf(w, vim.api.nvim_get_current_buf(), role_of(w))
  end, { desc = 'Close current buffer/tab' })

  schedule()
end

return M
