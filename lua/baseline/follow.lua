-- Make a "viewer" window replay every file Claude touches under the working dir
-- as a typing animation, without moving focus. A timer polls (via a non-blocking
-- `find`) for all files modified since the follower started, queues each change,
-- and plays them back one at a time in the viewer window. Files that already
-- existed at startup are ignored until Claude edits them, so it won't hijack the
-- initial README. Toggle with :FollowClaude.
--
-- Why a replay works: by the time we poll, Claude's edit is already complete on
-- disk, so we have both endpoints -- the previous snapshot (or empty, for a file
-- we've never shown) and the new file -- and can type the change out. The replay
-- is destructive on the *mirror buffer* only, which is safe: Claude writes the
-- disk file, never this buffer, and we reload the real file from disk (`edit!`)
-- as the final commit, discarding any animation artifacts.
--
-- The budget scales chars-per-tick to the change size, so typing a brand-new
-- 500-line file finishes in roughly the same time as a one-line diff.

local uv = vim.uv
local M = {}

M.config = {
  enabled = true,
  interval = 1000, -- poll period in ms
  prune = { '.git', 'node_modules', '.cache' }, -- directories to ignore
  animate = true, -- replay edits as a typing animation
  char_interval = 18, -- typing tick period in ms
  budget_ticks = 40, -- target number of ticks per file (scales typing speed)
}

-- `seen` maps path -> last processed mtime so we re-queue a file only when it
-- actually changes. `queue`/`queued` is the ordered playback queue (with a set
-- for dedupe). `snap` maps path -> the lines last shown, used as the "before"
-- for the next edit. `dirty` is the buffer an animation made modified, tracked
-- so we can clean it before any plain reload.
local state = {
  win = nil,
  timer = nil,
  anim = nil,
  start = 0,
  scanning = false,
  animating = false,
  seen = {},
  queue = {},
  queued = {},
  snap = {},
  dirty = nil,
}

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

local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- The changed span between two line tables: returns the first changed line `f`,
-- the last changed OLD line `old_end`, and the last changed NEW line `new_end`
-- (all 1-based). An empty old span (old_end < f) is a pure insertion; an empty
-- new span is a pure deletion. Returns nil when the contents are identical.
local function diff_range(old, new)
  local on, nn = #old, #new
  local f = 1
  while f <= math.min(on, nn) and old[f] == new[f] do
    f = f + 1
  end
  if f > on and f > nn then
    return nil -- identical
  end
  local t = 0
  while t < (math.min(on, nn) - f + 1) and old[on - t] == new[nn - t] do
    t = t + 1
  end
  return f, on - t, nn - t
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

-- Drop the "we made this buffer modified" flag so a subsequent plain `:edit`
-- isn't blocked. The buffer is a disk mirror, so this loses nothing the next
-- reload won't restore.
local function clear_dirty()
  if state.dirty and vim.api.nvim_buf_is_valid(state.dirty) then
    pcall(function()
      vim.bo[state.dirty].modified = false
    end)
  end
  state.dirty = nil
end

local function stop_anim()
  if state.anim then
    state.anim:stop()
    state.anim:close()
    state.anim = nil
  end
end

local drain -- forward declaration (finish_step -> drain -> process -> finish_step)

-- Mark the current playback step done and schedule the next. Scheduling (rather
-- than calling drain directly) avoids deep recursion when many files are no-ops.
local function finish_step()
  state.animating = false
  vim.schedule(function()
    if drain then
      drain()
    end
  end)
end

-- Commit a step: discard scratch edits, reload the real file from disk (clears
-- `modified`, re-applies filetype), jump the cursor, then advance the queue.
local function reload_real(win, path, new_lines, jump_line)
  clear_dirty()
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, 'edit!')
  end)
  state.snap[path] = new_lines
  if jump_line then
    move_cursor(win, jump_line)
  end
  finish_step()
end

