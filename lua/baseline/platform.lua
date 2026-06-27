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
  local in_ssh = vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil
  local has_display = vim.env.DISPLAY ~= nil or vim.env.WAYLAND_DISPLAY ~= nil

  -- On a headless remote box (e.g. SSH from Windows) there's no X/Wayland
  -- server, so xclip/xsel can't reach the clipboard even when installed.
  -- Relay the clipboard through the terminal emulator via OSC 52 instead.
  if in_ssh and not has_display then
    local osc52 = require('vim.ui.clipboard.osc52')

    -- OSC 52 *reads* are unreliable (most terminals refuse them and the
    -- request can hang), so paste from the last yank instead. Pasting
    -- external text is handled by the terminal's own paste (Ctrl+Shift+V).
    local function paste()
      return vim.split(vim.fn.getreg('"'), '\n')
    end

    vim.g.clipboard = {
      name = 'OSC 52',
      copy = {
        ['+'] = osc52.copy('+'),
        ['*'] = osc52.copy('*'),
      },
      paste = {
        ['+'] = paste,
        ['*'] = paste,
      },
    }
  end

  vim.opt.clipboard:append { 'unnamedplus' }
end
