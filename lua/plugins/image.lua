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
    -- image.nvim defaults max_height_window_percentage to 50, i.e. it shrinks any
    -- image to HALF the window height (anchored at top) -- which left the portrait
    -- filling only the top of its pane. We size the image explicitly to the pane in
    -- portrait.lua, so disable both clamps (100%) and let our geometry stand.
    max_width_window_percentage = 100,
    max_height_window_percentage = 100,
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

    -- SIZING fix (letterbox): over SSH the kernel reports 0 terminal pixels, so
    -- image.nvim assumes 8x16-px cells and draws the bitmap at that size -- smaller
    -- than WezTerm's real cells, so the square pane shows a small, margined image.
    -- We can't learn the real cell pixels (Neovim doesn't surface the CSI 16t
    -- reply), and we don't need to: the kitty protocol can SCALE an image into a
    -- given number of CELLS (c=columns, r=rows), which we already know -- it's the
    -- pane size. image.nvim's display path only sends pixel sizes (w/h), never c/r,
    -- so we inject them here. display_width/height are pixels == cells * cell_size,
    -- so dividing by the same cell_size recovers the exact pane cell count; the
    -- terminal then scales the bitmap to fill those cells at its true pixel size.
    -- Pre-cache support: portrait.lua warms the cache by rendering every pose once
    -- so its pixels TRANSMIT to the terminal (transmit goes through a different
    -- helper, write_graphics, not write_graphics_at). For each pose being warmed it
    -- puts that image's internal id in this set so the DISPLAY write below is
    -- skipped -- the pose transmits but isn't shown, so warming never flashes poses
    -- over the visible portrait. A SET (not a boolean) is required because the
    -- resize is async: the display happens in a later re-render, by which time a
    -- global flag would have been reset; the id stays set until the pose is really
    -- visited (portrait.lua clears it then).
    local image_mod = require('image')
    image_mod._portrait_suppress = image_mod._portrait_suppress or {}
    local helpers = require('image/backends/kitty/helpers')
    local orig_write_at = helpers.write_graphics_at
    helpers.write_graphics_at = function(config, x, y)
      if image_mod._portrait_suppress[config.image_id] then
        return
      end
      -- Scale the image to the PANE's own cell box, set by portrait.lua right
      -- before each render. We use this rather than image.nvim's display_width/
      -- height because image.nvim shrinks the geometry first (aspect-fit + a
      -- max_height_window_percentage clamp), which left the portrait filling only
      -- part of its pane. c=cols/r=rows tells the terminal to scale the whole image
      -- into exactly that many cells -- so it fills the pane the way the chafa
      -- backend does. We drop the pixel source-rect (w/h/x/y) so kitty uses the
      -- full image (leaving w/h makes kitty crop to a sub-rectangle instead).
      local box = image_mod._portrait_box
      if box then
        config.display_columns = box.cols
        config.display_rows = box.rows
        config.display_width = nil
        config.display_height = nil
        config.display_x = nil
        config.display_y = nil
      end
      return orig_write_at(config, x, y)
    end

    require('image').setup(opts)
  end,
}
