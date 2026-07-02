require('baseline.base')
require('baseline.highlights')
require('baseline.maps')
require('baseline.platform')
require('baseline.commands')
require('baseline.splash').setup()
require('baseline.banners').setup()
require('baseline.panetabs').setup()
require('baseline.statusline').setup()
require('baseline.winbar').setup()
require('baseline.portrait').setup()
require('baseline.layout').setup()
require('baseline.splash_images').setup()
require('baseline.scrollguard').setup()

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
  -- image.nvim uses the magick CLI (processor='magick_cli'), so it needs no
  -- luarock. Disable lazy's luarocks/hererocks support so its build step doesn't
  -- fail trying to install one.
  rocks = { enabled = false },
})

vim.cmd.colorscheme('wildcharm-redux')
vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })
vim.api.nvim_set_hl(0, "StatusLine", { bg = "none" })
vim.api.nvim_set_hl(0, "StatusLineNC", { bg = "none" })
