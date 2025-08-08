require'nvim-treesitter'.install { 
  "markdown",
  "regex",
  "markdown_inline",
  "tsx",
  "typescript",
  "toml",
  "fish",
  "php",
  "json",
  "yaml",
  "swift",
  "vue",
  "css",
  "html",
  "lua",
  "bash"
}

vim.api.nvim_create_autocmd('FileType', {
  pattern = { "ruby", "vue", "typescript", "tsx", "javascript" },
  callback = function()
    vim.treesitter.start()
  end,
})
