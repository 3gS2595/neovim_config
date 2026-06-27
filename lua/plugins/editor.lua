return {
  -- Fuzzy finding
  {
    'nvim-telescope/telescope.nvim',
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
      vim.keymap.set('n', '<C-t>', '<Cmd>Telescope file_browser<CR>', { desc = 'Telescope file browser' })
    end,
  },

  -- File explorer
  {
    'nvim-tree/nvim-tree.lua',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function()
      local api = require('nvim-tree.api')
      local bufutil = require('baseline.bufutil')

      -- Open the file under the cursor, then wipe the buffer it replaced so that
      -- clicking around the tree doesn't pile up buffers in the tabline. The
      -- replaced buffer is kept if it's modified or shown elsewhere (bufutil).
      local function open_replace()
        local before = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          before[w] = vim.api.nvim_win_get_buf(w)
        end
        api.node.open.edit()
        local w = vim.api.nvim_get_current_win()
        local prev = before[w]
        if prev and prev ~= vim.api.nvim_get_current_buf() then
          bufutil.wipe_if_unused(prev)
        end
      end

      local function on_attach(bufnr)
        local function opts(desc)
          return {
            desc = 'nvim-tree: ' .. desc,
            buffer = bufnr,
            silent = true,
            nowait = true,
          }
        end

        api.config.mappings.default_on_attach(bufnr)

        -- Replace-on-open for the usual "open file" mappings.
        vim.keymap.set('n', '<CR>', open_replace, opts('Open: replace buffer'))
        vim.keymap.set('n', 'o', open_replace, opts('Open: replace buffer'))
        vim.keymap.set('n', '<2-LeftMouse>', open_replace, opts('Open: replace buffer'))

        vim.keymap.set('n', '<C-t>', api.tree.change_root_to_parent, opts('Up'))
        vim.keymap.set('n', '?', api.tree.toggle_help, opts('Help'))
      end

      require('nvim-tree').setup({
        on_attach = on_attach,
        view = {
          adaptive_size = true,
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
    dependencies = { 'JoosepAlviste/nvim-ts-context-commentstring' },
    config = function()
      require('Comment').setup({
        pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
      })
    end,
  },
}