-- Replay `before` -> `after` as a typing animation in the viewer (which is
-- already editing `path`): establish the before state on screen, then type the
-- changed block in, then commit via reload_real.
local function animate(win, path, before, after)
  local buf = vim.api.nvim_win_get_buf(win)
  state.dirty = buf
  pcall(function()
    vim.bo[buf].modifiable = true
  end)
  -- Show the "before" (empty for a file we've never displayed).
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, before)

  local f, old_end, new_end = diff_range(before, after)
  if not f then
    reload_real(win, path, after, 1)
    return
  end

  local block = {} -- the new lines to type into the gap
  for i = f, new_end do
    block[#block + 1] = after[i]
  end
  if #block == 0 then -- pure deletion: nothing to type
    reload_real(win, path, after, f)
    return
  end

  -- Remove the old changed lines, leaving prefix + suffix; we type the block in.
  pcall(vim.api.nvim_buf_set_lines, buf, f - 1, old_end, false, {})

  local total = 0
  for _, l in ipairs(block) do
    total = total + #l
  end
  local per = math.max(2, math.floor(total / math.max(1, M.config.budget_ticks)))

  local li, ci = 1, 0
  local base = f - 1 -- 0-based row where the block starts

  stop_anim()
  state.anim = uv.new_timer()
  state.anim:start(
    0,
    M.config.char_interval,
    vim.schedule_wrap(function()
      if not state.animating or not (win and vim.api.nvim_win_is_valid(win)) then
        stop_anim()
        return
      end
      if li > #block then
        stop_anim()
        reload_real(win, path, after, f)
        return
      end
      local row = base + (li - 1)
      if ci == 0 then
        pcall(vim.api.nvim_buf_set_lines, buf, row, row, false, { '' })
      end
      local line = block[li]
      if #line > 0 then
        local chunk = line:sub(ci + 1, ci + per)
        pcall(vim.api.nvim_buf_set_text, buf, row, ci, row, ci, { chunk })
        ci = ci + #chunk
      end
      if ci >= #line then
        li, ci = li + 1, 0
      end
      move_cursor(win, row + 1)
    end)
  )
end

-- Play one queued file: open it in the viewer, then animate (or snap) the change
-- from its last snapshot (or empty) to the current disk contents.
local function process(path)
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    finish_step()
    return
  end

  local ok, new_lines = pcall(vim.fn.readfile, path)
  if not ok or not new_lines then
    finish_step()
    return
  end

  local old_lines = state.snap[path] or {}

  -- Open the file in the viewer (this creates a listed buffer for it).
  clear_dirty()
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
  end)
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= path then
    finish_step() -- load didn't take
    return
  end

  -- No visible change (e.g. mtime touched but content identical): just record.
  if same_lines(old_lines, new_lines) then
    state.snap[path] = new_lines
    finish_step()
    return
  end

  if M.config.animate then
    animate(win, path, old_lines, new_lines)
  else
    local line = first_diff(old_lines, new_lines)
    if line then
      move_cursor(win, line)
    end
    state.snap[path] = new_lines
    finish_step()
  end
end

-- Pop the next queued file and play it, one at a time.
drain = function()
  if state.animating or not M.config.enabled then
    return
  end
  local path = table.remove(state.queue, 1)
  if not path then
    return
  end
  state.queued[path] = nil
  state.animating = true
  process(path)
end

local function enqueue(path)
  if not state.queued[path] then
    state.queued[path] = true
    state.queue[#state.queue + 1] = path
  end
end

local function on_result(res)
  state.scanning = false
  if res.code ~= 0 or not res.stdout or res.stdout == '' then
    return
  end
  -- `find` output is sorted ascending by mtime, so we queue in edit order.
  for ln in res.stdout:gmatch('[^\n]+') do
    local mtime, path = ln:match('^(%S+)%s+(.+)$')
    mtime = tonumber(mtime)
    if mtime and path and mtime > state.start then
      if not state.seen[path] or mtime > state.seen[path] then
        state.seen[path] = mtime
        enqueue(path)
      end
    end
  end
  drain()
end

-- `find <cwd> -type f <prunes> -newermt @<start> -printf '<mtime> <path>\n' | sort -n`
local function build_cmd()
  local prunes = {}
  for _, d in ipairs(M.config.prune) do
    prunes[#prunes + 1] = '-not -path ' .. vim.fn.shellescape('*/' .. d .. '/*')
  end
  local sh = 'find '
    .. vim.fn.shellescape(uv.cwd())
    .. ' -type f '
    .. table.concat(prunes, ' ')
    .. ' -newermt '
    .. vim.fn.shellescape('@' .. tostring(state.start))
    .. " -printf '%T@ %p\\n' 2>/dev/null | sort -n"
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
  state.scanning = false
  state.animating = false
  state.seen = {}
  state.queue = {}
  state.queued = {}
  state.snap = {}
  -- Highlight the viewer's current line so the typed-into region stands out.
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
  stop_anim()
  clear_dirty()
  stop_timer()
  state.animating = false
  state.queue = {}
  state.queued = {}
  state.win = nil
end

return M
