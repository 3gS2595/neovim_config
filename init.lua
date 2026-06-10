require('baseline.base')
require('baseline.highlights')
require('baseline.maps')
require('baseline.platform')
require('baseline.commands')

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    'git', 'clone', '--filter=blob:none',
    'https://github.com/folke/lazy.nvim.git',
    '--branch=stable', lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup('plugins', {
  install = { colorscheme = { 'wildcharm-redux' } },
  change_detection = { notify = false },
})

vim.cmd.colorscheme('wildcharm-redux')
