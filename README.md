((Doing extensive personalization, may not run on your machine))

<img width="1949" height="1192" alt="NVIM EXAMPLE" src="https://github.com/user-attachments/assets/f56548c9-a94f-47d1-ac7e-f00d5ff0e49e" />

## Structure

```
init.lua                  -- core modules + lazy.nvim bootstrap
lua/baseline/base.lua     -- editor options
lua/baseline/highlights.lua -- visual options + yank highlight
lua/baseline/maps.lua     -- keymaps
lua/baseline/platform.lua -- OS-specific clipboard integration
lua/baseline/commands.lua -- custom user commands
lua/plugins/              -- lazy.nvim plugin specs, grouped by domain
colors/                   -- wildcharm-redux colorscheme
```

## Portrait pane

The tree column is bracketed by two square "portrait" panes showing a 3D head
that turns to look at your mouse (kitty graphics protocol; see
`lua/baseline/portrait.lua`). The head is not rendered live — it's cropped from a
precomputed sprite sheet at `portrait/atlas/sheet.png`, a grid of poses across a
range of yaw/pitch angles. You can swap in your own model and rebuild that sheet.

### Building the sheet

The build is two files in `portrait/`: `build.sh` (the driver — the one you run)
and `render.lua` (a small CPU rasterizer it calls once per pose). Requirements:
`nvim` (the renderer runs under `nvim -l`) and ImageMagick (`magick`).

```bash
cd portrait
./build.sh [options] <portrait.obj> [frame.obj]
```

- **`portrait.obj`** — the head that turns to look at the mouse (rotates per pose).
- **`frame.obj`** *(optional)* — a still background/border, baked identically into
  every pose so it never moves while the head turns. **Order decides the role:**
  first OBJ is the moving portrait, second is the static frame. Omit the frame to
  build the head on its own (the previous behavior).

Options:

- **`--size N`** — cell size in pixels (default `320`).
- **`--color`** — shade any model that ships an `.mtl` from its material diffuse
  (`Kd`). Models without materials keep the default celestial purple→pink ramp
  either way, so you can mix a colored model with an uncolored one.

**Sizing.** With no frame, the head **auto-fits** the square, so its absolute size
in Blender doesn't matter. With a frame, the **frame defines the camera view**: it
fills the square (fully visible), and the portrait is scaled by that same factor —
so size the head **centered in the frame**, and the head keeps its size/placement
*relative to the frame*. A head sized larger than the frame deliberately **spills
off-screen** (the part outside the frame's bounds is clipped). Examples:

```bash
./build.sh suzanne.obj                      # head only, ramp shading
./build.sh head.obj frame.obj               # moving head inside a still frame
./build.sh --color --size 384 head.obj frame.obj   # bigger, material-colored
```

### Exporting from Blender

- Orient the model to **face the camera** (looking down +Z toward the viewer) and
  **apply transforms** (Object → Apply → All Transforms) before exporting.
- Export as **Wavefront OBJ**. To use `--color`, export materials too so an `.mtl`
  sits next to the `.obj` (flat `Kd` diffuse only — textures/`map_Kd` are ignored).
- Keep the head and frame in a **single shared coordinate space** (export them
  positioned as you want them to compose); the builder preserves that layout.

### Applying a rebuild

`build.sh` overwrites `portrait/atlas/sheet.png`. Inside a running Neovim, run
`:Portrait rebuild` to drop the old sheet and pick up the new one without
restarting.

## Key Features

### Status Line & UI Enhancements
- Customizable and performant statusline, tabline and winbar with [`lualine.nvim`](https://github.com/nvim-lualine/lualine.nvim), including code context via [`nvim-navic`](https://github.com/SmiteshP/nvim-navic).
- Transparent background support with [`transparent.nvim`](https://github.com/xiyaowong/transparent.nvim).
- File icons provided by [`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons).
- Color highlighting with [`nvim-colorizer.lua`](https://github.com/norcalli/nvim-colorizer.lua).

### File Navigation & Search
- Fuzzy file finding and searching through [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) and its file browser extension [`telescope-file-browser.nvim`](https://github.com/nvim-telescope/telescope-file-browser.nvim).
- File explorer with [`nvim-tree.lua`](https://github.com/nvim-tree/nvim-tree.lua).

### Git Integration
- Git change signs with [`gitsigns.nvim`](https://github.com/lewis6991/gitsigns.nvim).
- Git blame and browse functionality via [`git.nvim`](https://github.com/dinhhuy258/git.nvim).

### Editing & Autocompletion
- Automatic pairing of brackets and HTML tags with [`nvim-autopairs`](https://github.com/windwp/nvim-autopairs) and [`nvim-ts-autotag`](https://github.com/windwp/nvim-ts-autotag).
- Context-aware commenting powered by [`Comment.nvim`](https://github.com/numToStr/Comment.nvim) and Treesitter.
- Advanced autocompletion using [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) with LSP, buffer, and path sources.
- Snippet support via [`LuaSnip`](https://github.com/L3MON4D3/LuaSnip).

### Language Server Protocol (LSP) Setup
- Native `vim.lsp.config` setup on Neovim 0.11+, with servers managed by [`mason.nvim`](https://github.com/mason-org/mason.nvim) and auto-enabled by [`mason-lspconfig.nvim`](https://github.com/mason-org/mason-lspconfig.nvim).
- Automatically ensures the following LSP servers are installed:
  - `astro`, `cssls`, `eslint`, `html`, `jsonls`, `lua_ls`, `tailwindcss`, `vtsls`, `vue_ls`
- Vue 3 single-file components via `vue_ls` + `vtsls` with the Vue TypeScript plugin.
- Enhanced LSP UIs through [`lspsaga.nvim`](https://github.com/nvimdev/lspsaga.nvim).
- Completion item pictograms with [`lspkind-nvim`](https://github.com/onsails/lspkind-nvim).

### Treesitter Configuration
- Syntax highlighting and parsing powered by [`nvim-treesitter`](https://github.com/nvim-treesitter/nvim-treesitter) (`master` branch; the `main` rewrite requires Neovim 0.12 nightly).
- Auto-installed parsers include:
  - `bash`, `css`, `fish`, `html`, `javascript`, `json`, `lua`, `markdown`, `markdown_inline`, `php`, `regex`, `ruby`, `swift`, `toml`, `tsx`, `typescript`, `vue`, `yaml`

### Command Line & Notifications
- Enhanced command line UI with [`noice.nvim`](https://github.com/folke/noice.nvim) plus dependencies [`nui.nvim`](https://github.com/MunifTanjim/nui.nvim) and [`nvim-notify`](https://github.com/rcarriga/nvim-notify).
