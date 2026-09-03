# neorg-math-renderer

Render Neorg `@math ... @end` blocks as LaTeX images directly inside Neovim,
powered by [image.nvim](https://github.com/3rd/image.nvim).

Inline `$...$` math is deliberately left untouched — only ranged `@math`
blocks are rendered.

## Features

- **Block-only rendering**: `@math ... @end` blocks become images; inline math
  is never touched.
- **Pluggable LaTeX backends**, probed in a configurable preference order:
  1. `ratex` — the [RaTeX](https://github.com/erweixin/RaTeX) `ratex-render`
     CLI (pure Rust, KaTeX-compatible, renders PNG directly)
  2. `tex2svg` — the MathJax `tex2svg` CLI, rasterized with
     `rsvg-convert`/`magick`/`convert`
  3. `latex` — traditional `latex` + `dvipng` (same pipeline as neorg's own
     `core.latex.renderer`)
- **True-size images, no upscaling**: images render at their natural pixel
  size; with `fit_window = true` (default) oversized images are scaled down
  to fit the window, never up.
- **neorg-nabla compatible options**: `render_on_enter`, `debounce_ms`.
- **Visible source, image beside it**: the LaTeX source is never hidden;
  each formula renders on reserved virtual lines directly below (default)
  or above the block (`position` option).
- **Disk cache**: one PNG per unique formula (keyed by snippet + backend +
  foreground color), shared across sessions.

## Requirements

- Neovim >= 0.10 (reserving virtual lines above the block needs >= 0.11;
  with the default `position = "below"`, 0.10 works too)
- [neorg](https://github.com/nvim-neorg/neorg)
- [image.nvim](https://github.com/3rd/image.nvim) with a working backend
  (kitty/sixel/ueberzug) for your terminal
- At least one LaTeX backend (see below)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-neorg/neorg",
  dependencies = {
    { "3rd/image.nvim", build = false },
    { "brglng/neorg-math-renderer" },
  },
  config = function()
    require("neorg").setup({
      load = {
        ["core.defaults"] = {},
        ["external.math-renderer"] = {
          config = {
            -- all defaults; see Configuration below
          },
        },
      },
    })
  end,
}
```

## Usage

In a norg buffer:

```vim
:Neorg render-math enable
:Neorg render-math disable
:Neorg render-math toggle
```

Images appear as soon as the backend conversion finishes; the LaTeX source
itself is never hidden.

## Configuration

All options (defaults shown):

```lua
["external.math-renderer"] = {
  config = {
    -- Render automatically when a `.norg` buffer is entered.
    render_on_enter = false,

    -- Milliseconds to wait after the last text change before re-rendering.
    debounce_ms = 200,

    -- Where the image is rendered relative to the math block:
    -- "below" (default) or "above".
    position = "below",

    -- Keep the image when the math block itself is folded (default). Set
    -- true to hide it and remove its reservation while folded. An outer
    -- section/paragraph fold always hides the image.
    hide_on_fold = false,

    -- LaTeX-to-PNG backends in preference order. The first backend whose
    -- probe succeeds is used.
    backends = { "ratex", "tex2svg", "latex" },

    -- false: render at native pixel size, never scaled.
    -- true:  downscale oversized images to fit the window (never upscale).
    fit_window = true,

    -- dvipng density for the traditional `latex` backend.
    dpi = 350,

    -- Foreground color as "#rrggbb". nil = foreground of
    -- `@neorg.rendered.latex` (following its link, so it tracks your
    -- colorscheme; fallback: 50% grey, matching core.latex.renderer).
    foreground_color = nil,

    -- Background of rendered formulas: "transparent" or "#rrggbb".
    background_color = "transparent",

    -- PNG cache directory.
    cache_dir = vim.fn.stdpath("cache") .. "/nvim/neorg-math-renderer",

    -- Per-backend invocation configuration; see "Backend configuration"
    -- below for the string / function forms.
    ratex = "ratex-render",
    tex2svg = "tex2svg",
    latex = "latex",
  },
},
```

## Backend configuration

Each of `ratex`, `tex2svg` and `latex` accepts either a **string** or a
**function**:

- **string**: an executable name. It is probed on PATH and invoked by the
  module's built-in pipeline for that backend.
- **function**: a full custom invocation that takes over the backend:

  ```lua
  latex = function(snippet, opts, callback)
    -- opts = { foreground_color, background_color, cache_dir }
    -- Render `snippet` however you like (subprocess, HTTP service, ...),
    -- then either return the PNG path synchronously:
    return png_path
    -- or call, at any time (also from fast events):
    callback(png_path, nil)      -- success
    callback(nil, "reason")      -- failure
  end,
  ```

  The produced PNG is moved into the module's disk cache either way, and a
  function-valued backend is always considered available (no executable
  probe).

## Backends

### ratex (preferred)

[RaTeX](https://github.com/erweixin/RaTeX) renders PNG directly — no extra
rasterizer needed:

```bash
# prebuilt CLI archives bundle the KaTeX fonts
# https://github.com/erweixin/RaTeX/releases (ratex-cli-*)
# the archive binary is called `render`; expose it as `ratex-render`:
install -m755 render /usr/local/bin/ratex-render

# or build from source
cargo build --release -p ratex-render --features embed-fonts
install -m755 target/release/render /usr/local/bin/ratex-render
```

If you keep the original binary name, point the config at it:
`ratex = "render"` (or any full path). To add CLI flags such as `--dpr` or
`--font-dir`, use the function form:

```lua
ratex = function(snippet, opts, callback)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ snippet:gsub("%s*\n%s*", " ") }, dir .. "/in.txt")
  vim.system({ "ratex-render", "--dpr", "2", "--font-dir", "/path/to/fonts",
    "--color", opts.foreground_color,
    "--background-color", opts.background_color,
    "--input", dir .. "/in.txt", "--output-dir", dir },
    { text = true }, function(r)
      vim.schedule(function()
        if r.code == 0 then callback(dir .. "/0001.png") else callback(nil, "ratex failed") end
      end)
    end)
end,
```

### tex2svg (MathJax)

```bash
npm install -g mathjax-node-cli   # provides `tex2svg`
brew install librsvg              # rsvg-convert (or: brew install imagemagick)
```

The SVG output is recolored from `currentColor` to the configured foreground
before rasterization; `background_color = "#rrggbb"` is painted in by the
rasterizer (`rsvg-convert -b` / `magick -background … -flatten`).

### latex (traditional)

TeX Live / MacTeX with `latex`, `dvipng`, and the packages `amsmath`,
`amssymb`, `graphicx`:

```bash
brew install --cask mactex-no-gui   # macOS
sudo apt install texlive-latex-extra texlive-fonts-recommended  # Debian/Ubuntu
```

Note: the `standalone` class (v1.5a) is incompatible with the new
display-math handling of the LaTeX 2025+ kernel, so this module compiles with
`article` + `\pagestyle{empty}` and crops borders with `dvipng -T tight`.

Snippets containing bare `&`/`\\` alignment are wrapped in `align*`;
top-level environments (`align`, `gather`, `multline`, ...) are passed
through as-is; second-level environments (`pmatrix`, `cases`, ...) are
wrapped in `\[ ... \]`.

## How rendering works

- The LaTeX source of a math block is never hidden: the formula image is
  an addition rendered on reserved virtual lines directly below (default)
  or directly above the block.
- The reservation tracks the image height exactly, so following text is
  pushed down by the image height and no blank rows are left behind.
- CursorMoved, CursorHold, folding and scrolling re-anchor existing images
  without regenerating their PNG files. If the math block itself is folded,
  its image and virtual-line reservation move to the visible boundary outside
  the fold by default; set `hide_on_fold = true` to hide both for the block's
  own fold. An outer section/paragraph fold always hides the image.
- If the same buffer is displayed in multiple windows, every window gets
  its own rendered images (new splits pick them up automatically, closed
  windows drop theirs).
- Images wiped by floating UI recover automatically: command line float
  (`CmdlineLeave`), any closing window incl. notification popups
  (`WinClosed`), or a manual `doautocmd User NeorgMathRendererRedraw` /
  `public.redraw()`.
- The foreground color tracks `@norg.rendered.latex` (including its link
  target) and is re-resolved on `ColorScheme`, so formulas follow your
  colorscheme automatically.

## Testing

A backend smoke test that does not require neorg:

```bash
PATH="/Library/TeX/texbin:$PATH" nvim --headless -l test/smoke.lua
```

`test/sample.norg` contains math blocks of every supported shape for manual
verification in a real neorg session.

## Troubleshooting

- **No rendering**: check `:Neorg render-math` is enabled, and that
  `:lua print(vim.inspect(require("neorg.modules").get_module("external.math-renderer").public.get_backend()))`
  prints a backend name instead of `nil`.
- **Conversion errors** are notified at most once every 30 seconds per
  backend; stale temp artifacts live under `<cache_dir>/tmp/` and can be
  inspected or deleted freely.
- Images bound to a window are re-shown via `BufWinEnter`; if they vanish
  after a window switch, `:Neorg render-math toggle` twice re-renders.
