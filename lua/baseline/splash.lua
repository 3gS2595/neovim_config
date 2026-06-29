-- Startup splash screen.
--
-- Replaces Neovim's built-in intro with a centered, light-pink ASCII-art title
-- and a loading bar that tracks the REAL expensive startup steps: the lazy
-- plugins, the window layout, the Claude terminal, the portrait SPRITE SHEET
-- transmit (baseline.portrait) and the fastfetch render (baseline.layout).
--
-- It is drawn as ONE full-editor float (zindex high) so it overlays the window
-- juggling baseline.layout does on VimEnter, then dismisses itself once every
-- registered step has reported complete (or a safety timeout fires).
--
--   * baseline.layout calls M.show{...} first thing on a bare `nvim`, then
--     M.complete('<key>') as each milestone lands.
--   * baseline.portrait fires `User PortraitReady` once the sheet is resident;
--     layout maps that to M.complete('portrait').
--
-- Colours / sizing live in M.config. Preview it any time with :Splash.

local api = vim.api
local M = {}

M.config = {
  title_fg = '#ffb6c1', -- light pink (CSS "lightpink") -- the ASCII art
  fill_fg = '#ff8fcf', -- loading bar: completed portion
  empty_fg = '#5c3a4a', -- loading bar: remaining portion
  status_fg = '#ffc8dd', -- percentage + "what it's loading" line
  bar_width = 46, -- bar length in cells
  fill_char = '█',
  empty_char = '░',
  linger_ms = 400, -- how long the full bar lingers before the splash closes
  timeout_ms = 9000, -- absolute safety net: close no matter what after this
  transparent = true, -- bg NONE (on-theme) vs an opaque backdrop
  backdrop = '#140810', -- backdrop colour when transparent = false
}

