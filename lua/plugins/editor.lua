return {
  -- Fuzzy finding
  {
    'nvim-telescope/telescope.nvim',
    -- Lazy: nothing here is needed until you actually open a picker, so load on
    -- first use rather than at startup (saves ~15ms + the file_browser require).
    cmd = 'Telescope',
    keys = {
      { '<leader>ff', desc = 'Telescope find files' },
      { '<leader>fg', desc = 'Telescope live grep' },
      { '<leader>fb', desc = 'Telescope buffers' },
      { '<leader>fh', desc = 'Telescope help tags' },
      { '<leader>fe', desc = 'Telescope file browser' },
    },
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-file-browser.nvim',
    },
    config = function()
      local telescope = require('telescope')

      telescope.setup({
        defaults = {
          file_ignore_patterns = { 'node_modules' },
        },
      })

      telescope.load_extension('file_browser')

      local builtin = require('telescope.builtin')

      vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Telescope find files' })
      vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Telescope live grep' })
      vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope buffers' })
      vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Telescope help tags' })
      -- <leader>fe, not <C-t>: Ctrl-T is the Chrome "new tab" shortcut (baseline.panetabs).
      vim.keymap.set('n', '<leader>fe', '<Cmd>Telescope file_browser<CR>', { desc = 'Telescope file browser' })
    end,
  },

  -- File explorer
  {
    'nvim-tree/nvim-tree.lua',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function()
      local api = require('nvim-tree.api')

      local function on_attach(bufnr)
        local function opts(desc)
          return {
            desc = 'nvim-tree: ' .. desc,
            buffer = bufnr,
            silent = true,
            nowait = true,
          }
        end

        -- Default open mappings: opened files persist as tabs in the code
        -- pane's winbar (baseline.panetabs) rather than replacing each other.
        api.config.mappings.default_on_attach(bufnr)

        vim.keymap.set('n', '<C-t>', api.tree.change_root_to_parent, opts('Up'))
        vim.keymap.set('n', '?', api.tree.toggle_help, opts('Help'))
      end

      require('nvim-tree').setup({
        on_attach = on_attach,
        view = {
          -- Fixed default width (shared with baseline.layout so the column it sizes
          -- and nvim-tree agree). adaptive_size is left off so the tree never
          -- auto-resizes to its content on refresh; preserve_window_proportions
          -- keeps a manual resize from disturbing sibling panes. :LayoutReset
          -- restores this width on demand.
          width = require('baseline.layout').TREE_WIDTH,
          preserve_window_proportions = true,
        },
      })

      -- Startup tree placement is handled by baseline.layout (centre column for
      -- a bare `nvim`, side panel when files are passed).
    end,
  },

  -- Auto-close brackets and quotes
  {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    opts = {
      disable_filetype = { 'TelescopePrompt', 'vim' },
    },
  },

  -- Context-aware commenting (uses treesitter for vue/tsx embedded languages)
  {
    'numToStr/Comment.nvim',
    -- Lazy: load the first time a comment mapping is pressed.
    keys = {
      { 'gcc', mode = 'n', desc = 'Comment toggle current line' },
      { 'gbc', mode = 'n', desc = 'Comment toggle current block' },
      { 'gc', mode = { 'n', 'x' }, desc = 'Comment toggle linewise' },
      { 'gb', mode = { 'n', 'x' }, desc = 'Comment toggle blockwise' },
    },
    dependencies = { 'JoosepAlviste/nvim-ts-context-commentstring' },
    config = function()
      require('Comment').setup({
        pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
      })
    end,
  },
}
