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
  proportionally; smaller images are never enlarged. The scaled PNG is then
  letterboxed into a ceil-cell box, with padding centered vertically and
  horizontally, so no image stretch occurs. For visible suffix text, the
  height-compliant box must fit complete-line inline layout; with no safe width,
  source stays visible and image is hidden. Block sizing remains controlled by
  `fit_window`.
- **`core.latex.renderer`-aligned options**: `conceal`, `dpi`,
  `render_on_enter`, `debounce_ms`, and `scale` (except `min_length`, which is
  intentionally unsupported).
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
- ImageMagick `magick` or `convert` for inline letterboxing
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
        ["core.defaults"] = {
          config = {
            -- Avoid duplicate inline images and conceal extmarks.
            disable = { "core.latex.renderer" },
          },
        },
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

For tmux visibility, enable `tmux_show_only_in_active_window = true` in your
existing image.nvim setup. Use tmux >= 3.3 with `allow-passthrough on`,
`visual-activity off`, and `focus-events on`, as required by image.nvim.
Folded images respect image.nvim's native inactive/focus state, including
pending transforms; this module does not override image.nvim's visibility
options.

The renderer refreshes images after Ctrl-L and common UI lifecycle redraws. For
plugins that repaint the terminal directly without such an event, trigger the
manual hook after repainting:

```vim
doautocmd User NeorgMathRendererRedraw
```

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

    -- Maximum inline-image height in terminal cell rows. Inline images above
    -- this limit are downscaled proportionally; smaller images are never
    -- enlarged. The result is letterboxed into a ceil-cell box. Math block
    -- sizing is controlled by fit_window.
    scale = 1,

    -- false: block images retain their density-normalized size.
    -- true:  window percentage caps can further downscale block images.
    -- This option does not affect inline images.
    fit_window = true,

    -- Foreground color: nil = current `@neorg.rendered.latex` foreground;
    -- a value starting with # is a literal color; any other string is a
    -- highlight group name. Missing groups fall back to `Normal`'s foreground.
    foreground_color = nil,

    -- Background color: nil = transparent; a value starting with # is a
    -- literal color; any other string is a highlight group name. A group
    -- without a background falls back to transparent.
    background_color = nil,

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

Color options use three forms. `nil` selects the current default formula
foreground for `foreground_color` and transparent for `background_color`. A
string beginning with `#` is used as a literal color. Any other string is
resolved as a highlight-group name; its `fg` or `bg` attribute is used. A
missing foreground falls back to `Normal`'s foreground; a missing background
falls back to transparent.

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
  wrapping. If the height-compliant box does not fit safe width, source stays
  visible and image is hidden rather than applying another scale factor. A
  line-end formula uses conceal without replacement text and normal
  height-capped sizing when its box fits the terminal edge; otherwise source
  stays visible. Inline images are proportionally resized and letterboxed into
  ceil-cell boxes with vertical and horizontal centering. They never use
  image.nvim virtual-line padding or reserve vertical rows.
- `scale` is a maximum inline-image height in terminal cell rows. Only inline
  images taller than that limit are reduced; shorter images keep native size.
  The reduced PNG keeps its aspect ratio and is padded to the ceil-cell box;
  padding uses `background_color` and is centered around the formula in both
  directions. A height-compliant box that cannot fit line layout is
  hidden instead of being reduced again; block images keep their previous
  native/`fit_window` sizing behavior.
- Inline images are always hidden while their source row is inside a closed
  fold. They are not moved outside folds like block images.
- CursorMoved, CursorHold, folding and scrolling re-anchor existing images
  without regenerating PNG files. Multiple windows receive independent image
  objects; inline conceal remains buffer-scoped like core's renderer.
- If the same buffer is displayed in multiple windows, every window gets
  its own rendered images (new splits pick them up automatically, closed
  windows drop theirs).
- Images wiped by floating UI recover automatically when its window closes
  (`WinClosed`), including notification and Noice popups, or through a manual
  `doautocmd User NeorgMathRendererRedraw` / `public.redraw()`.
