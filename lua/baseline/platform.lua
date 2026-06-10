-- OS-specific clipboard integration
if vim.fn.has('wsl') == 1 then
  vim.api.nvim_create_autocmd('TextYankPost', {
    group = vim.api.nvim_create_augroup('wsl_yank', { clear = true }),
    callback = function()
      vim.fn.system('/mnt/c/windows/system32/clip.exe', vim.fn.getreg('"'))
    end,
  })
elseif vim.fn.has('win32') == 1 then
  vim.opt.clipboard:prepend { 'unnamed', 'unnamedplus' }
else -- Linux and macOS
  vim.opt.clipboard:append { 'unnamedplus' }
end
