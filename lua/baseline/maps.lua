local keymap = vim.keymap
vim.g.mapleader = ' ' -- sets leader to Space key

keymap.set('n', 'x', '"_x')

-- Increment/decrement
keymap.set('n', '+', '<C-a>')
keymap.set('n', '-', '<C-x>')

-- Delete a word backwards
keymap.set('n', 'dw', 'vb"_d')

-- Select all
keymap.set('n', '<C-a>', 'gg<S-v>G')

-- New tab
keymap.set('n', 'te', ':tabedit')
keymap.set('n', '<Tab>', ':tabnext<Return>')
keymap.set('n', '<S-Tab>', ':tabprevious<Return>')
-- Split window
keymap.set('n', 'ss', ':split<Return><C-w>w')
keymap.set('n', 'sv', ':vsplit<Return><C-w>w')
-- Move between panes with Ctrl+h/j/k/l (vim/tmux standard). Mapped in terminal
-- mode too, via <C-\><C-n> to leave terminal-insert first, so it works from
-- inside the Claude/shell terminals (most of the layout) -- not just file panes.
-- This shadows the shell's Ctrl+L (clear) / Ctrl+H (backspace) inside terminals;
-- type `clear` / use Backspace there instead.
--
-- The tree column is sandwiched by two 'portrait' scratch panes (baseline.portrait);
-- those heads are never a useful focus target, so directional motion SKIPS them and
-- only ever lands on the terminal, code, or file-tree panes.
local api = vim.api
local function is_portrait(win)
  return vim.bo[api.nvim_win_get_buf(win)].filetype == 'portrait'
end

-- Move focus one window in `dir`, but never leave the cursor on a portrait pane.
-- If the move lands on a portrait, keep going the SAME direction to step over it to
-- the next real pane (so up-from-terminal passes the head onto the tree, and
-- down-from-tree passes it onto the terminal). If nothing lies further that way, the
-- portrait's only real sibling is the tree it brackets, so fall back to the tree
-- window itself; failing that, stay put.
local function win_move(dir)
  local start = api.nvim_get_current_win()
  vim.cmd('wincmd ' .. dir)
  while is_portrait(api.nvim_get_current_win()) do
    local before = api.nvim_get_current_win()
    vim.cmd('wincmd ' .. dir)
    if api.nvim_get_current_win() == before then
      -- Can't advance past the head this way; land on the tree it sandwiches.
      local tree = require('baseline.portrait').tree_win()
      api.nvim_set_current_win(tree or start)
      return
    end
  end
end

for _, dir in ipairs({ 'h', 'j', 'k', 'l' }) do
  local move = function()
    win_move(dir)
  end
  -- Terminal mode is covered directly: win_move drives the jump with `:wincmd`
  -- (an Ex command, which runs fine from terminal-insert -- unlike the keystroke
  -- <C-w>k), and switching away from a terminal leaves terminal-insert on its own.
  keymap.set({ 'n', 'v', 't' }, '<C-' .. dir .. '>', move)
end

-- Esc leaves terminal-insert for normal mode instantly. NOTE: this shadows Esc
-- inside terminal buffers (including the Claude pane and shells), so Esc no longer
-- reaches the program running there (e.g. Claude's Esc-to-interrupt).
keymap.set('t', '<Esc>', [[<C-\><C-n>]])

-- Resize window. On Alt+arrows, not <C-w>+arrows: <C-w> alone is the Chrome
-- "close tab" shortcut (baseline.panetabs), and a <C-w><arrow> mapping would make
-- every <C-w> wait ~timeoutlen to disambiguate before closing.
keymap.set('n', '<A-Left>', '<C-w><')
keymap.set('n', '<A-Right>', '<C-w>>')
keymap.set('n', '<A-Up>', '<C-w>+')
keymap.set('n', '<A-Down>', '<C-w>-')

-- Terminal
keymap.set('n', 'tt', ':belowright split | terminal<CR>', { desc = 'Open terminal below' })

-- System clipboard
keymap.set('v', '<C-c>', '"+y', { desc = 'Copy to system clipboard' })
keymap.set('n', '<C-v>', '"+p', { desc = 'Paste from system clipboard' })
keymap.set('i', '<C-v>', '<C-r>+', { desc = 'Paste from system clipboard' })
