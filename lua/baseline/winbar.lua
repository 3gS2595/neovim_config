-- Native per-window winbar (the top row of each pane): LSP diagnostics +
-- nvim-navic breadcrumb on the focused, untagged pane (help/quickfix/etc.),
-- otherwise just baseline.panetabs' own row -- buffer tabs on tagged panes
-- (code/terminal), the heart banner fallback everywhere else. Replaces
-- lualine's `winbar`/`inactive_winbar` tables now that lualine is gone.
--
-- vim.g.statusline_winid is Neovim's documented way to know which window a
-- statusline/winbar %{%...%} expression is being evaluated FOR --
-- nvim_get_current_win() would just return the globally focused window,
-- which is wrong for every window's winbar except the focused one.

local M = {}

local DIAG_ORDER = {
  { vim.diagnostic.severity.ERROR, ' ', 'DiagnosticError' },
  { vim.diagnostic.severity.WARN, ' ', 'DiagnosticWarn' },
  { vim.diagnostic.severity.INFO, ' ', 'DiagnosticInfo' },
  { vim.diagnostic.severity.HINT, ' ', 'DiagnosticHint' },
}

local function diagnostics(buf)
  local counts = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    counts[d.severity] = (counts[d.severity] or 0) + 1
  end
  local parts = {}
  for _, o in ipairs(DIAG_ORDER) do
    local n = counts[o[1]]
    if n and n > 0 then
      parts[#parts + 1] = '%#' .. o[3] .. '#' .. o[2] .. n
    end
  end
  return table.concat(parts, ' ')
end

-- nvim-navic returns a string with its OWN inline %#Group# highlights already
-- embedded (it's built specifically to be dropped into a statusline/winbar
-- verbatim), so we just pass it through.
local function navic(buf)
  local ok, nav = pcall(require, 'nvim-navic')
  if not ok or not nav.is_available(buf) then
    return ''
  end
  return nav.get_location({}, buf)
end

function M.render()
  -- g:statusline_winid is unset (nil, not even 0) outside a real statusline/
  -- winbar redraw -- e.g. our own :redrawstatus! from a BufDelete autocmd
  -- during teardown -- so nvim_win_is_valid would error on a nil arg.
  local win = vim.g.statusline_winid or 0
  if not vim.api.nvim_win_is_valid(win) then
    return ''
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local panetabs = require('baseline.panetabs')
  local tabs = panetabs.winbar(win)

  -- Diagnostics/navic only belong on the focused, untagged pane -- tabbed
  -- panes want their tab row flush left, and an unfocused pane showing LSP
  -- context for a buffer you're not looking at is just noise.
  if panetabs.is_tabbed(win) or win ~= vim.api.nvim_get_current_win() then
    return tabs
  end

  local diag, nav = diagnostics(buf), navic(buf)
  local left = table.concat(
    vim.tbl_filter(function(s) return s ~= '' end, { diag, nav }),
    ' '
  )
  return (left ~= '' and left .. ' ' or '') .. tabs
end

function M.setup()
  vim.o.winbar = "%{%v:lua.require('baseline.winbar').render()%}"

  local group = vim.api.nvim_create_augroup('BaselineWinbar', { clear = true })
  -- Neovim redraws the winbar on its own for most normal editing (typing,
  -- cursor moves, buffer/window switches). These cover the cases that can
  -- change OUR content with nothing else forcing a repaint: async diagnostics
  -- landing, a buffer being added/removed/renamed, a layout change, or (via
  -- CursorHold) anything missed while idle.
  vim.api.nvim_create_autocmd({
    'DiagnosticChanged', 'BufAdd', 'BufDelete', 'BufWritePost', 'TermOpen',
    'WinNew', 'WinClosed', 'WinResized', 'VimResized', 'TabEnter', 'CursorHold',
  }, {
    group = group,
    callback = function()
      vim.cmd('redrawstatus!')
    end,
  })

  -- Keep the file tree's winbar blank (no heart banner/tab row over it), the
  -- same treatment baseline.portrait already gives its own square panes
  -- directly (vim.wo[win].winbar = ''), which this doesn't need to duplicate.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'NvimTree',
    callback = function(args)
      local win = vim.fn.bufwinid(args.buf)
      if win ~= -1 then
        vim.wo[win].winbar = ''
      end
    end,
  })
end

return M