-- ASCII-art title. Long-bracket strings keep backslashes and both quote styles
-- literal -- do not "fix" the punctuation, it is the art.
M.art = {
[[             \· . _ . ·/    .· ´ ¯ ` ·.‚          .· ´ ¯ ` ·.    \· . _ .·/   \·._ .·/  .· ´ ¯ ` ·. \· . _ . ·· . _ . ·/ ]],
[[ \· . _ .·'/ /        /'   '/         o  |'       '/         o '\    '\      /'  .·´   .·´'   `· . _ . ·´  '\                '/'  ]],
[[  |        \/        /     |    :· . _ .·        |              |°    \    `·´   .·´    '   \· . _ . ·/ '  |     |·.·|'     |'   ]],
[[  |       '|\.·´ ¯ `·\     '\    `· . _ . -·-.‚ ' '\            '/‘      '\     .·´            |        '|‘   '|     '\ '/      |'   ]],
[[ /·´ ¯ ` ·\                 `· . _ . ·´ ¯ `·\    `· . _ . ·´          \.·´'              /· ´ ¯ ` ·\ ' /·´ ¯ `·\´ ¯ ` ·\  ']],
}

-- state --------------------------------------------------------------------
local state = {
  win = nil,
  buf = nil,
  ns = nil,
  steps = {}, -- key -> { label, done }
  order = {}, -- key order, for the status line
  done = 0,
  total = 0,
  shown = 0, -- the fraction the bar is CURRENTLY drawn at (eased toward target)
  closing = false,
  timer = nil,
  anim = nil, -- uv timer driving the eased bar + per-frame redraw
}

local uv = vim.uv or vim.loop

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local function trim(s)
  return (s:gsub('%s+$', ''))
end

local function spaces(n)
  return n > 0 and string.rep(' ', n) or ''
end

local function art_width()
  local w = 0
  for _, l in ipairs(M.art) do
    w = math.max(w, dw(trim(l)))
  end
  return w
end

-- The label of whatever step is currently in flight (first not-done), so the
-- status line reads "loading portrait sprite sheet…" while it happens.
local function current_status()
  for _, key in ipairs(state.order) do
    if not state.steps[key].done then
      return state.steps[key].label .. '…'
    end
  end
  return 'ready ♡'
end

local function set_hl()
  local c = M.config
  api.nvim_set_hl(0, 'SplashTitle', { fg = c.title_fg, bg = 'NONE' })
  api.nvim_set_hl(0, 'SplashBarFill', { fg = c.fill_fg, bg = 'NONE', bold = true })
  api.nvim_set_hl(0, 'SplashBarEmpty', { fg = c.empty_fg, bg = 'NONE' })
  api.nvim_set_hl(0, 'SplashStatus', { fg = c.status_fg, bg = 'NONE' })
  api.nvim_set_hl(0, 'SplashNormal', { bg = c.transparent and 'NONE' or c.backdrop })
end

-- Build the buffer lines plus the highlight spans (byte columns) that colour
-- them. Everything is re-centered from scratch so a resize just re-renders.
local function build_lines()
  local cols, rows = vim.o.columns, vim.o.lines
  local pad = math.max(0, math.floor((cols - art_width()) / 2))

  local content, hls = {}, {}
  local function add(line, group, cs, ce)
    content[#content + 1] = line
    if group then
      hls[#hls + 1] = { group, #content - 1, cs or 0, ce or -1 }
    end
  end

  -- title
  for _, l in ipairs(M.art) do
    add(spaces(pad) .. trim(l), 'SplashTitle')
  end

  add('')
  add('')

  -- loading bar: [████████░░░░░░░░]  62%
  -- Drawn from state.shown (the eased value the animation timer walks toward the
  -- real done/total) rather than the raw milestone count, so the bar GLIDES and
  -- keeps creeping during a long step instead of snapping between milestones.
  local c = M.config
  local pct = math.max(0, math.min(1, state.shown))
  local nfill = math.floor(pct * c.bar_width + 0.5)
  local fill = string.rep(c.fill_char, nfill)
  local empty = string.rep(c.empty_char, c.bar_width - nfill)
  local pct_txt = string.format('  %3d%%', math.floor(pct * 100 + 0.5))
  local bar = fill .. empty .. pct_txt
  local bpad = math.max(0, math.floor((cols - dw(bar)) / 2))
  local row = #content -- 0-based row this line will occupy
  add(spaces(bpad) .. bar)
  local b = #spaces(bpad) -- pad is ascii spaces: bytes == cells
  hls[#hls + 1] = { 'SplashBarFill', row, b, b + #fill }
  hls[#hls + 1] = { 'SplashBarEmpty', row, b + #fill, b + #fill + #empty }
  hls[#hls + 1] = { 'SplashStatus', row, b + #fill + #empty, -1 }

  add('')

  -- "what it's loading" line
  local status = current_status()
  local spad = math.max(0, math.floor((cols - dw(status)) / 2))
  add(spaces(spad) .. status, 'SplashStatus')

  -- vertical centering
  local top = math.max(0, math.floor((rows - #content) / 2))
  local out = {}
  for _ = 1, top do
    out[#out + 1] = ''
  end
  for _, l in ipairs(content) do
    out[#out + 1] = l
  end
  for _, h in ipairs(hls) do
    h[2] = h[2] + top
  end
  return out, hls
end

local function render()
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local lines, hls = build_lines()
  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_add_highlight, state.buf, state.ns, h[1], h[2], h[3], h[4])
  end
end

-- Force the splash window to repaint NOW. render() only updates the buffer;
-- without this flush the screen wouldn't actually redraw until the event loop
-- went idle, which is exactly why the bar used to sit frozen then jump.
local function flush()
  if state.win and api.nvim_win_is_valid(state.win) then
    pcall(api.nvim__redraw, { win = state.win, flush = true })
  end
end

-- Where the bar should be heading right now. The floor is the REAL progress
-- (done/total); on top of that we trickle most of the way to the next milestone
-- so the bar keeps creeping while a step is still in flight -- never quite
-- reaching the milestone until it genuinely completes.
local function compute_target()
  if state.total == 0 then
    return 0
  end
  if state.done >= state.total then
    return 1
  end
  return math.min(0.99, (state.done + 0.9) / state.total)
end

-- Drive the eased bar: every frame, walk state.shown a fraction of the way to
-- the target and repaint. Runs on a uv timer so it animates during the async
-- tail (claude / fastfetch / portrait) when the main loop is otherwise idle.
local function start_anim()
  if state.anim then
    return
  end
  state.anim = uv.new_timer()
  state.anim:start(0, 33, vim.schedule_wrap(function()
    if state.closing or not (state.buf and api.nvim_buf_is_valid(state.buf)) then
      return
    end
    local target = compute_target()
    local diff = target - state.shown
    if math.abs(diff) > 0.001 then
      state.shown = state.shown + diff * 0.12
      if math.abs(target - state.shown) < 0.003 then
        state.shown = target
      end
      render()
      flush()
    end
  end))
end

local function stop_anim()
  if state.anim then
    pcall(function()
      state.anim:stop()
      state.anim:close()
    end)
    state.anim = nil
  end
end

-- public API ---------------------------------------------------------------

-- steps: list of { key = '...', label = '...' } in display order.
function M.show(steps)
  if state.win and api.nvim_win_is_valid(state.win) then
    return -- already up
  end
  state.steps, state.order, state.done, state.closing = {}, {}, 0, false
  state.shown = 0
  for _, s in ipairs(steps or {}) do
    state.steps[s.key] = { label = s.label, done = false }
    state.order[#state.order + 1] = s.key
  end
  state.total = #state.order

  set_hl()
  state.ns = state.ns or api.nvim_create_namespace('BaselineSplash')
  state.buf = api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = 'wipe'
  vim.bo[state.buf].filetype = 'splash'

  state.win = api.nvim_open_win(state.buf, false, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    focusable = false,
    zindex = 200, -- over the panes (and the banner overlay at 30)
    style = 'minimal',
    noautocmd = true,
  })
  vim.wo[state.win].winhighlight = 'Normal:SplashNormal,NormalNC:SplashNormal,EndOfBuffer:SplashNormal'

  render()
  flush() -- paint the empty bar immediately so it's visible from frame one
  start_anim()

  local grp = api.nvim_create_augroup('BaselineSplash', { clear = true })
  api.nvim_create_autocmd({ 'VimResized', 'ColorScheme' }, {
    group = grp,
    callback = function()
      if state.win and api.nvim_win_is_valid(state.win) then
        set_hl()
        pcall(api.nvim_win_set_config, state.win, {
          relative = 'editor', row = 0, col = 0, width = vim.o.columns, height = vim.o.lines,
        })
        render()
      end
    end,
  })

  state.timer = vim.defer_fn(M.close, M.config.timeout_ms)
end

-- Mark a registered step complete; advance the bar and, once all are done,
-- linger briefly then close.
function M.complete(key)
  local s = state.steps[key]
  if not s or s.done then
    return
  end
  s.done = true
  state.done = state.done + 1
  render()
  if state.done >= state.total then
    vim.defer_fn(M.close, M.config.linger_ms)
  end
end

function M.close()
  if state.closing then
    return
  end
  state.closing = true
  -- Land on a full bar for the final frame, then tear down the animation.
  state.shown = 1
  render()
  flush()
  stop_anim()
  pcall(api.nvim_del_augroup_by_name, 'BaselineSplash')
  if state.timer then
    pcall(function()
      state.timer:stop()
    end)
    state.timer = nil
  end
  if state.win and api.nvim_win_is_valid(state.win) then
    pcall(api.nvim_win_close, state.win, true)
  end
  state.win = nil
  -- Give the portrait engine a clean repaint now the overlay is gone.
  pcall(api.nvim_exec_autocmds, 'User', { pattern = 'SplashClosed', modeline = false })
end

function M.setup()
  -- Suppress the native intro so it never flashes before our overlay paints.
  pcall(function()
    vim.opt.shortmess:append('I')
  end)

  -- :Splash -- preview the splash with a fake progression.
  api.nvim_create_user_command('Splash', function()
    local steps = {
      { key = 'plugins', label = 'loading plugins' },
      { key = 'layout', label = 'building layout' },
      { key = 'claude', label = 'starting claude' },
      { key = 'portrait', label = 'loading portrait sprite sheet' },
      { key = 'fastfetch', label = 'rendering splash' },
    }
    M.show(steps)
    local i = 0
    local function step()
      i = i + 1
      if steps[i] then
        M.complete(steps[i].key)
        vim.defer_fn(step, 550)
      end
    end
    vim.defer_fn(step, 450)
  end, { desc = 'Preview the startup splash' })
end

return M
