local status, packer = pcall(require, "packer")
if (not status) then
  print("Packer is not installed")
  return
end

vim.cmd [[packadd packer.nvim]]

packer.startup(function(use)
  use 'nvim-lualine/lualine.nvim' -- Statusline
  use 'nvim-lua/plenary.nvim'     -- Common utilities
  use 'nvim-tree/nvim-tree.lua'   -- File Explorer
  use 'nvim-telescope/telescope.nvim'
  use 'windwp/nvim-autopairs'
  use 'windwp/nvim-ts-autotag'
  use 'akinsho/nvim-bufferline.lua'
  use {
    "nvim-telescope/telescope-file-browser.nvim",
    requires = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" }
  }
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
end)


vim.g.neominimap = {
  -- Enable the plugin by default
  auto_enable = true, ---@type boolean

  -- Log level
  log_level = vim.log.levels.OFF, ---@type Neominimap.Log.Levels

  -- Notification level
  notification_level = vim.log.levels.INFO, ---@type Neominimap.Log.Levels

  -- Path to the log file
  log_path = vim.fn.stdpath("data") .. "/neominimap.log", ---@type string

  -- Minimap will not be created for buffers of these types
  ---@type string[]
  exclude_filetypes = {
    "help",
    "bigfile", -- For Snacks.nvim
  },

  -- Minimap will not be created for buffers of these types
  ---@type string[]
  exclude_buftypes = {
    "nofile",
    "nowrite",
    "quickfix",
    "terminal",
    "prompt",
  },

  -- When false is returned, the minimap will not be created for this buffer
  ---@type fun(bufnr: integer): boolean
  buf_filter = function()
    return true
  end,

  -- When false is returned, the minimap will not be created for this window
  ---@type fun(winid: integer): boolean
  win_filter = function()
    return true
  end,

  -- When false is returned, the minimap will not be created for this tab
  ---@type fun(tabid: integer): boolean
  tab_filter = function()
    return true
  end,


  -- How many columns a dot should span
  x_multiplier = 8, ---@type integer

  -- How many rows a dot should span
  y_multiplier = 2, ---@type integer


  --- Either `split` or `float`
  --- When layout is set to `float`,
  --- the minimap will be created in floating windows attached to all suitable windows
  --- When layout is set to `split`,
  --- the minimap will be created in one split window
  layout = "split", ---@type Neominimap.Config.LayoutType

  --- Used when `layout` is set to `split`
  split = {
    minimap_width = 6, ---@type integer

    -- Always fix the width of the split window
    fix_width = false, ---@type boolean

    direction = "right", ---@type Neominimap.Config.SplitDirection

    ---Automatically close the split window when it is the last window
    close_if_last_window = false, ---@type boolean
  },

  -- For performance issue, when text changed,
  -- minimap is refreshed after a certain delay
  -- Set the delay in milliseconds
  delay = 200, ---@type integer

  -- Sync the cursor position with the minimap
  sync_cursor = true, ---@type boolean

  click = {
    -- Enable mouse click on minimap
    enabled = false, ---@type boolean
    -- Automatically switch focus to minimap when clicked
    auto_switch_focus = true, ---@type boolean
  },

  diagnostic = {
    enabled = true, ---@type boolean
    severity = vim.diagnostic.severity.WARN,
    mode = "line", ---@type Neominimap.Handler.Annotation.Mode
    priority = {
      ERROR = 100, ---@type integer
      WARN = 90, ---@type integer
      INFO = 80, ---@type integer
      HINT = 70, ---@type integer
    },
    icon = {
      ERROR = "󰅚 ", ---@type string
      WARN = "󰀪 ", ---@type string
      INFO = "󰌶 ", ---@type string
      HINT = " ", ---@type string
    },
  },

  git = {
    enabled = true, ---@type boolean
    mode = "sign", ---@type Neominimap.Handler.Annotation.Mode
    priority = 6, ---@type integer
    icon = {
      add = "+ ", ---@type string
      change = "~ ", ---@type string
      delete = "- ", ---@type string
    },
  },

  search = {
    enabled = false, ---@type boolean
    mode = "line", ---@type Neominimap.Handler.Annotation.Mode
    priority = 20, ---@type integer
    icon = "󰱽 ", ---@type string
  },

  treesitter = {
    enabled = true, ---@type boolean
    priority = 200, ---@type integer
  },

  mark = {
    enabled = false, ---@type boolean
    mode = "icon", ---@type Neominimap.Handler.Annotation.Mode
    priority = 10, ---@type integer
    key = "m", ---@type string
    show_builtins = false, ---@type boolean -- shows the builtin marks like [ ] < >
  },

  ---Overrite the default winopt
  ---@param opt vim.wo
  ---@param winid integer the window id of the source window, NOT minimap window
  winopt = function(opt, winid) end,

  ---Overrite the default bufopt
  ---@param opt vim.bo
  ---@param bufnr integer the buffer id of the source buffer, NOT minimap buffer
  bufopt = function(opt, bufnr) end,

  ---@type Neominimap.Map.Handler[]
  handlers = {},
}
