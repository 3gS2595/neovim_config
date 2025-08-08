A highly customized Neovim setup tailored for Ruby and Vue3/TypeScript development.  

## Prerequisites

- Neovim 0.8 or later recommended
- `git` installed
- Node.js and `npm` (for installing `tree-sitter-cli`)
- Optional: Nerd Font for best icon/font support (see below)

## Installation

1. Clone [packer.nvim](https://github.com/wbthomason/packer.nvim) plugin manager:

```git clone --depth 1 https://github.com/wbthomason/packer.nvim ~/.local/share/nvim/site/pack/packer/start/packer.nvim```

2. Install Plugins inside vim:

```:PackerSync```

## Key Features

### Status Line & UI Enhancements
- [`lualine.nvim`](https://github.com/nvim-lualine/lualine.nvim) — customizable and performant statusline.
- Transparent background support with [`transparent.nvim`](https://github.com/xiyaowong/transparent.nvim).
- File icons provided by [`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons).
- Buffer management via [`nvim-bufferline.lua`](https://github.com/akinsho/nvim-bufferline.lua).
- Color highlighting with [`nvim-colorizer.lua`](https://github.com/norcalli/nvim-colorizer.lua).

### File Navigation & Search
- Fuzzy file finding and searching through [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) and its file browser extension [`telescope-file-browser.nvim`](https://github.com/nvim-telescope/telescope-file-browser.nvim).
- File explorer with [`nvim-tree.lua`](https://github.com/nvim-tree/nvim-tree.lua).

### Git Integration
- Git change signs with [`gitsigns.nvim`](https://github.com/lewis6991/gitsigns.nvim).
- Git blame and browse functionality via [`git.nvim`](https://github.com/dinhhuy258/git.nvim).

### Editing & Autocompletion
- Automatic pairing of brackets and HTML tags with [`nvim-autopairs`](https://github.com/windwp/nvim-autopairs) and [`nvim-ts-autotag`](https://github.com/windwp/nvim-ts-autotag).
- Context-aware commenting powered by [`Comment.nvim`](https://github.com/numToStr/Comment.nvim) and Treesitter.
- Advanced autocompletion using [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) with LSP, buffer, and path sources.
- Snippet support via [`LuaSnip`](https://github.com/L3MON4D3/LuaSnip).
- Includes integration with **GitHub Copilot** for AI-assisted code completion.

### Language Server Protocol (LSP) Setup
- Managed LSP servers with [`mason.nvim`](https://github.com/williamboman/mason.nvim) and bridged by [`mason-lspconfig.nvim`](https://github.com/williamboman/mason-lspconfig.nvim).
- Automatically ensures the following LSP servers are installed:
  - `vtsls`, `vue_ls`, `eslint`, `lua_ls`, `jsonls`, `html`, `cssls`, `tailwindcss`
- Enhanced LSP UIs through [`lspsaga.nvim`](https://github.com/nvimdev/lspsaga.nvim).
- Completion item pictograms with [`lspkind-nvim`](https://github.com/onsails/lspkind-nvim).
- Code context display using [`nvim-navic`](https://github.com/SmiteshP/nvim-navic).

### Treesitter Configuration
- Syntax highlighting and parsing powered by [`nvim-treesitter`](https://github.com/nvim-treesitter/nvim-treesitter) on the latest main branch.
- Installed parsers include:
  - `markdown`, `regex`, `markdown_inline`, `tsx`, `typescript`, `toml`, `fish`, `php`, `json`, `yaml`, `swift`, `vue`, `css`, `html`, `lua`, `bash`
- Autostarts Treesitter highlighting for filetypes: `ruby`, `vue`, `typescript`, `tsx`, and `javascript`.

### Command Line & Notifications
- Enhanced command line UI with [`noice.nvim`](https://github.com/folke/noice.nvim) plus dependencies [`nui.nvim`](https://github.com/MunifTanjim/nui.nvim) and [`nvim-notify`](https://github.com/rcarriga/nvim-notify).
