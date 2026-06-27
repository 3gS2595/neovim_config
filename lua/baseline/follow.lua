-- Make a "viewer" window follow whatever file is edited under the working dir
-- (e.g. the files Claude writes from the terminal). A timer polls for the most
-- recently modified file via an async `find` subprocess (non-blocking) and,
-- when it changes, loads it into the viewer window WITHOUT moving focus. Files
-- that already existed at startup are ignored, so it won't hijack the initial
-- README; only edits made after the follower starts are tracked.
--
-- This mirrors the filesystem, not Claude's intent: it snaps to the newest
-- write, so unrelated churn (build output, caches) can pull it around. Tune the
-- pruned directories in M.config.prune. Toggle with :FollowClaude.

local uv = vim.uv
local bufutil = require('baseline.bufutil')
local M = {}

M.config = {
  enabled = true,
  interval = 1000, -- poll period in ms
  prune = { '.git', 'node_modules', '.cache' }, -- directories to ignore
}

-- `snap` remembers the lines last shown per path so we can locate the first
-- changed line when a file is re-loaded.
local state =
  { win = nil, timer = nil, start = 0, last_path = nil, last_mtime = nil, scanning = false, snap = {} }

-- First line index where `old` and `new` differ (or the first appended line).
-- Returns nil when there's no prior snapshot or the contents are identical.
local function first_diff(old, new)
  if not old then
    return nil
  end
  local n = math.min(#old, #new)
  for i = 1, n do
    if old[i] ~= new[i] then
      return i
    end
  end
  if #new ~= #old then
    return math.max(1, math.min(#old, #new) + (#new > #old and 1 or 0))
  end
  return nil
end

-- Put the viewer's cursor on `line` and centre it, without taking focus.
local function move_cursor(win, line)
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  line = math.max(1, math.min(line, count))
  vim.api.nvim_win_call(win, function()
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    vim.cmd('normal! zz')
  end)
end

-- Load `path` into the viewer window without changing the focused window, jump
-- the viewer's cursor to the changed region, and tidy up the buffer it replaced.
local function show(path)
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local old_buf = vim.api.nvim_win_get_buf(win)
  local same = vim.api.nvim_buf_get_name(old_buf) == path
  local old_lines = state.snap[path]

  vim.api.nvim_win_call(win, function()
    if same then
      pcall(vim.cmd, 'checktime') -- same file: reload if changed on disk
    else
      pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
    end
  end)

  -- Bail if the load didn't take (e.g. unsaved edits blocked the switch).
  local new_buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_get_name(new_buf) ~= path then
    return
  end

  local new_lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
  local line = first_diff(old_lines, new_lines)
  if line then
    move_cursor(win, line)
  end
  state.snap[path] = new_lines

  -- Don't let followed files pile up in the buffer tabline.
  if not same then
    bufutil.wipe_if_unused(old_buf)
  end
end

local function on_result(res)
  state.scanning = false
  if res.code ~= 0 or not res.stdout or res.stdout == '' then
    return
  end
  local mtime, path = vim.trim(res.stdout):match('^(%S+)%s+(.+)$')
  mtime = tonumber(mtime)
  if not (mtime and path) then
    return
  end
  if mtime <= state.start then
    return -- file predates the follower; not a fresh edit
  end
  if path == state.last_path and mtime == state.last_mtime then
    return -- nothing new since last poll
  end
  state.last_path, state.last_mtime = path, mtime
  show(path)
end

-- `find <cwd> -type f <prunes> -printf '<mtime> <path>\n' | sort -n | tail -1`
local function build_cmd()
  local prunes = {}
  for _, d in ipairs(M.config.prune) do
    prunes[#prunes + 1] = '-not -path ' .. vim.fn.shellescape('*/' .. d .. '/*')
  end
  local sh = 'find '
    .. vim.fn.shellescape(uv.cwd())
    .. ' -type f '
    .. table.concat(prunes, ' ')
    .. " -printf '%T@ %p\\n' 2>/dev/null | sort -n | tail -1"
  return { 'sh', '-c', sh }
end

local function scan()
  if not M.config.enabled then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.stop() -- viewer window is gone
    return
  end
  if state.scanning then
    return -- previous find still running
  end
  state.scanning = true
  vim.system(build_cmd(), { text = true }, vim.schedule_wrap(on_result))
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- Begin following: `win` is the viewer window to keep in sync.
function M.start(win)
  vim.o.autoread = true
  state.win = win
  state.start = os.time()
  state.last_path, state.last_mtime = nil, nil
  state.snap = {}
  -- Highlight the viewer's current line so the jumped-to change stands out.
  pcall(vim.api.nvim_set_option_value, 'cursorline', true, { win = win })
  stop_timer()
  state.timer = uv.new_timer()
  state.timer:start(M.config.interval, M.config.interval, vim.schedule_wrap(scan))

  vim.api.nvim_create_user_command('FollowClaude', function(opts)
    if opts.args == 'on' then
      M.config.enabled = true
    elseif opts.args == 'off' then
      M.config.enabled = false
    else
      M.config.enabled = not M.config.enabled
    end
    vim.notify('FollowClaude ' .. (M.config.enabled and 'on' or 'off'))
  end, {
    nargs = '?',
    complete = function()
      return { 'on', 'off', 'toggle' }
    end,
  })
end

function M.stop()
  stop_timer()
  state.win = nil
end

return M