- Folded blocks use outside-fold buffer/window anchors when the adjacent
  line preserves their indentation and placement, retaining image.nvim's native
  clipping. Short/wrapped adjacent lines and entire-buffer folds retain
  absolute placement.
  These fallbacks use the same terminal-cell sizing, `scale_factor`, and
  native window/global caps as unfolded blocks. Block geometry is calibrated
  to a reference terminal cell height of 40 pixels (20×40 in the test
  geometry): the PNG's native pixel-to-cell size is multiplied by the current
  cell height / 40, uniformly for both axes, before the native window/global
  caps. This retains the reference display size at 20×40 and approximately
  the same rows/columns at 10×20 without a new default size cap. It does not
  detect OS DPI or change the cached PNG; image.nvim's explicit
  `scale_factor` still applies. With image.nvim's `kitty`
  backend using normal placements (not `unicode-placeholders`), folded images
  are cropped at all content-window edges, including absolute fallbacks. The
  original image size, source PNG and reserved rows are retained; scrolling
  or resizing back restores the full image. Fully offscreen images clear.
  Other backends retain their previous clipping behavior: absolute fallbacks
  hide when their bottom edge cannot fit above the statusline.
  Resizing refreshes block geometry and reservations without
  reconverting LaTeX. Cell geometry comes from image.nvim's terminal query;
  the 40-pixel calibration is not a physical-display DPI measurement.
- Unloading or deleting the buffer (`:bd`, `:bunload`, `:bwipeout`) clears
  every image of that buffer, including absolute folded fallbacks, and drops
  its cached state; re-entering the buffer renders it fresh.
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

A buffer-lifecycle regression test checks that `:bd`, `:bunload` and
`:bwipeout` clear every image (including detached folded block images) and
drop per-buffer state, using stubbed neorg/image.nvim modules:

```bash
nvim --headless -u NONE -l test/buffer_unload.lua
```

A folded lifecycle/geometry regression uses an installed image.nvim checkout's
actual renderer, image objects, and native focus handlers with real Neovim
folds/extmarks. Tmux queries, terminal geometry, PNG processing, and graphics
output are controlled doubles:

```bash
nvim --headless -u NONE -l test/folded_lifecycle.lua
# For a checkout outside stdpath("data")/lazy/image.nvim:
IMAGE_NVIM_PATH=/path/to/image.nvim nvim --headless -u NONE -l test/folded_lifecycle.lua
```

These headless checks do **not** verify live terminal graphics, tmux switching,
or physical display DPI. `test/sample.norg` provides formulas for live checks:

1. With the tmux settings above and `hide_on_fold = false`, fold an indented
   math block with a blank adjacent line, then one with an equally indented
   adjacent line. Check `position = "below"` and `"above"`: placement and
   formula size must match unfolded rendering. Also fold a buffer containing
   only one math block; its formula must remain visible. With normal Kitty
   placements, scroll/resize it across top, bottom and horizontal split edges:
   only the out-of-window portion should disappear, without shrinking or
   painting over statuslines/borders, and returning should restore it.
2. Switch tmux windows/sessions away and back, including while conversion is
   pending. No formula should remain painted on the other window; returning
   should restore it. Scroll offscreen/back and near the statusline, and resize
   Neovim splits; reservations and placement must follow without new LaTeX
   conversions.
3. Move the terminal between Retina/non-Retina displays or change its font,
   then resize it so image.nvim refreshes terminal geometry. Inspect
   `require("image/utils/term").get_size()` in Neovim and compare folded versus
   unfolded formula size and reserved rows at both densities. Check that the
   40-pixel reference looks right on the target display: if the terminal does
   not report updated cell geometry, this module cannot infer screen DPI.
4. Verify `hide_on_fold = true`, an outer section fold, and `:bd`/`:bunload`/
   `:bwipeout` (including a non-current split) still clear the appropriate images.

## Troubleshooting

- **No rendering**: check `:Neorg render-math` is enabled, and that
  `:lua print(vim.inspect(require("neorg.modules").get_module("external.math-renderer").public.get_backend()))`
  prints a backend name instead of `nil`.
- **Conversion errors** are notified at most once every 30 seconds per
  backend; stale temp artifacts live under `<cache_dir>/tmp/` and can be
  inspected or deleted freely.
- Images bound to a window are re-shown via `BufWinEnter`; if they vanish
  after a window switch, `:Neorg render-math toggle` twice re-renders.
- **nvim-notify, Noice and overlap clearing**: if `image.nvim` uses
  `window_overlap_clear_enabled = true`, add `"notify"` and `"noice"` to
  `window_overlap_clear_ft_ignore`, for example:

  ```lua
  window_overlap_clear_ft_ignore = {
    "cmp_menu", "cmp_docs", "", "snacks_notif", "scrollview", "scrollview_sign",
    "notify", "noice",
  },
  ```

  `nvim-notify` uses `notify` as its floating buffer filetype. Without this
  exception, `image.nvim` intentionally clears math images while a notification
  overlaps the editor window. A popup still covers pixels beneath it; terminal
  layering cannot display an image above the popup. Images are refreshed after
  the popup closes.
