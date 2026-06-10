return {
  -- Claude Code integration
  {
    'coder/claudecode.nvim',
    dependencies = { 'folke/snacks.nvim' },
    config = function()
      require('claudecode').setup({
        terminal_cmd = 'claude',
        log_level = 'info',
        auto_start = true,
        terminal = {
          provider = 'native',
          split_side = 'right',
        },
      })

      local opts = { silent = true }
      vim.keymap.set('n', '<leader>ac', '<Cmd>ClaudeCode<CR>', vim.tbl_extend('force', opts, { desc = 'Toggle Claude Code' }))
      vim.keymap.set('v', '<leader>as', '<Cmd>ClaudeCodeSend<CR>', vim.tbl_extend('force', opts, { desc = 'Send selection to Claude' }))
      vim.keymap.set('n', '<leader>aa', '<Cmd>ClaudeCodeAdd %<CR>', vim.tbl_extend('force', opts, { desc = 'Add file to Claude context' }))
      vim.keymap.set('n', '<leader>dy', '<Cmd>ClaudeCodeDiffAccept<CR>', vim.tbl_extend('force', opts, { desc = 'Accept Claude diff' }))
      vim.keymap.set('n', '<leader>dn', '<Cmd>ClaudeCodeDiffDeny<CR>', vim.tbl_extend('force', opts, { desc = 'Deny Claude diff' }))
    end,
  },
}
