local wezterm = require("wezterm")

return {
  -- PowerShell
  default_prog = {
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  },
-- rose-pine, ported verbatim from your Windows Terminal scheme so colors match exactly
  colors = {
    foreground = "#E0DEF4",
    background = "#191724",
    cursor_bg = "#6E6A86",
    cursor_border = "#6E6A86",
    cursor_fg = "#191724",
    selection_bg = "#403D52",
    selection_fg = "#E0DEF4",
    ansi = {
      "#26233A", -- black
      "#EB6F92", -- red
      "#31748F", -- green
      "#F6C177", -- yellow
      "#9CCFD8", -- blue
      "#C4A7E7", -- magenta (purple)
      "#EBBCBA", -- cyan
      "#E0DEF4", -- white
    },
    brights = {
      "#908CAA", -- bright black
      "#EB6F92", -- bright red
      "#31748F", -- bright green
      "#F6C177", -- bright yellow
      "#9CCFD8", -- bright blue
      "#C4A7E7", -- bright magenta
      "#EBBCBA", -- bright cyan
      "#E0DEF4", -- bright white
    },
  },



  -- SSH domain
  ssh_domains = {
    {
      name = "wax",
      remote_address = "ec2-3-130-240-169.us-east-2.compute.amazonaws.com",
      username = "ubuntu",
      multiplexing = "None",
      assume_shell = "Posix",
      ssh_option = {
        identityfile = "C:/Users/lucius/.ssh/wax.pem",
        identitiesonly = "yes",
      },
    },
  },

  -- Keybind
  keys = {
    {
      key = "u",
      mods = "CTRL|SHIFT",
      action = wezterm.action.SpawnTab({ DomainName = "wax" }),
    },
    -- Let Ctrl+Tab / Ctrl+Shift+Tab fall through to Neovim (Chrome-style tab
    -- nav in baseline.panetabs) instead of switching WezTerm's own tabs.
    { key = "Tab", mods = "CTRL", action = wezterm.action.DisableDefaultAssignment },
    { key = "Tab", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
  },

  -- Appearance
  font_size = 12.0,

  -- Font ported from the Windows Terminal PowerShell profile (MS Gothic, cellWidth 0.5)
  font = wezterm.font("MS Gothic"),
  cell_width = 1.0,
  line_height = 1.0,

  -- Background, ported from Windows Terminal:
  -- The image is stretched to fill at 0.11 opacity (WT backgroundImageOpacity).
  -- Uncovered areas fall back to the scheme background (#191724), which
  -- window_background_opacity makes translucent -- THAT is the slight rose-pine
  -- "hue" tint over the transparency that WT gives you, not pure see-through.
  background = {
    -- Base shade layer: the rose-pine bg color. THIS is the purple tint WT paints
    -- behind the transparent image. Layered backgrounds do NOT auto-draw the scheme
    -- bg, so without this layer the image's transparent pixels show only the desktop
    -- (no tint). Change this color to make the shade lighter/darker.
    {
      source = { Color = "#191724" },
      width = "100%",
      height = "100%",
      opacity = 0.86,
    },
    -- Image layer (WT backgroundImageOpacity, stretch = fill)
    {
      source = {
        File = "C:/Users/lucius/source/repos/bg0_4k1.png",
      },
      width = "100%",
      height = "100%",
      opacity = 0.21,
    },
  },

  -- WT "opacity": 86  ->  0.86  (86% opaque window, tinted by the bg color)
  window_background_opacity = 0.96,
  text_background_opacity = 1.0,


  enable_tab_bar = true,
  hide_tab_bar_if_only_one_tab = true,



  -- Performance
  -- NOTE: WebGpu on Windows often ignores window_background_opacity and renders
  -- an opaque window. OpenGL honors transparency. Use OpenGL for transparent bg.
  front_end = "OpenGL",

  enable_kitty_graphics = true,
  -- Disabled: on the Windows/ConPTY build of WezTerm this protocol's escape
  -- sequences don't round-trip cleanly, and Neovim auto-negotiates into it,
  -- causing plain Esc to get delayed/swallowed instead of switching modes.
  enable_kitty_keyboard = false,

}
