return {
  -- In-buffer markdown rendering (headings, code blocks, tables, checkboxes…)
  {
    'MeanderingProgrammer/render-markdown.nvim',
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'nvim-tree/nvim-web-devicons',
    },
    ft = { 'markdown' },
    opts = {},
  },
}
