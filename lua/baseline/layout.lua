-- Default startup layout: a left area (code + tree over a shared terminal) and a
-- full-height Claude column on the right.
--
--   +-----------+-----------+-----------+
--   | code view | file tree |           |
--   |  (top)    | +portrait |  claude   |
--   |           | (bottom)  | (right,   |
--   +-----------+-----------+  full     |
--   |   terminal (spans     |  height)  |
--   |   under code + tree)  |           |
--   +-----------------------+-----------+
--
-- Built on VimEnter, but only for a bare `nvim` (no file arguments) so it does
-- not hijack `nvim <file>`, git commit editors, pagers, etc. When files are
-- passed we fall back to opening the tree on the side (the previous behaviour).

local M = {}

-- Open an interactive terminal in the current window and, if given, "type" a
-- command into it. We send keystrokes to the shell's channel (rather than
-- `:terminal {cmd}`, which uses a non-interactive `shell -c` that skips your rc)
-- so aliases/functions resolve and the shell stays alive after the command.
local function open_terminal(cmd)
  vim.cmd('terminal')
  if cmd then
    local job = vim.b.terminal_job_id
    -- Defer briefly so the shell has initialised and is reading input.
    vim.defer_fn(function()
      pcall(vim.api.nvim_chan_send, job, cmd .. '\n')
    end, 200)
  end
end

-- Load the working directory's README into the current window, if one exists
-- (exact README.md first, then any case variant). No-op when absent.
local function open_readme()
  local cwd = vim.fn.getcwd()
  for _, pat in ipairs({ '/README.md', '/[Rr][Ee][Aa][Dd][Mm][Ee].md' }) do
    local matches = vim.fn.glob(cwd .. pat, false, true)
    if #matches > 0 then
      vim.cmd('edit ' .. vim.fn.fnameescape(matches[1]))
      return
    end
  end
end

local function build()
  -- Predictable split directions: new splits go right / below.
  vim.o.splitright = true
  vim.o.splitbelow = true
  -- Manual pane sizes must stick. With equalalways (the default) Neovim re-equalises
  -- every split/close, which fights deliberate resizes; we size the panes ourselves.
  vim.o.equalalways = false

  local code = vim.api.nvim_get_current_win()
  -- Top-left pane shows the project README when there is one. Every pane lists
  -- its buffers as tabs automatically (baseline.panetabs derives the role from
  -- the buffer), so no pane needs tagging here.
  open_readme()

  -- Right column: a full-height terminal running Claude. It shares the terminal
  -- tabs with the bottom terminal (every terminal pane lists all terminals).
  vim.cmd('vsplit')
  local claude = vim.api.nvim_get_current_win()
  open_terminal('claude --dangerously-skip-permissions')

  -- Left area, bottom: a terminal running `c`. Split off the code window BEFORE
  -- the code|tree split so it spans the full width below both of them.
  vim.api.nvim_set_current_win(code)
  vim.cmd('split')
  open_terminal('c')

  -- Top row of the left area: code view (left) | file tree + portrait (right).
  vim.api.nvim_set_current_win(code)
  vim.cmd('vsplit')
  local tree = vim.api.nvim_get_current_win()
  require('baseline.portrait').setup_center(tree)

  -- Width: Claude owns the right 50%, the left area (code | tree, over the wide
  -- terminal) shares the other 50%. Equalise first so code|tree split the left half
  -- evenly, then pin Claude to half the screen; the left area absorbs the rest.
  vim.api.nvim_set_current_win(code)
  vim.cmd('wincmd =')
  pcall(vim.api.nvim_win_set_width, claude, math.floor(vim.o.columns / 2))

  -- Keep the code view following whatever file gets edited (e.g. by Claude in
  -- the right terminal) without stealing focus from the terminal.
  require('baseline.follow').start(code)
end

function M.setup()
  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('StartupLayout', { clear = true }),
    callback = function()
      if vim.fn.argc() > 0 then
        -- Opened with file(s): keep the plain side-panel tree.
        pcall(vim.cmd, 'NvimTreeOpen')
        return
      end
      -- Defer so the rest of startup settles before we reshape the windows.
      vim.schedule(build)
    end,
  })
end

return M
