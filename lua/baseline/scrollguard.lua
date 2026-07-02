-- Redirect mouse-wheel scrolling into the Claude pane instead of letting it
-- scroll whatever window happens to be under the cursor.
--
-- Scrolling over the Claude terminal window while it isn't the focused window
-- in terminal-mode makes Neovim page the terminal BUFFER's scrollback (normal
-- vim behaviour: the wheel scrolls the window under the mouse). But Claude is a
-- live TUI on the alternate screen, so that paging fights its own redraws and
-- produces broken-looking scrolling. Fix: the instant a scroll tick lands over
-- the Claude window, jump focus there and enter terminal-mode BEFORE the tick
-- is processed, so it lands on the live program instead of the scrollback. Once
-- scrolling stops (debounce), return focus/mode to wherever they were.
--
-- Whole thing is pure Neovim/Lua -- no OS-specific hooks -- since "the Claude
-- pane" is just a terminal-buffer window inside this one process, not an
-- external terminal-multiplexer pane.

local M = {}

local api = vim.api
local uv = vim.uv

local DEBOUNCE_MS = 300

local state = nil -- {win, mode, cwin} saved prior focus/mode, while a redirect is active
local timer = nil

-- The Claude terminal window in the current tabpage, found by the window-local
-- tag baseline.layout sets when it creates the pane. NOT inferred from the
-- buffer name: open_terminal() spawns a plain shell and TYPES the claude
-- command into it afterwards, so the terminal buffer's name is permanently
-- "...:/bin/zsh" (or whatever $SHELL is) -- it never contains "claude".
local function claude_win()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local ok, tagged = pcall(api.nvim_win_get_var, win, 'is_claude_pane')
    if ok and tagged then
      return win
    end
  end
  return nil
end

-- Exposed so other modules (panetabs' click router) can single out the Claude
-- pane specifically, without duplicating the window-tag lookup.
M.claude_win = claude_win

local function stop_timer()
  if timer then
    timer:stop()
    pcall(function()
      timer:close()
    end)
    timer = nil
  end
end

-- Fires once scrolling has stopped (no ticks for DEBOUNCE_MS). Restores the
-- saved window/mode, unless the user already navigated away from the Claude
-- window themselves in the meantime -- in that case leave them where they are
-- rather than yanking focus back.
local function restore()
  stop_timer()
  local s = state
  state = nil
  if not s then
    return
  end
  if api.nvim_get_current_win() ~= s.cwin then
    return
  end
  if api.nvim_win_is_valid(s.win) then
    api.nvim_set_current_win(s.win)
    if s.mode == 'i' or s.mode == 't' then
      vim.cmd('startinsert')
    end
  end
end

local function arm_timer()
  if timer then
    timer:stop()
  else
    timer = uv.new_timer()
  end
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(restore))
end

-- <expr> handler for a scroll key. Returns the key unchanged for the common
-- case (already on the Claude window, in terminal-mode -- native scrolling
-- proceeds untouched), or swallows it once per gesture while a deferred
-- focus-switch + resend happens (win/buf changes are blocked by textlock inside
-- an <expr> mapping, same constraint panetabs.lua's click router works around).
local function on_scroll(key)
  local cwin = claude_win()
  if not cwin then
    return key
  end
  local mp = vim.fn.getmousepos()
  if mp.winid ~= cwin then
    return key
  end

  arm_timer()

  if api.nvim_get_current_win() == cwin and vim.fn.mode() == 't' then
    return key -- already there: fast path, no redirect needed
  end

  if not state then
    state = { win = api.nvim_get_current_win(), mode = vim.fn.mode(), cwin = cwin }
    local termkey = api.nvim_replace_termcodes(key, true, true, true)
    vim.schedule(function()
      if api.nvim_win_is_valid(cwin) then
        api.nvim_set_current_win(cwin)
        vim.cmd('startinsert')
        api.nvim_feedkeys(termkey, 'n', false)
      end
    end)
  end
  return '' -- swallow: the deferred switch above resends this tick (or the next one lands post-switch)
end

function M.setup()
  for _, key in ipairs({ '<ScrollWheelUp>', '<ScrollWheelDown>', '<ScrollWheelLeft>', '<ScrollWheelRight>' }) do
    vim.keymap.set({ 'n', 'v', 'i', 't' }, key, function()
      return on_scroll(key)
    end, { expr = true, desc = 'Redirect scroll into Claude pane' })
  end
end

return M
