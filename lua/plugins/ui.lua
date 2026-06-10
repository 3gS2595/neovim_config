return {
  -- Statusline, tabline and winbar
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons', 'SmiteshP/nvim-navic' },
    config = function()
      local custom_theme = require('lualine.themes.horizon')
      local yellow = '#aaaa00'
      local orange = '#ff6600'
      local red = '#870000'

      custom_theme.normal.a.bg = red
      custom_theme.visual.a.bg = '#be19e8'
      custom_theme.insert.a.bg = orange
      custom_theme.inactive.a.bg = red
      custom_theme.insert.a.fg = red
      custom_theme.visual.a.fg = red
      custom_theme.replace.a.fg = red
      custom_theme.normal.a.fg = orange

      for _, mode in ipairs({ 'inactive', 'visual', 'normal', 'insert', 'command', 'replace' }) do
        custom_theme[mode].b.bg = yellow
        custom_theme[mode].b.fg = red
        custom_theme[mode].c.bg = '#000000'
        custom_theme[mode].c.fg = orange
      end
      custom_theme.insert.c.bg = yellow

      require('lualine').setup({
        options = {
          theme = custom_theme,
          globalstatus = true,
          icons_enabled = true,
          section_separators = {
            left = '',
            right = '',
          },
        },
        sections = {
          lualine_a = { 'mode' },
          lualine_b = { 'diff', 'diagnostics' },
          lualine_c = { 'filename' },
          lualine_x = {},
          lualine_y = { 'encoding', 'fileformat', 'filetype' },
          lualine_z = { 'branch' },
        },
        tabline = {
          lualine_a = {
            {
              'buffers',
              show_filename_only = false,
              hide_filename_extension = false,
              show_modified_status = true,
              mode = 2,
              max_length = vim.o.columns * 2 / 3,
              filetype_names = {
                TelescopePrompt = 'Telescope',
              },
              use_mode_colors = true,
              symbols = {
                modified = ' ●',
                alternate_file = '#',
                directory = '',
              },
            },
          },
          lualine_z = { 'tabs' },
        },
        winbar = {
          lualine_a = {
            {
              'diagnostics',
              update_in_insert = true,
            },
            {
              function()
                return require('nvim-navic').get_location()
              end,
              cond = function()
                return require('nvim-navic').is_available()
              end,
            },
          },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
        inactive_winbar = {
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
      })
    end,
  },

  -- Code context for the winbar (attached in lsp.lua on LspAttach)
  { 'SmiteshP/nvim-navic', lazy = true },

  -- File icons
  {
    'nvim-tree/nvim-web-devicons',
    opts = {
      color_icons = true,
      default = true,
      strict = true,
      override = {
        zsh = {
          icon = '',
          color = '#428850',
          cterm_color = '65',
          name = 'Zsh',
        },
      },
      override_by_filename = {
        ['.gitignore'] = {
          icon = '',
          color = '#f1502f',
          name = 'Gitignore',
        },
      },
      override_by_extension = {
        ['log'] = {
          icon = '',
          color = '#81e043',
          name = 'Log',
        },
      },
    },
  },

  -- Transparent background
  {
    'xiyaowong/transparent.nvim',
    opts = {
      groups = {
        'Normal', 'NormalNC', 'Comment', 'Constant', 'Special', 'Identifier',
        'Statement', 'PreProc', 'Type', 'Underlined', 'Todo', 'String', 'Function',
        'Conditional', 'Repeat', 'Operator', 'Structure', 'LineNr', 'NonText',
        'SignColumn', 'CursorLine', 'CursorLineNr', 'StatusLine', 'StatusLineNC',
        'EndOfBuffer',
      },
      extra_groups = {
        'NormalFloat',   -- plugins which have float panel such as Lazy, Mason, LspInfo
        'NvimTreeNormal',
      },
    },
  },

  -- Highlight color codes (#rrggbb etc.) in any filetype
  {
    'norcalli/nvim-colorizer.lua',
    config = function()
      require('colorizer').setup({ '*' })
    end,
  },

  -- Cmdline UI, messages and notifications
  {
    'folke/noice.nvim',
    dependencies = { 'MunifTanjim/nui.nvim', 'rcarriga/nvim-notify' },
    opts = {
      lsp = {
        -- override markdown rendering so that cmp and other plugins use Treesitter
        override = {
          ['vim.lsp.util.convert_input_to_markdown_lines'] = true,
          ['vim.lsp.util.stylize_markdown'] = true,
          ['cmp.entry.get_documentation'] = true,
        },
      },
      presets = {
        bottom_search = false,
        command_palette = false,
        long_message_to_split = false,
        inc_rename = false,
        lsp_doc_border = false,
      },
    },
  },
}
