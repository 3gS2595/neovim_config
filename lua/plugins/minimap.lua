return {
  -- Classic IDE-style code minimap. Renders a scaled-down braille overview of the
  -- buffer in a floating window pinned to the TOP-RIGHT corner of the code pane,
  -- with the current viewport highlighted (relative = 'win'). auto_enable opens it
  -- on real file panes; the structural panes of the layout (the Claude/shell
  -- terminals, the file tree, the portrait squares and the startup splash) are
  -- excluded by filetype so no minimap is drawn over them.
  {
    'gorbit99/codewindow.nvim',
    event = 'VeryLazy',
    config = function()
      local codewindow = require('codewindow')

      codewindow.setup({
        auto_enable = true,
        -- Pin to the top-right of the focused window, not the editor as a whole.
        relative = 'win',
        minimap_width = 6,
        width_multiplier = 4,
        use_lsp = true,
        use_treesitter = true,
        use_git = true,
        show_cursor = true,
        window_border = 'none',
        exclude_filetypes = {
          'NvimTree',
          'portrait',
          'splash',
          'terminal',
          'noice',
          'notify',
          'TelescopePrompt',
        },
      })

      -- <leader>mm toggles it, <leader>mf focuses it (mnemonic: minimap).
      vim.keymap.set('n', '<leader>mm', codewindow.toggle_minimap, { desc = 'Toggle code minimap' })
      vim.keymap.set('n', '<leader>mf', codewindow.toggle_focus, { desc = 'Focus code minimap' })
    end,
  },
}
