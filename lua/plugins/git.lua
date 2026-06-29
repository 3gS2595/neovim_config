return {
  -- Git signs in the gutter. Load when a real file opens (the startup panes are
  -- empty/terminal buffers), not at startup.
  { 'lewis6991/gitsigns.nvim', event = { 'BufReadPre', 'BufNewFile' }, opts = {} },

  -- Git blame & browse
  {
    'dinhhuy258/git.nvim',
    -- Lazy: load on first use of either mapping.
    keys = {
      { '<Leader>gb', desc = 'Git blame' },
      { '<Leader>go', desc = 'Git browse' },
    },
    config = function()
      require('git').setup({
        keymaps = {
          blame = '<Leader>gb',  -- Open blame window
          browse = '<Leader>go', -- Open file/folder in git repository
        },
      })
    end,
  },
}
