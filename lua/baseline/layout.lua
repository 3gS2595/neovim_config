-- Default startup layout: a left area (code + tree over a shared terminal) and a
-- full-height Claude column on the right.
--
--   +-----------+-----------+-----------+
--   |           | +portrait |           |
--   | code view | (top)     |           |
--   |  (top)    | file tree |  claude   |
--   |           | +portrait | (right,   |
--   |           | (bottom)  |  full     |
--   +-----------+-----------+  height)  |
--   |   terminal (spans     |           |
--   |   under code + tree)  |           |
--   +-----------------------+-----------+
--
-- Built on VimEnter, but only for a bare `nvim` (no file arguments) so it does
-- not hijack `nvim <file>`, git commit editors, pagers, etc. When files are
-- passed we fall back to opening the tree on the side (the previous behaviour).

local M = {}

local splash = require('baseline.splash')

-- The startup milestones the splash bar tracks, in the order they're shown.
local SPLASH_STEPS = {
  { key = 'plugins', label = 'loading plugins' },
  { key = 'layout', label = 'building layout' },
  { key = 'claude', label = 'starting claude' },
  { key = 'portrait', label = 'loading portrait sprite sheet' },
  { key = 'fastfetch', label = 'rendering splash' },
}

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

local FLOWERFETCH = vim.fn.expand('$HOME/.config/fastfetch/flowerfetch.sh')

-- Auto-size the left area to the MINIMUM width that fits the fastfetch splash
-- without wrapping, render the splash into the bottom terminal at that width, then
-- shrink the pane to the splash height + the resting prompt line. We render
-- flowerfetch once off-screen (COLUMNS huge, so it can't self-wrap) to learn its
-- natural width (widest line) and line count; set the left area to that width
-- (Claude absorbs the rest); and only THEN send the splash to the bottom terminal,
-- so it renders at the final width and never wraps. Deterministic and async, so
-- startup isn't blocked while fastfetch renders.
local function fit_layout_to_fastfetch(claude, bottom, bottom_job, treecol)
  vim.system({ 'bash', FLOWERFETCH }, { env = { COLUMNS = '1000' }, text = true }, vim.schedule_wrap(function(res)
    local maxw, count = 0, 0
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { trimempty = false })) do
      -- Strip SGR colour codes, then measure display columns (handles the wide
      -- braille/box-drawing glyphs in the logo).
      local clean = line:gsub('\27%[[0-9;]*m', '')
      if clean ~= '' then
        count = count + 1
        maxw = math.max(maxw, vim.fn.strdisplaywidth(clean))
      end
    end
    if count == 0 then return end

    -- Width: left area = fastfetch's natural width; Claude takes the rest. Cap so
    -- Claude keeps a usable minimum on a narrow screen (-1 for the column divider).
    local left_w = math.max(20, math.min(maxw, vim.o.columns - 20))
    if vim.api.nvim_win_is_valid(claude) then
      pcall(vim.api.nvim_win_set_width, claude, math.max(1, vim.o.columns - left_w - 1))
    end

    -- Within the left area, make the tree column only as wide as its widest entry
    -- (so no file-tree item is clipped) and let the code view absorb the rest. We
    -- size it once from the rendered tree buffer rather than nvim-tree's
    -- adaptive_size (which refights every refresh). textoff accounts for the tree's
    -- signcolumn/gutter; cap so the code view keeps a usable minimum.
    if treecol and vim.api.nvim_win_is_valid(treecol) then
      local tbuf = vim.api.nvim_win_get_buf(treecol)
      local content = 0
      for _, l in ipairs(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)) do
        content = math.max(content, vim.fn.strdisplaywidth(l))
      end
      local info = vim.fn.getwininfo(treecol)[1]
      local gutter = (info and info.textoff) or 0
      local tw = math.max(12, math.min(content + gutter, left_w - 20))
      pcall(vim.api.nvim_win_set_width, treecol, tw)
    end

    -- Now the bottom terminal is `left_w` wide: render the splash there (no wrap as
    -- long as left_w >= maxw) and size the pane to fit it + the resting prompt line.
    if bottom_job then
      pcall(vim.api.nvim_chan_send, bottom_job, 'command clear; fastfetch\n')
    end
    if vim.api.nvim_win_is_valid(bottom) then
      local rows = 0
      for _, line in ipairs(vim.split(res.stdout or '', '\n', { trimempty = false })) do
        local clean = line:gsub('\27%[[0-9;]*m', '')
        if clean ~= '' then
          rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(clean) / left_w))
        end
      end
      pcall(vim.api.nvim_win_set_height, bottom, math.max(3, math.min(vim.o.lines - 6, rows + 2)))
    end

    -- Splash rendered: the last startup milestone is done.
    splash.complete('fastfetch')
  end))
