-- Native bottom statusline: current mode on the left, the heart separator
-- pattern filling the rest of the row. Replaces lualine.nvim -- lualine's own
-- heart-fill component had to measure the OTHER lualine sections around it
-- (nvim_eval_statusline) and cache the result to dodge a re-entrant-eval flash
-- (see git history / lua/plugins/ui.lua before this file). Here there IS no
-- other section: it's just the mode block and the fill, and both only depend
-- on the mode and the editor width, which Neovim already redraws the
-- statusline for on its own (mode changes and resizes always repaint) -- so no
-- measuring/caching dance is needed.

local M = {}

-- vim.fn.mode(1) short codes -> {label, highlight group}. Not exhaustive of
-- every obscure code; anything missing falls back to the code itself
-- upper-cased under the normal-mode colour (see M.render).
local MODES = {
  n = { 'NORMAL', 'StatuslineNormal' },
  no = { 'O-PENDING', 'StatuslineNormal' },
  nov = { 'O-PENDING', 'StatuslineNormal' },
  noV = { 'O-PENDING', 'StatuslineNormal' },
  ['no\22'] = { 'O-PENDING', 'StatuslineNormal' },
  niI = { 'NORMAL', 'StatuslineNormal' },
  niR = { 'NORMAL', 'StatuslineNormal' },
  niV = { 'NORMAL', 'StatuslineNormal' },
  nt = { 'NORMAL', 'StatuslineNormal' },
  ntT = { 'NORMAL', 'StatuslineNormal' },
  v = { 'VISUAL', 'StatuslineVisual' },
  vs = { 'VISUAL', 'StatuslineVisual' },
  V = { 'V-LINE', 'StatuslineVisual' },
  Vs = { 'V-LINE', 'StatuslineVisual' },
  ['\22'] = { 'V-BLOCK', 'StatuslineVisual' },
  ['\22s'] = { 'V-BLOCK', 'StatuslineVisual' },
  s = { 'SELECT', 'StatuslineVisual' },
  S = { 'S-LINE', 'StatuslineVisual' },
  ['\19'] = { 'S-BLOCK', 'StatuslineVisual' },
  i = { 'INSERT', 'StatuslineInsert' },
  ic = { 'INSERT', 'StatuslineInsert' },
  ix = { 'INSERT', 'StatuslineInsert' },
  R = { 'REPLACE', 'StatuslineReplace' },
  Rc = { 'REPLACE', 'StatuslineReplace' },
  Rx = { 'REPLACE', 'StatuslineReplace' },
  Rv = { 'V-REPLACE', 'StatuslineReplace' },
  Rvc = { 'V-REPLACE', 'StatuslineReplace' },
  c = { 'COMMAND', 'StatuslineCommand' },
  cv = { 'EX', 'StatuslineCommand' },
  ce = { 'EX', 'StatuslineCommand' },
  r = { 'PROMPT', 'StatuslineCommand' },
  rm = { 'MORE', 'StatuslineCommand' },
  ['r?'] = { 'CONFIRM', 'StatuslineCommand' },
  ['!'] = { 'SHELL', 'StatuslineCommand' },
  t = { 'TERMINAL', 'StatuslineInsert' },
}

M.config = {
  fg = '#ff5f87', -- heart colour (baseline.banners' fg, kept as a literal here
                   -- so this file has no load-order dependency on that module)
  yellow = '#aaaa00',
  orange = '#ff6600',
  red = '#870000',
  purple = '#be19e8',
}

local function apply_hl()
  local c = M.config
  vim.api.nvim_set_hl(0, 'StatuslineNormal', { bg = c.red, fg = c.orange, bold = true })
  vim.api.nvim_set_hl(0, 'StatuslineInsert', { bg = c.orange, fg = c.red, bold = true })
  vim.api.nvim_set_hl(0, 'StatuslineVisual', { bg = c.purple, fg = c.red, bold = true })
  vim.api.nvim_set_hl(0, 'StatuslineReplace', { bg = c.yellow, fg = c.red, bold = true })
  vim.api.nvim_set_hl(0, 'StatuslineCommand', { bg = c.yellow, fg = c.red, bold = true })
  vim.api.nvim_set_hl(0, 'StatuslineHeart', { fg = c.fg, bg = 'NONE', bold = true })

  -- Make the native chrome groups transparent so nothing but our own colours
  -- shows: the mode block and the heart fill paint the WHOLE row themselves
  -- (see M.render), so any leftover 'StatusLine' background would only ever
  -- show as a stray seam if the heart count rounds a column short. WinBar/
  -- TabLine are included here too since baseline.winbar (the top row) relies
  -- on the same "our own colours paint everything" approach. The colorscheme
  -- is applied AFTER this runs and repaints these groups, hence the
  -- ColorScheme autocmd in M.setup.
  for _, name in ipairs({
    'WinBar', 'WinBarNC',
    'TabLine', 'TabLineFill', 'TabLineSel',
    'StatusLine', 'StatusLineNC',
  }) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    hl.bg = 'NONE'
    vim.api.nvim_set_hl(0, name, hl)
  end
end

function M.render()
  local mode = vim.api.nvim_get_mode().mode
  local info = MODES[mode] or { mode:upper(), 'StatuslineNormal' }
  local label = ' ' .. info[1] .. ' '
  local avail = math.max(0, vim.o.columns - vim.fn.strdisplaywidth(label))
  local hearts = string.rep('♡ ', math.floor(avail / 2))
  return '%#' .. info[2] .. '#' .. label .. '%#StatuslineHeart#' .. hearts
end

function M.setup()
  vim.o.laststatus = 3 -- one statusline for the whole editor, not per-window
  vim.o.statusline = "%{%v:lua.require('baseline.statusline').render()%}"

  apply_hl()
  local group = vim.api.nvim_create_augroup('BaselineStatusline', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply_hl })
end

return M
