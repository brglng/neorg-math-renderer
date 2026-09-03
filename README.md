# neorg-math-renderer

Render Neorg `@math ... @end` blocks and inline `$...$` math as LaTeX images
directly inside Neovim, powered by
[image.nvim](https://github.com/3rd/image.nvim).

**Do not load `core.latex.renderer` together with this module.** Both modules
render inline math; loading both creates duplicate images and competing
conceal extmarks.

## Features

- **Block and inline rendering**: `@math ... @end` blocks and inline math
  become images. Block source is always visible; inline source follows
  `conceal`.
- **Pluggable LaTeX backends**, probed in a configurable preference order:
  1. `ratex` — the [RaTeX](https://github.com/erweixin/RaTeX) `ratex-render`
     CLI (pure Rust, KaTeX-compatible, renders PNG directly)
  2. `tex2svg` — the MathJax `tex2svg` CLI, rasterized with
     `rsvg-convert`/`magick`/`convert`
  3. `latex` — traditional `latex` + `dvipng` (same pipeline as neorg's own
     `core.latex.renderer`)
- **Inline height-aware scaling**: `scale` sets maximum inline-image height
  in terminal cell rows. Inline images exceeding cap are downscaled
  proportionally; smaller images are never enlarged. For visible suffix text,
  complete-line inline layout may require proportional width/height reduction;
  with no safe width, image is hidden rather than covering suffix text. A
  line-end formula does not spend its width on raw source bytes: source is
  concealed without a replacement placeholder, and image width is capped only
  by terminal edge when needed. Block sizing remains controlled by `fit_window`.
- **`core.latex.renderer`-compatible options**: `conceal`, `dpi`,
  `render_on_enter`, `renderer`, `debounce_ms`, and `scale` (except
  `min_length`, which is intentionally unsupported).
- **Visible block source, concealed inline source**: block images render on
  reserved virtual lines directly below (default) or above the block
  (`position` option). Inline images hide whenever their source row is folded.
- **Disk cache**: one PNG per unique formula and render mode (keyed by
  snippet + backend + mode + foreground color), shared across sessions.

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

Images appear as soon as backend conversion finishes. Block source stays
visible; inline source follows `conceal` and remains editable on its cursor row.

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

    -- Conceal inline math source when conceallevel permits it. This never
    -- conceals `@math` block source.
    conceal = true,

    -- dvipng density for the traditional `latex` backend.
    dpi = 350,

    -- Renderer name accepted for core.latex.renderer compatibility. This
    -- module uses image.nvim directly for block reservations.
    renderer = "core.integrations.image",

    -- Maximum inline-image height in terminal cell rows. Inline images above
    -- this limit are downscaled proportionally; smaller images are never
    -- enlarged. Math block sizing is controlled by fit_window.
    scale = 1,

    -- false: block images render at native pixel size, never scaled.
    -- true:  downscale oversized block images to fit the window (never upscale).
    -- This option does not affect inline images.
    fit_window = true,

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
    -- opts = { foreground_color, background_color, cache_dir, inline }
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

- The source of a `@math` block is never concealed: its image is an addition
  rendered on reserved virtual lines directly below (default) or directly
  above the block. `hide_on_fold` controls the block image only; an outer
  section/paragraph fold always hides it.
- Inline math uses core renderer normalization for `$...$` and `$|...|$`.
  With `conceal = true`, source is concealed away from its cursor row and the
  image is cleared on that row for editing. With `conceal = false`, source
  remains visible. A non-whitespace suffix (including following inline nodes)
  uses inline replacement text only when complete raw/display line plus
  placeholders fits actual window width; one cell of slack avoids edge
  wrapping. If needed, image width and height are reduced together to
  preserve aspect ratio. If no positive safe width remains, source stays
  visible and image is hidden. A line-end formula uses conceal without
  replacement text and normal height-capped sizing, bounded only by terminal
  edge when needed. Inline images never use image.nvim virtual-line padding or
  reserve vertical rows.
- `scale` is a maximum inline-image height in terminal cell rows. Only inline
  images taller than that limit are reduced; shorter images keep native size.
  Width follows original aspect ratio. When line fitting needs more reduction,
  width and height are reduced together; block images keep their previous
  native/`fit_window` sizing behavior.
- Inline images are always hidden while their source row is inside a closed
  fold. They are not moved outside folds like block images.
- CursorMoved, CursorHold, folding and scrolling re-anchor existing images
  without regenerating PNG files. Multiple windows receive independent image
  objects; inline conceal remains buffer-scoped like core's renderer.
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

A focused inline layout regression test checks safe inline conceal text,
strict no-padding/no-virtual-line source invariants, and stale-anchor guard
coverage:

```bash
nvim --headless -u NONE -l test/inline_layout.lua
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