end

local function build()
  -- Predictable split directions: new splits go right / below.
  vim.o.splitright = true
  vim.o.splitbelow = true
  -- Manual pane sizes must stick. With equalalways (the default) Neovim re-equalises
  -- every split/close, which fights deliberate resizes; we size the panes ourselves.
  vim.o.equalalways = false

  -- Plugins finished loading before VimEnter fired; mark it as the first tick.
  splash.complete('plugins')

  local code = vim.api.nvim_get_current_win()
  -- Top-left pane keeps the bare-`nvim` empty [No Name] buffer (a blank file) so
  -- the code view opens ready to type in, not on the README. Every pane lists its
  -- buffers as tabs automatically (baseline.panetabs derives the role from the
  -- buffer), so no pane needs tagging here.

  -- Right column: a full-height terminal running Claude. It shares the terminal
  -- tabs with the bottom terminal (every terminal pane lists all terminals).
  vim.cmd('vsplit')
  local claude = vim.api.nvim_get_current_win()
  open_terminal('claude --dangerously-skip-permissions')
  splash.complete('claude')

  -- Left area, bottom: a terminal showing just the fastfetch splash, then the
  -- resting prompt. Split off the code window BEFORE the code|tree split so it
  -- spans the full width below both of them. We open it WITHOUT a command and let
  -- fit_layout_to_fastfetch render the splash later — only after the left area has
  -- been sized to fastfetch's natural width, so it renders without wrapping. (The
  -- `command clear` it sends wipes the auto splash+ls the interactive shell prints
  -- on startup; `fastfetch` reprints only the splash.)
  vim.api.nvim_set_current_win(code)
  vim.cmd('split')
  local bottom = vim.api.nvim_get_current_win()
  open_terminal()
  local bottom_job = vim.b.terminal_job_id

  -- Top row of the left area: portrait + file tree + portrait (left) | code view (right).
  -- vsplit (splitright) opens the new window to the right and focuses it; that new
  -- window becomes the code view, and the original window becomes the tree column.
  vim.api.nvim_set_current_win(code)
  vim.cmd('vsplit')
  local newcode = vim.api.nvim_get_current_win()
  local treecol = code -- original (left) window -> tree column
  require('baseline.portrait').setup_center(treecol)
  code = newcode -- the right window is now the code view (follow + focus track it)

  -- Equalise so the three columns start evenly; fit_layout_to_fastfetch then sets
  -- the final widths (left area = fastfetch's natural width, Claude the rest) once
  -- it has measured the splash.
  vim.api.nvim_set_current_win(code)
  vim.cmd('wincmd =')
  splash.complete('layout')

  -- Size the left area to fit the fastfetch splash without wrapping, render it into
  -- the bottom terminal, shrink that pane to the splash height + prompt line, and
  -- give the code view the larger share of the left area (tree column the smaller).
  fit_layout_to_fastfetch(claude, bottom, bottom_job, treecol)

  -- Keep the code view following whatever file gets edited (e.g. by Claude in
  -- the right terminal) without stealing focus from the terminal.
  require('baseline.follow').start(code)
end

function M.setup()
  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('StartupLayout', { clear = true }),
    callback = function()
      if vim.fn.argc() > 0 then
        -- Opened with file(s): keep the plain side-panel tree, no splash.
        pcall(vim.cmd, 'NvimTreeOpen')
        return
      end
      -- Paint the splash synchronously (before the deferred build) so it covers
      -- the window juggling, and advance its bar when the portrait sheet lands.
      splash.show(SPLASH_STEPS)
      vim.api.nvim_create_autocmd('User', {
        pattern = 'PortraitReady',
        once = true,
        callback = function()
          splash.complete('portrait')
        end,
      })
      -- Defer so the rest of startup settles before we reshape the windows.
      vim.schedule(build)
    end,
  })
end

return M
