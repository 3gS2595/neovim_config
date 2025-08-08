local status, mason = pcall(require, "mason")
if not status then return end

local status2, mason_lspconfig = pcall(require, "mason-lspconfig")
if not status2 then return end

mason.setup()

mason_lspconfig.setup {
  ensure_installed = {
    "vtsls",
    "vue_ls",
    "eslint",
    "lua_ls",
    "jsonls",
    "html",
    "cssls",
    "tailwindcss",
  },
  automatic_installation = true, -- Keep updated
}
