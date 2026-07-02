return {
  {
    'nvim-treesitter/nvim-treesitter',
    -- NOTE: the 'main' rewrite requires Neovim 0.12 (nightly); 'master' is
    -- the maintained-for-0.11 branch. Switch to 'main' after upgrading.
    branch = 'master',
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter.configs').setup({
        ensure_installed = {
          'bash', 'css', 'fish', 'html', 'javascript', 'json', 'lua',
          'markdown', 'markdown_inline', 'php', 'regex', 'ruby',
          'toml', 'tsx', 'typescript', 'vue', 'yaml',
        },
        highlight = { enable = true },
      })
    end,
  },

  -- Auto-close/rename HTML tags. Only relevant while editing, so load on the
  -- first insert rather than sourcing its plugin file at startup (~14ms saved).
  { 'windwp/nvim-ts-autotag', event = 'InsertEnter', opts = {} },

  -- Embedded-language commentstring (consumed by Comment.nvim in editor.lua)
  {
    'JoosepAlviste/nvim-ts-context-commentstring',
    init = function()
      vim.g.skip_ts_context_commentstring_module = true
    end,
    opts = {
      enable_autocmd = false,
    },
  },
}
