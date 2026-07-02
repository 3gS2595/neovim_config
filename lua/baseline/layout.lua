-- Default startup layout: a left area (code + tree over a shared terminal) and a
-- full-height Claude column on the right.
--
--   +-----------+-----------+-----------+
--   |           | +portrait |           |
--   | code view | (top)     |           |
--   |  (top)    | file tree |  claude   |
--   |           |           | (right,   |
--   |           |           |  full     |
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

-- Fixed default width for the file-tree column. nvim-tree's adaptive_size is off
-- (see plugins/editor.lua) and we no longer size the column to its content, so the
-- tree keeps this width and never resizes itself. editor.lua reads M.TREE_WIDTH so
-- there's a single source of truth.
M.TREE_WIDTH = 31

-- Remembered window handles and the sizes computed at startup, so :LayoutReset can
-- restore the startup proportions on demand. Populated by fit_layout_to_fastfetch.
local layout_state = nil

-- Pin the tree column to the fixed default width, bounded only by the terminal's
-- OWN total width (never by the fastfetch-measured left_w) -- that's the whole
-- point of a fixed width: it must not shrink just because the splash logo happens
-- to be narrow. Exposed standalone (not folded into apply_sizes) so build() can
-- pin it immediately, synchronously, rather than waiting on the async fastfetch
-- measurement that drives the rest of apply_sizes.
local function apply_tree_width(treecol)
  if treecol and vim.api.nvim_win_is_valid(treecol) then
    pcall(vim.api.nvim_win_set_width, treecol, math.max(12, math.min(vim.o.columns - 20, M.TREE_WIDTH)))
  end
end

-- Apply the startup pane sizes from layout_state: Claude takes everything outside
-- the left area, the tree column is the fixed default width, and the bottom terminal
-- is the splash height. Used both on first build and by :LayoutReset.
local function apply_sizes()
  local s = layout_state
  if not s then return end
  if vim.api.nvim_win_is_valid(s.claude) then
    pcall(vim.api.nvim_win_set_width, s.claude, math.max(1, vim.o.columns - s.left_w - 1))
  end
  apply_tree_width(s.treecol)
  if vim.api.nvim_win_is_valid(s.bottom) then
    pcall(vim.api.nvim_win_set_height, s.bottom, s.bottom_height)
  end
end

-- The bottom terminal window that shows the fastfetch splash, so baseline.splash_images
-- can anchor kitty images over it. Read-only handle; nil until the layout is built.
function M.splash_win()
  return layout_state and layout_state.bottom
end

-- Restore the panes to their startup sizes (tree width, Claude width, bottom
-- terminal height). Exposed as the :LayoutReset user command.
function M.reset()
  if not layout_state then
    vim.notify('LayoutReset: no startup layout to restore', vim.log.levels.WARN)
    return
  end
  apply_sizes()
end

-- The startup milestones the splash bar tracks, in the order they're shown.
-- Order MUST match the order build() calls splash.complete() in, so the status
-- label always names the step actually in flight: plugins, then the Claude
-- terminal, then the window juggling, then the async portrait + fastfetch tail.
local SPLASH_STEPS = {
  { key = 'plugins', label = 'loading plugins' },
  { key = 'claude', label = 'starting claude' },
  { key = 'layout', label = 'building layout' },
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
    -- The tree column inside the left area is the fixed M.TREE_WIDTH (no
    -- content-based sizing), so it keeps its width and never resizes itself.
    local left_w = math.max(20, math.min(maxw, vim.o.columns - 20))

    -- Height of the bottom terminal: enough rows to show the splash (which is
    -- `left_w` wide, so account for wrapping) plus the resting prompt line.
    local rows = 0
    for _, line in ipairs(vim.split(res.stdout or '', '\n', { trimempty = false })) do
      local clean = line:gsub('\27%[[0-9;]*m', '')
      if clean ~= '' then
        rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(clean) / left_w))
      end
    end
    local bottom_height = math.max(3, math.min(vim.o.lines - 6, rows + 2))

    -- Remember the startup sizes + windows so :LayoutReset can restore them, then
    -- apply them.
    layout_state = {
      claude = claude,
      bottom = bottom,
      treecol = treecol,
      left_w = left_w,
      bottom_height = bottom_height,
    }
    apply_sizes()

    -- The left area is now `left_w` wide: render the splash into the bottom terminal
    -- (no wrap as long as left_w >= maxw).
    if bottom_job then
      pcall(vim.api.nvim_chan_send, bottom_job, 'command clear; fastfetch\n')
    end

    -- Splash rendered: the last startup milestone is done.
    splash.complete('fastfetch')
  end))
end

-- Look for a `notes.md` at the base of the repo (git top-level, falling back to
-- the cwd). Returns its absolute path if it exists, otherwise nil. Used so the
-- code view opens on your notes instead of a blank buffer when one is present.
local function repo_notes_path()
  local root = vim.loop.cwd()
  local out = vim.fn.systemlist({ 'git', '-C', root, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
    root = out[1]
  end
  local path = root .. '/notes.md'
  if vim.loop.fs_stat(path) then
    return path
  end
  return nil
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
  -- Tagged (not inferred from the buffer name): open_terminal spawns a plain
  -- shell and TYPES the claude command into it afterwards, so the terminal
  -- buffer's name is permanently "...:/bin/zsh" (or whatever $SHELL is), never
  -- "claude" -- baseline.scrollguard needs a reliable way to find this window.
  vim.api.nvim_win_set_var(claude, 'is_claude_pane', true)
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

  -- If the repo has a notes.md at its base, open it in the code view in place of
  -- the bare [No Name] buffer, so you land on your notes ready to edit.
  local notes = repo_notes_path()
  if notes then
    vim.api.nvim_win_call(code, function()
      vim.cmd('edit ' .. vim.fn.fnameescape(notes))
    end)
  end

  -- Equalise so the three columns start evenly; fit_layout_to_fastfetch then sets
  -- the final widths (left area = fastfetch's natural width, Claude the rest) once
  -- it has measured the splash.
  vim.api.nvim_set_current_win(code)
  vim.cmd('wincmd =')
  -- wincmd = just equalised the tree column away from its fixed width; pin it back
  -- immediately rather than waiting on fit_layout_to_fastfetch's async measurement
  -- (which can be slow, or never land if the fastfetch script fails), so the tree
  -- is never left sitting at the equalised width.
  apply_tree_width(treecol)
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
  -- Restore the startup pane proportions (tree width, Claude width, bottom
  -- terminal height) after any manual resizing.
  vim.api.nvim_create_user_command('LayoutReset', M.reset, {
    desc = 'Reset pane sizes to the startup layout defaults',
  })

  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('StartupLayout', { clear = true }),
    callback = function()
      if vim.fn.argc() > 0 then
        -- Opened with file(s): keep the plain side-panel tree, no splash.
        pcall(vim.cmd, 'NvimTreeOpen')
        return
      end
      -- Hold the portrait heads back before the splash even goes up: kitty images
      -- are composited by the terminal, not Neovim, so they'd otherwise bleed
      -- through the splash's blank (transparent) cells while it's still covering
      -- the window juggling. Reopened by portrait.lua's own 'SplashClosed' listener.
      require('baseline.portrait').hold_reveal()
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
