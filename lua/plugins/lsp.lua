return {
  {
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'mason-org/mason.nvim', opts = {} },
      'mason-org/mason-lspconfig.nvim',
      'hrsh7th/cmp-nvim-lsp',
      'SmiteshP/nvim-navic',
    },
    config = function()
      -- Completion capabilities for every server
      vim.lsp.config('*', {
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
      })

      -- Vue 3 + vtsls wiring: vtsls handles TypeScript inside .vue files via
      -- the Vue TS plugin, and vue_ls forwards its tsserver requests to vtsls.
      local vue_language_server_path =
        vim.fn.expand('$MASON/packages') .. '/vue-language-server/node_modules/@vue/language-server'

      vim.lsp.config('vtsls', {
        settings = {
          vtsls = {
            tsserver = {
              globalPlugins = {
                {
                  name = '@vue/typescript-plugin',
                  location = vue_language_server_path,
                  languages = { 'vue' },
                  configNamespace = 'typescript',
                },
              },
            },
          },
        },
        filetypes = { 'typescript', 'javascript', 'javascriptreact', 'typescriptreact', 'vue' },
      })

      vim.lsp.config('vue_ls', {
        on_init = function(client)
          client.handlers['tsserver/request'] = function(_, result, context)
            local clients = vim.lsp.get_clients({ bufnr = context.bufnr, name = 'vtsls' })
            if #clients == 0 then
              vim.notify('Could not find `vtsls` lsp client, `vue_ls` would not work without it.', vim.log.levels.ERROR)
              return
            end
            local ts_client = clients[1]

            local param = unpack(result)
            local id, command, payload = unpack(param)
            ts_client:exec_cmd({
              title = 'vue_request_forward',
              command = 'typescript.tsserverRequest',
              arguments = {
                command,
                payload,
              },
            }, { bufnr = context.bufnr }, function(_, r)
              -- NOTE: Do NOT bail on error/nil response; notify nil back to
              -- vue_ls to prevent a memory leak.
              local response = r and r.body
              local response_data = { { id, response } }

              ---@diagnostic disable-next-line: param-type-mismatch
              client:notify('tsserver/response', response_data)
            end)
          end
        end,
      })

      -- Installs the servers below and auto-enables every installed server
      require('mason-lspconfig').setup({
        ensure_installed = {
          'astro',
          'cssls',
          'eslint',
          'html',
          'jsonls',
          'lua_ls',
          'tailwindcss',
          'vtsls',
          'vue_ls',
        },
      })

      local signs = { Error = ' ', Warn = ' ', Hint = ' ', Info = ' ' }
      vim.diagnostic.config({
        virtual_text = { prefix = '●' },
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = signs.Error,
            [vim.diagnostic.severity.WARN] = signs.Warn,
            [vim.diagnostic.severity.HINT] = signs.Hint,
            [vim.diagnostic.severity.INFO] = signs.Info,
          },
        },
        underline = true,
        update_in_insert = true,
        severity_sort = true,
        float = { source = true },
      })

      -- Buffer-local keymaps and navic whenever a server attaches
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('lsp_attach', { clear = true }),
        callback = function(args)
          local opts = { buffer = args.buf, silent = true }
          vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
          vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
          vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
          vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
          vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
          vim.keymap.set('v', '<leader>ca', vim.lsp.buf.code_action, opts)
          vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
          vim.keymap.set('n', '<leader>gr', vim.lsp.buf.references, opts)
          vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, opts)
          vim.keymap.set('n', '[d', function() vim.diagnostic.jump({ count = -1 }) end, opts)
          vim.keymap.set('n', ']d', function() vim.diagnostic.jump({ count = 1 }) end, opts)
          vim.keymap.set('i', '<C-k>', vim.lsp.buf.signature_help, opts)

          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client and client.server_capabilities.documentSymbolProvider then
            require('nvim-navic').attach(client, args.buf)
          end
        end,
      })
    end,
  },

  -- LSP UIs (finder, peek, rename, diagnostics)
  {
    'nvimdev/lspsaga.nvim',
    event = 'LspAttach',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function()
      require('lspsaga').setup({
        ui = {
          border = 'rounded',
        },
        symbol_in_winbar = {
          enable = false,
        },
        lightbulb = {
          enable = false,
        },
        outline = {
          layout = 'float',
        },
      })

      local opts = { silent = true }
      -- NB: no <C-j> map here. Ctrl+h/j/k/l are pane navigation (baseline.maps),
      -- and this runs on LspAttach -- a global <C-j> here would shadow pane-down in
      -- every LSP buffer. Diagnostics are still navigable via ]d / [d (see above).
      vim.keymap.set('n', 'gl', '<Cmd>Lspsaga show_line_diagnostics<CR>', opts)
      vim.keymap.set('n', 'gt', '<Cmd>Lspsaga goto_type_definition<CR>', opts)
      vim.keymap.set('n', 'gp', '<Cmd>Lspsaga peek_definition<CR>', opts)
      vim.keymap.set('n', 'gr', '<Cmd>Lspsaga rename<CR>', opts)
    end,
  },
}
