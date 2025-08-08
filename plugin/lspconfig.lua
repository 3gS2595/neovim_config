local status, nvim_lsp = pcall(require, "lspconfig")
if not status then return end

local protocol = require('vim.lsp.protocol')

protocol.CompletionItemKind = {
  '', '', '', '', '', '', '', 'ﰮ', '', '',
  '', '', '', '', '﬌', '', '', '', '', '',
  '�蕾', '', '', 'ﬦ', '',
}

-- Define on_attach function for LSP keybindings
local on_attach = function(client, bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }
  vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
  vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
  vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
  vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
  vim.keymap.set('n', '<leader>gr', vim.lsp.buf.references, opts)
  vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, opts)
  vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
  vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
end

local capabilities = require('cmp_nvim_lsp').default_capabilities()

nvim_lsp.tailwindcss.setup({
  on_attach = on_attach,
  capabilities = capabilities,
})

nvim_lsp.cssls.setup({
  on_attach = on_attach,
  capabilities = capabilities,
})

nvim_lsp.astro.setup({
  on_attach = on_attach,
  capabilities = capabilities,
})

-- Updated Diagnostic signs using vim.diagnostic.config
local signs = { Error = " ", Warn = " ", Hint = " ", Info = " " }
for type, icon in pairs(signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" }) -- Deprecated, remove this
end
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
  float = { source = "always" },
})
