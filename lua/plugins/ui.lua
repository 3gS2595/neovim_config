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

      -- MODE COLORS
      custom_theme.normal.a.bg = red
      custom_theme.visual.a.bg = '#be19e8'
      custom_theme.insert.a.bg = orange
      custom_theme.inactive.a.bg = red
      custom_theme.insert.a.fg = red
      custom_theme.visual.a.fg = red
      custom_theme.replace.a.fg = red
      custom_theme.normal.a.fg = orange

      -- SECTION B + C FIX
      for _, mode in ipairs({ 'inactive', 'visual', 'normal', 'insert', 'command', 'replace' }) do
        custom_theme[mode].b.bg = yellow
        custom_theme[mode].b.fg = red

        -- 🔥 FIX: allow transparency in center section
        custom_theme[mode].c.bg = 'NONE'
        custom_theme[mode].c.fg = orange
      end

      custom_theme.insert.c.bg = 'NONE'

      require('lualine').setup({
        options = {
          theme = custom_theme,
          globalstatus = true,
          icons_enabled = true,
          -- The portrait engine's structural panes (square + empty) carry this
          -- filetype; skip their winbar so no banner/separator line is drawn
          -- beneath the portrait (baseline/portrait.lua).
          disabled_filetypes = { winbar = { 'portrait' } },
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

        -- Buffers live per-pane in each window's winbar (baseline.panetabs);
        -- the global tabline is disabled (showtabline = 0) so no top line shows.

        winbar = {
          lualine_a = {
            {
              'diagnostics',
              update_in_insert = true,
              -- Hidden on tabbed panes (code/terminal) so the tabs sit flush.
              cond = function()
                return not require('baseline.panetabs').is_tabbed()
              end,
            },
            {
              function()
                return require('nvim-navic').get_location()
              end,
              cond = function()
                return require('nvim-navic').is_available()
                  and not require('baseline.panetabs').is_tabbed()
              end,
            },
          },
          lualine_c = {
            {
              -- Per-pane buffer tabs on tagged panes, heart banner elsewhere.
              function()
                return require('baseline.panetabs').winbar()
              end,
              padding = 0, -- flush at col 0 so row-2 overlay lines up
              color = { fg = require('baseline.banners').config.fg, gui = 'bold' },
            },
          },
        },

        inactive_winbar = {
          lualine_c = {
            {
              function()
                return require('baseline.panetabs').winbar()
              end,
              padding = 0, -- flush at col 0 so row-2 overlay lines up
              color = { fg = require('baseline.banners').config.fg, gui = 'bold' },
            },
          },
        },
      })

      -- Keep the colored mode sections (red 'a'/'z', yellow 'b'/'y') but make
      -- the center/title bars transparent. lualine's own center fill already
      -- rides on lualine_c (bg=NONE). What's left are the *native* statusline,
      -- winbar and tabline groups, which the colorscheme repaints to black/gray.
      -- The colorscheme is applied AFTER this config runs, so reapply on every
      -- ColorScheme event (and once now) to keep these groups transparent.
      local function transparent_bars()
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

      vim.api.nvim_create_autocmd('ColorScheme', {
        group = vim.api.nvim_create_augroup('TransparentBars', { clear = true }),
        callback = transparent_bars,
      })
      transparent_bars()
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
    dependencies = { 'MunifTanjim/nui.nvim', 'rcarriga/nvim-notify' },
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
