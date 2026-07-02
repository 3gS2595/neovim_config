return {
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

        -- 🔥 IMPORTANT: add winbar too
        'WinBar',
        'WinBarNC',
      },
      extra_groups = {
        'NormalFloat',
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
    dependencies = {
      'MunifTanjim/nui.nvim',
      {
        'rcarriga/nvim-notify',
        -- Normal has a transparent bg, so nvim-notify can't derive a
        -- background color for NotifyBackground and warns on startup.
        -- Give it an explicit fallback to silence the warning.
        opts = { background_colour = '#000000' },
      },
    },
    opts = {
      lsp = {
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
