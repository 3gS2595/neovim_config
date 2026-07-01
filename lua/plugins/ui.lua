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

      -- Heart filler for the status line. The status line and the bottom pane
      -- separator are now the SAME row: the separate bottom heart border that
      -- baseline/banners.lua used to draw one row above the status line is gone,
      -- and instead the status line's middle is filled with the same spaced-heart
      -- pattern as the other dividers, with the mode/diff blocks on the left and
      -- encoding/branch on the right riding on top of it.
      --
      -- lualine gives a component no width hint, so we MEASURE the other sections:
      -- evaluate the whole status line with this filler blanked (the `measuring`
      -- guard makes the nested eval skip us so we don't recurse), which reports the
      -- columns every other section consumes; the remainder is ours to tile with
      -- '♡ ' pairs.
      --
      -- The catch: nvim_eval_statusline must NOT be called from inside the live
      -- status-line render (i.e. from heart_fill while Neovim is drawing the
      -- screen). A re-entrant status-line eval mid-redraw returns inconsistent
      -- widths, so the heart count jitters frame-to-frame and the line visibly
      -- flashes. So heart_fill never measures: it just returns a CACHED string.
      -- The cache is rebuilt by recompute_hearts(), which we only ever call from a
      -- scheduled (post-redraw) context via the autocmds below -- on the events
      -- that actually change a section's width (resize, mode change, diagnostics,
      -- buffer/git changes). When it changes we redrawstatus once to paint it.
      local heart_fg = require('baseline.banners').config.fg
      local heart_cache = ''
      local measuring = false
      local function heart_fill()
        return measuring and '' or heart_cache
      end
      local function recompute_hearts()
        measuring = true
        local ok, res = pcall(vim.api.nvim_eval_statusline, vim.o.statusline, { maxwidth = 0 })
        measuring = false
        local new = ''
        if ok then
          local avail = vim.o.columns - res.width
          if avail >= 2 then
            new = string.rep('♡ ', math.floor(avail / 2))
          end
        end
        if new ~= heart_cache then
          heart_cache = new
          vim.cmd('redrawstatus')
        end
      end

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
          -- The heart filler IS the bottom separator now (see heart_fill above).
          -- padding = 0 so the measured/rendered widths match exactly (an empty
          -- padded component and a filled one would differ otherwise). Add
          -- 'filename' before it here if you want the file name back on this row.
          lualine_c = {
            {
              heart_fill,
              padding = 0,
              color = { fg = heart_fg, gui = 'bold' },
            },
          },
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

      -- Rebuild the heart fill (see heart_fill / recompute_hearts above) out of
      -- the render path. vim.schedule defers to a normal, post-redraw context so
      -- the nvim_eval_statusline measurement is never re-entrant -- the thing that
      -- made the bottom line flash. A pending flag coalesces bursts into one
      -- rebuild, and recompute_hearts only redrawstatus when the count actually
      -- changes, so over-firing these events is cheap.
      --
      -- The fill "not reaching the end" was staleness: a section changed width
      -- but nothing here recomputed, so the cached heart count stayed sized for
      -- the old layout. The list must cover EVERY section that can change width:
      --   mode (a)              -> ModeChanged
      --   diff hunk counts (b)  -> TextChanged/I as you edit, User Gitsigns* once
      --                            gitsigns finishes its async recount, DiffChanged
      --   diagnostics (b)       -> DiagnosticChanged
      --   filetype/encoding (y) -> FileType (set after BufWinEnter), BufEnter
      --   branch (z)            -> User Gitsigns* / BufEnter after a checkout
      --   window/terminal size  -> VimResized, WinResized, Win*/Tab*/BufWinEnter
      -- CursorHold is the idle backstop that repairs anything the above missed
      -- once the user pauses.
      local pending = false
      local function schedule_hearts()
        if pending then
          return
        end
        pending = true
        vim.schedule(function()
          pending = false
          recompute_hearts()
        end)
      end
      local grp = vim.api.nvim_create_augroup('HeartStatusFill', { clear = true })
      vim.api.nvim_create_autocmd({
        'VimResized', 'WinResized', 'WinNew', 'WinClosed', 'WinEnter',
        'ModeChanged', 'DiagnosticChanged', 'BufWinEnter', 'BufEnter',
        'TabEnter', 'VimEnter', 'FileType', 'DiffUpdated',
        'TextChanged', 'TextChangedI', 'CursorHold', 'CursorHoldI',
      }, {
        group = grp,
        callback = schedule_hearts,
      })
      -- gitsigns updates its diff/branch status asynchronously (after a debounce),
      -- so TextChanged fires before the counts settle; this catches the settled
      -- width. Pattern-guarded to gitsigns' own User events only.
      vim.api.nvim_create_autocmd('User', {
        group = grp,
        pattern = { 'GitSignsUpdate', 'GitSignsChanged', 'FugitiveChanged' },
        callback = schedule_hearts,
      })
      schedule_hearts()
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
