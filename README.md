work in progress 

  use 'nvim-lualine/lualine.nvim' -- Statusline
  use 'nvim-lua/plenary.nvim'     -- Common utilities
  use 'nvim-tree/nvim-tree.lua'   -- File Explorer
  use 'nvim-telescope/telescope.nvim'
  use 'windwp/nvim-autopairs'
  use 'windwp/nvim-ts-autotag'
  use 'akinsho/nvim-bufferline.lua'

  -- Git
  use 'lewis6991/gitsigns.nvim' -- Git Icon Support
  use 'dinhhuy258/git.nvim'     -- For git blame & browse

  -- UI
  use 'Isrothy/neominimap.nvim'
  use 'xiyaowong/transparent.nvim'  -- Transparent Background
  use 'norcalli/nvim-colorizer.lua'
  use 'nvim-tree/nvim-web-devicons' -- Icon Support

  -- CmdLine
  use 'folke/noice.nvim'     -- main cmdline plugin
  use 'MunifTanjim/nui.nvim' -- Noice (Nice, Noise, Notice) requirement
  use 'rcarriga/nvim-notify' -- notification manager

  -- Plugin Manager
  use 'wbthomason/packer.nvim'
  use 'williamboman/mason.nvim'           -- Plugin Manager
  use 'williamboman/mason-lspconfig.nvim' -- Bridges Mason to lspconfig

  -- LSP
  use 'neovim/nvim-lspconfig' -- LSP
  use 'nvimdev/lspsaga.nvim'  -- LSP UIs
  use 'onsails/lspkind-nvim'  -- vscode-like pictograms

  -- Completion
  use 'hrsh7th/nvim-cmp'     -- Completion
  use 'hrsh7th/cmp-nvim-lsp' -- nvim-cmp source for neovim's built-in LSP
  use 'hrsh7th/cmp-buffer'   -- nvim-cmp source for buffer words
  use 'hrsh7th/cmp-path'     -- nvim-cmp source for path
  use 'L3MON4D3/LuaSnip'     -- nvim-cmp snippet engine

  use {
    'nvim-treesitter/nvim-treesitter',
    run = function() require('nvim-treesitter.install').update({ with_sync = true }) end,
  }

  use { 'numToStr/Comment.nvim',
    requires = {
      'JoosepAlviste/nvim-ts-context-commentstring'
    }
  }

  -- Status Lines
  use {
    "SmiteshP/nvim-navic",
    requires = "neovim/nvim-lspconfig"
  }

  use {
    "nvim-telescope/telescope-file-browser.nvim",
    requires = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" }
  }



