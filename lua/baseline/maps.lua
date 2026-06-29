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
keymap.set({ 'n', 'v' }, '<C-h>', '<C-w>h')
keymap.set({ 'n', 'v' }, '<C-j>', '<C-w>j')
keymap.set({ 'n', 'v' }, '<C-k>', '<C-w>k')
keymap.set({ 'n', 'v' }, '<C-l>', '<C-w>l')
keymap.set('t', '<C-h>', [[<C-\><C-n><C-w>h]])
keymap.set('t', '<C-j>', [[<C-\><C-n><C-w>j]])
keymap.set('t', '<C-k>', [[<C-\><C-n><C-w>k]])
keymap.set('t', '<C-l>', [[<C-\><C-n><C-w>l]])

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
