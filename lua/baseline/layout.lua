-- Default startup layout: three columns.
--
--   +-----------+-----------+-----------+
--   | code view |           |           |
--   |  (top)    | file tree | terminal  |
--   +-----------+ (center)  | (right)   |
--   | terminal  |           |           |
--   | (bottom)  |           |           |
--   +-----------+-----------+-----------+
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

  local panetabs = require('baseline.panetabs')

  local code = vim.api.nvim_get_current_win()
  -- Top-left pane shows the project README when there is one, and lists open
  -- file buffers as tabs in its winbar.
  open_readme()
  panetabs.set_role(code, 'files')

  -- Three columns: code | center | right.
  vim.cmd('vsplit')
  local center = vim.api.nvim_get_current_win()
  vim.cmd('vsplit')
  local right = vim.api.nvim_get_current_win()

  -- Right column: a terminal running Claude. Keep it out of the terminal tabs
  -- so the bottom-left pane's tabs only show terminals you open there.
  vim.api.nvim_set_current_win(right)
  open_terminal('claude --dangerously-skip-permissions')
  panetabs.exclude_buf(vim.api.nvim_get_current_buf())

  -- Center column: the file tree, opened in this window (not its side panel).
  vim.api.nvim_set_current_win(center)
  require('nvim-tree.api').tree.open({ current_window = true })

  -- Left column, bottom half: a terminal running `c`, below the code view. Its
  -- winbar lists terminal buffers as tabs.
  vim.api.nvim_set_current_win(code)
  vim.cmd('split')
  panetabs.set_role(vim.api.nvim_get_current_win(), 'terms')
  open_terminal('c')

  -- Even out the columns and land the cursor in the code view.
  vim.api.nvim_set_current_win(code)
  vim.cmd('wincmd =')

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
