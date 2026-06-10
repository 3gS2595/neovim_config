vim.opt.cursorline = true
vim.opt.termguicolors = true
vim.opt.winblend = 0
vim.opt.wildoptions = 'pum'
vim.opt.pumblend = 5
vim.opt.background = 'dark'

-- Briefly highlight yanked text using the "Visual" highlight group
vim.api.nvim_create_autocmd('TextYankPost', {
  group = vim.api.nvim_create_augroup('highlight_yank', { clear = true }),
  callback = function()
    vim.hl.on_yank({ higroup = 'Visual', timeout = 100 })
  end,
})
