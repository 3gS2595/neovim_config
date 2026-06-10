return {
  -- Git signs in the gutter
  { 'lewis6991/gitsigns.nvim', opts = {} },

  -- Git blame & browse
  {
    'dinhhuy258/git.nvim',
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
