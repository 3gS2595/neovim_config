-- Kitty-graphics image backend for the portrait pane (baseline/portrait.lua,
-- backend = 'kitty', auto-selected when the terminal supports the protocol). The
-- magick_cli processor shells out to ImageMagick, so NO luarock is needed.
return {
  '3rd/image.nvim',
  -- Loaded only when the kitty backend is actually used (portrait.lua require()s
  -- it on demand), so it never hooks the UI on terminals without kitty support.
  lazy = true,
  opts = {
    backend = 'kitty',
    processor = 'magick_cli',
    -- We drive image.nvim directly from portrait.lua; disable the document
    -- integrations so it doesn't scan/hook normal buffers.
    integrations = {
      markdown = { enabled = false },
      neorg = { enabled = false },
      typst = { enabled = false },
      html = { enabled = false },
      css = { enabled = false },
    },
    -- Don't auto-clear our portrait when another window overlaps it.
    window_overlap_clear_enabled = false,
    editor_only_render_when_focused = false,
  },
  config = function(_, opts)
    -- SSH fix: over SSH image.nvim uses *direct* kitty transmission, which needs
    -- the tty device path. It finds it with `io.popen("tty")`, but the `tty`
    -- utility checks its STDIN and Neovim doesn't hand child processes the
    -- controlling terminal -- so `tty` prints the literal string "not a tty",
    -- which image.nvim then treats as a filename and writes graphics into (a junk
    -- file appears, the portrait never shows). Patch get_tty to prefer $SSH_TTY
    -- and never return that garbage; nil makes image.nvim fall back to its libuv
    -- stdout writer (new_tty fd 1), which works fine.
    --
    -- NOTE: image.nvim requires its modules with SLASH paths ("image/utils"), and
    -- Lua keys package.loaded by the literal string, so require('image.utils.term')
    -- would be a DIFFERENT table than the one the kitty backend reads via
    -- utils.term -- patching it does nothing. Patch the exact table the backend
    -- dereferences: the `term` field of require('image/utils'). (The kitty backend
    -- loads lazily at first render, after this config runs, so it's in time.)
    local term = require('image/utils').term
    local orig_get_tty = term.get_tty
    term.get_tty = function()
      local ssh_tty = vim.env.SSH_TTY
      if ssh_tty and ssh_tty ~= '' then
        return ssh_tty
      end
      local t = orig_get_tty()
      if not t or t == '' or t == 'not a tty' then
        return nil
      end
      return t
    end
    require('image').setup(opts)
  end,
}
