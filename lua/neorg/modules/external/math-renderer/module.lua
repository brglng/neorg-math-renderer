--[[
    file: external.math-renderer
    title: Render Neorg math as images with image.nvim
    summary: Renders Neorg `@math ... @end` blocks and inline math as images using image.nvim.
    ---

Renders Neorg `@math ... @end` blocks and inline `$...$` math by converting
LaTeX source into PNG images and displaying them with
[image.nvim](https://github.com/3rd/image.nvim).

Do not load `core.latex.renderer` with this module. Both modules render inline
math and would otherwise create duplicate images and competing conceal marks.

Toggle rendering with `:Neorg render-math enable|disable|toggle`.

Block LaTeX source stays visible. Block images are placed on reserved
virtual lines above or below the block; when a block is folded, its image and
reservation move to a visible boundary outside the fold. Inline source is
concealed according to `conceal`; inline images never reserve virtual lines
and hide whenever their source row is folded. Inline replacement text is used
only for formulas with visible suffix/layout nodes, and only when complete
raw/display line budgeting is safe. End-of-line formulas normally conceal
source without replacement text and keep normal height-capped aspect-ratio
sizing when they fit the terminal edge; otherwise source stays visible.
Optional trailing-whitespace conceal can safely preserve the original width,
including for line-end formulas with trailing spaces, using display-cell
widths; tabs use their actual starting-column width, while uncertain
multi-inline layouts keep the normal fallback.
When an inline image is shown, its source is proportionally resized and
letterboxed into a ceil-cell box: padding is centered vertically and
horizontally.

Image backends are probed in the configured `backends` preference order:

- `ratex`   -- the Rust [RaTeX](https://github.com/erweixin/RaTeX) `ratex-render` CLI
- `tex2svg` -- the MathJax `tex2svg` CLI plus `rsvg-convert`/`magick`/`convert`
- `latex`   -- traditional `latex` + `dvipng` (same pipeline as `core.latex.renderer`)

Requires:
- The [image.nvim](https://github.com/3rd/image.nvim) neovim plugin.
- `magick` or `convert` for inline letterboxing.
- At least one of the LaTeX backends above.
--]]

local neorg = require("neorg.core")
local module = neorg.modules.create("external.math-renderer")
local modules = neorg.modules

local backends = require("neorg.modules.external.math-renderer.backends")

module.setup = function()
	return {
		success = true,
		requires = {
			"core.integrations.treesitter",
			"core.autocommands",
			"core.neorgcmd",
			"core.highlights",
		},
	}
end

module.config.public = {
	-- When true, rendering is enabled automatically when a `.norg` buffer is entered.
	render_on_enter = false,

	-- Milliseconds to wait after the last text change before re-rendering.
	debounce_ms = 200,

	-- Where to render the formula image relative to the math block:
	-- "below" (default) or "above". The block's source stays fully
	-- visible; the image occupies reserved virtual lines next to it.
	position = "below",

	-- Keep the formula image visible when its own math block is folded.
	-- Set true to hide it and remove its reservation. An image is always
	-- hidden when an outer section/paragraph fold contains the math block.
	hide_on_fold = false,

	-- LaTeX-to-PNG backends in preference order. The first backend whose
	-- executables are found is used for every formula.
	--   "ratex"   -> `ratex-render` (RaTeX CLI, KaTeX-compatible, pure Rust)
	--   "tex2svg" -> MathJax `tex2svg` CLI + rsvg-convert/magick/convert
	--   "latex"   -> traditional `latex` + `dvipng`
	backends = { "ratex", "tex2svg", "latex" },

	-- Conceal inline math source when conceallevel permits it. This setting
	-- never conceals `@math` block source; inline images never reserve virtual
	-- lines, regardless of this setting.
	conceal = true,

	-- When true, safely preserve the source column after an inline formula
	-- followed by more than one horizontal whitespace cell or a tab. Tab width
	-- uses its actual starting column; uncertain layouts use the placeholder.
	preserve_inline_spacing = false,

	-- Dots per inch used by dvipng for the traditional `latex` backend.
	dpi = 350,

	-- Maximum inline-image height in terminal cell rows, expressed as a
	-- multiple of one terminal line. Inline images above this limit are
	-- downscaled proportionally; smaller images are never enlarged. For a
	-- visible suffix, the height-compliant image must fit the complete-line
	-- budget; with no safe width, source stays visible and the image is hidden.
	-- End-of-line formulas do not use that raw-line leftover budget. Math block
	-- sizing remains controlled by `fit_window`.
	scale = 1,

	-- When false, block images render at native pixel size. When true
	-- (default), oversized block images are scaled down to fit the window;
	-- block images are never scaled up. This option does not affect inline
	-- images.
	fit_window = true,

	-- Foreground color: nil uses the current `@neorg.rendered.latex`
	-- foreground; a value starting with # is a literal color; any other
	-- string names a highlight group whose foreground is used.
	foreground_color = nil,

	-- Background color: nil means transparent; a value starting with # is a
	-- literal color; any other string names a highlight group whose background
	-- is used. Missing highlight backgrounds fall back to transparent.
	background_color = nil,

	-- Directory for cached PNG files (one file per unique formula).
	cache_dir = vim.fn.stdpath("cache") .. "/nvim/neorg-math-renderer",

	-- Per-backend invocation configuration. Each of these accepts either:
	--   * a string: executable name probed on PATH and called by the built-in
	--     pipeline, or
	--   * a function: a full custom invocation taking over that backend:
	--       fn(snippet, opts, callback)
	--     where opts = { foreground_color, background_color, cache_dir, inline }.
	--     The function must eventually call callback(png_path, nil) -- or
	--     simply return a path string synchronously. The PNG is moved into
	--     the cache either way.
	ratex = "ratex-render",
	tex2svg = "tex2svg",
	latex = "latex",
}

module.private = {
	--- image.nvim module, or nil when the plugin is missing.
	image = nil,

	--- Extmark namespace used for image row reservations.
	ns = nil,

	--- Whether rendering is currently active.
	do_render = false,

	--- Per-buffer block state: bufnr -> { [math_row] = entry }.
	--- Each entry: { math_row, erow, indent, snippet, has_content, png,
	---               images (winid -> image), reservation_id, shown, pending }
	blocks = {},

	--- Per-buffer inline state: bufnr -> { [range_key] = entry }.
	--- Inline extmarks are buffer-scoped; images remain window-scoped so fold
	--- visibility is evaluated independently for every window.
	inlines = {},

	--- Per-buffer debounce timer handles.
	timers = {},

	--- Namespace used by the Ctrl-L redraw key listener.
	redraw_key_ns = nil,

	--- Last time an error was notified per backend (throttle).
	last_error_notify = {},

	--- Resolved colors passed to backends and used by inline padding.
	foreground_color = nil,
	background_color = "transparent",
}

local function highlight_color(group, attribute)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if ok and type(hl) == "table" and hl[attribute] then
		return ("#%06x"):format(hl[attribute])
	end
	return nil
end

local function resolve_foreground()
	local configured = module.config.public.foreground_color
	if configured == nil then
		return highlight_color("@neorg.rendered.latex", "fg")
			or highlight_color("Normal", "fg")
	end
	if type(configured) == "string" and configured:sub(1, 1) == "#" then
		return configured
	end
	if type(configured) == "string" then
		return highlight_color(configured, "fg")
			or highlight_color("Normal", "fg")
	end
	return highlight_color("Normal", "fg")
end

local function resolve_background()
	local configured = module.config.public.background_color
	if configured == nil then
		return "transparent"
	end
	if type(configured) == "string" and configured:sub(1, 1) == "#" then
		return configured
	end
	if type(configured) == "string" then
		return highlight_color(configured, "bg") or "transparent"
	end
	return "transparent"
end

--- Recompute formula colors from the active colorscheme. Foreground nil uses
--- `@neorg.rendered.latex`, then `Normal`; background nil is transparent. A #
--- value is a literal color, while any other string is resolved as a highlight group.
local function compute_foreground()
	local foreground = resolve_foreground()
	local background = resolve_background()
	module.private.foreground_color = foreground
	module.private.background_color = background

	backends.setup({
		cache_dir = module.config.public.cache_dir,
		ratex = module.config.public.ratex,
		tex2svg = module.config.public.tex2svg,
		latex = module.config.public.latex,
		dpi = module.config.public.dpi,
		foreground_hex = foreground,
		background_color = background,
		on_error = function(backend, msg)
			module.private.report_error(backend, msg)
		end,
	})
end

--- Throttled user-facing error notification (once every 30s per backend).
function module.private.report_error(backend, msg)
	local now = os.clock()
	if (module.private.last_error_notify[backend] or 0) + 30 > now then
		return
	end
	module.private.last_error_notify[backend] = now
	vim.notify(("neorg-math-renderer [%s]: %s"):format(backend, msg), vim.log.levels.ERROR)
end

--------------------------------------------------------------------------------
-- block discovery
--------------------------------------------------------------------------------

local ts = nil

--- Collect every `@math ... @end` block in `buf`.
--- The query only targets ranged verbatim tags named "math"; inline math is
--- collected separately so block source can never inherit inline concealment.
---@param buf integer
---@return table<number, table> entries keyed by block start row (0-based)
local function get_math_blocks(buf)
	local entries = {}

	module.required["core.integrations.treesitter"].execute_query(
		[[
			(ranged_verbatim_tag
				(tag_name) @name
				(#eq? @name "math")
			) @block
		]],
		function(query, id, node)
			if query.captures[id] ~= "block" then
				return
			end

			-- A carryover set may precede @math inside the ranged_verbatim_tag
			-- node, so node:range() start is not necessarily the tag row. Read
			-- the opening tag from the 'name' field instead.
			local name_nodes = node:field("name")
			if not name_nodes or #name_nodes == 0 then
				return
			end
			if ts.get_node_text(name_nodes[1], buf) ~= "math" then
				return
			end

			local math_row = select(1, name_nodes[1]:range())
			local _, _, erow, _ = node:range()

			-- Content lines strictly between @math and @end, joined for the
			-- LaTeX parser (newlines are insignificant whitespace in math).
			local lines = vim.api.nvim_buf_get_lines(buf, math_row + 1, erow, false)
			local snippet = vim.trim(table.concat(lines, " "))

			local tag_line = vim.api.nvim_buf_get_lines(buf, math_row, math_row + 1, false)[1] or ""

			entries[math_row] = {
				math_row = math_row,
				erow = erow,
				indent = #((tag_line:match("^(%s*)")) or ""),
				snippet = snippet,
				has_content = snippet ~= "" and erow > math_row + 1,
			}
		end,
		buf
	)

	return entries
end

--- Match core.latex.renderer's inline source normalization exactly. Norg's
--- `$|...|$` form uses the bars to mark the editable region; normal inline
--- math keeps `$` delimiters and unescapes escaped characters.
---@param original string
---@return string
local function clean_inline_snippet(original)
	local clean = original:gsub("^%$|", "$")
	clean = clean:gsub("|%$$", "$")
	if clean == original then
		clean = clean:gsub("\\(.)", "%1")
	end
	return clean
end

--- Collect every inline math node, including multiple nodes on one line.
---@param buf integer
---@return table<string, table> entries keyed by current source range
local function get_inline_math(buf)
	local entries = {}

	module.required["core.integrations.treesitter"].execute_query(
		[[
			(
				(inline_math) @inline
				(#offset! @inline 0 1 0 -1)
			)
		]],
		function(query, id, node)
			if query.captures[id] ~= "inline" then
				return
			end

			local original = ts.get_node_text(node, buf)
			if type(original) ~= "string" then
				return
			end
			local range = { node:range() }
			local key = ("%d:%d:%d:%d"):format(range[1], range[2], range[3], range[4])
			entries[key] = {
				key = key,
				range = range,
				snippet = clean_inline_snippet(original),
				png = nil,
				box_png = nil,
				box_geometry = nil,
				box_key = nil,
				box_pending = false,
				box_generation = 0,
				box_unavailable = false,
				images = {},
				extmark_id = nil,
				shown = false,
				pending = false,
			}
		end,
		buf
	)

	return entries
end

local function clear_image(entry)
	for win, img in pairs(entry.images or {}) do
		pcall(function()
			img:clear()
		end)
		entry.images[win] = nil
	end
end

--- `scale` is the maximum image height in terminal cell rows. A terminal
--- line is one cell row, so the configured value is also the cell-row cap.
local function scale_limit()
	local scale = tonumber(module.config.public.scale)
	if scale and scale > 0 then
		return scale
	end
	return nil
end

--- Compute inline geometry from source pixel dimensions: apply one
--- proportional factor (the `scale` height cap, or native size when the
--- formula already fits), round the scaled pixels, then ceil the terminal
--- cell box. The formula is later letterboxed into this box, so padding—not
--- a second resize—absorbs the cell rounding.
---@return table|nil geometry with scaled_width, scaled_height, width_cells,
--- height_rows, width_pixels, height_pixels, and factor
local function inline_box_geometry_from_size(width, height)
	local ok_term, term = pcall(function()
		return require("image/utils/term").get_size()
	end)
	width = tonumber(width)
	height = tonumber(height)
	if
		not ok_term
		or not term
		or not term.cell_width
		or not term.cell_height
		or term.cell_width <= 0
		or term.cell_height <= 0
		or not width
		or not height
		or width <= 0
		or height <= 0
	then
		return nil
	end

	local factor = 1
	local cap = scale_limit()
	local native_rows = height / term.cell_height
	if cap and native_rows > cap then
		factor = cap / native_rows
	end
	local scaled_width = math.max(1, math.floor(width * factor + 0.5))
	local scaled_height = math.max(1, math.floor(height * factor + 0.5))
	local width_cells = math.max(1, math.ceil(scaled_width / term.cell_width))
	local height_rows = math.max(1, math.ceil(scaled_height / term.cell_height))
	return {
		scaled_width = scaled_width,
		scaled_height = scaled_height,
		width_cells = width_cells,
		height_rows = height_rows,
		width_pixels = width_cells * term.cell_width,
		height_pixels = height_rows * term.cell_height,
		factor = factor,
	}
end

local function inline_box_geometry(img)
	return inline_box_geometry_from_size(img and img.image_width, img and img.image_height)
end

--- Placeholder/geometry size in terminal cells for inline images, from the
--- ceil box above. `max_width` is an optional complete-line layout budget;
--- when the box cannot fit, the first return is zero so callers leave the
--- source visible instead of distorting the image. The remaining returns are
--- the box height in rows and the scaled formula size in pixels.
local function image_display_dimensions(img, max_width)
	local geometry = inline_box_geometry(img)
	if not geometry then
		return 0, 0, 0, 0
	end
	if max_width and geometry.width_cells > max_width then
		return 0, 0, 0, 0
	end
	return geometry.width_cells, geometry.height_rows, geometry.scaled_width, geometry.scaled_height
end

local function apply_inline_box_geometry(img, geometry)
	if img and img.geometry and geometry then
		img.geometry.width = geometry.width_cells
		img.geometry.height = geometry.height_rows
	end
end

--- Terminal rows the rendered block image occupies: prefer the height
--- reported by the last successful render, fall back to a pixel estimate.
--- Inline `scale` is intentionally not applied here; block sizing continues
--- to follow `fit_window` and the image's rendered geometry.
local function image_rows(img)
	local ok, rendered = pcall(function()
		return img.rendered_geometry and img.rendered_geometry.height
	end)
	if ok and type(rendered) == "number" and rendered > 0 then
		return math.max(1, math.floor(rendered))
	end
	local ok_term, term = pcall(function()
		return require("image/utils/term").get_size()
	end)
	local ok_px, px = pcall(function()
		return img.image_height
	end)
	if ok_term and ok_px and term and term.cell_height and term.cell_height > 0 and px and px > 0 then
		return math.max(1, math.floor(px / term.cell_height))
	end
	return 1
end

--- Check buffer row/column before passing it to image.nvim. image.nvim calls
--- `screenpos()` internally and raises E966 when its row is beyond the current
--- buffer after a deletion or buffer shrink.
local function buffer_position_valid(buf, row, col)
	if not vim.api.nvim_buf_is_valid(buf) or type(row) ~= "number" or row < 0 then
		return false
	end
	if row ~= math.floor(row) or row >= vim.api.nvim_buf_line_count(buf) then
		return false
	end
	if col == nil then
		return true
	end
	if type(col) ~= "number" or col < 0 or col ~= math.floor(col) then
		return false
	end
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, row, row + 1, false)
	return ok and lines and lines[1] ~= nil and col <= #lines[1]
end

local function buffer_range_valid(buf, range)
	if type(range) ~= "table" or #range < 4 then
		return false
	end
	if range[3] < range[1] or (range[3] == range[1] and range[4] < range[2]) then
		return false
	end
	return buffer_position_valid(buf, range[1], range[2])
		and buffer_position_valid(buf, range[3], range[4])
end

--- Guard image.nvim's own deferred transform callback as well as this
--- module's render passes. image.nvim calls `image:render()` later without
--- going through our entry functions, so stale geometry must be rejected at
--- the image-object boundary too.
local function guard_image_render(buf, img)
	if not img or img.math_renderer_render_guarded or type(img.render) ~= "function" then
		return
	end
	local render = img.render
	img.render = function(self, geometry)
		if self.buffer == buf and not self.math_renderer_absolute then
			local row = geometry and geometry.y or self.geometry and self.geometry.y
			local col = geometry and geometry.x or self.geometry and self.geometry.x
			if not buffer_position_valid(buf, row, col) then
				pcall(function()
					self:clear(true)
				end)
				return
			end
		end
		return render(self, geometry)
	end
	img.math_renderer_render_guarded = true
end

--- Return the closed fold containing `entry` in `win`, if any.
--- Fold state is window-local, so every per-window image needs its own check.
local function entry_fold_info(entry, win)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local ok, info = pcall(vim.api.nvim_win_call, win, function()
		local start_row = vim.fn.foldclosed(entry.math_row + 1)
		if start_row == -1 then
			return nil
		end
		local end_row = vim.fn.foldclosedend(entry.math_row + 1) - 1
		local start_row_zero = start_row - 1
		return {
			start_row = start_row_zero,
			end_row = end_row,
			-- An exact fold of the ranged math tag is the block's own fold.
			-- Anything extending outside its @math..@end rows is an outer
			-- section/paragraph fold and is hidden even when hide_on_fold=false.
			outer = start_row_zero < entry.math_row or end_row > entry.erow,
		}
	end)
	return ok and info or nil
end

local function fold_hides_image(fold)
	return fold ~= nil and (fold.outer or module.config.public.hide_on_fold)
end

--- Choose the visible image/window used for the buffer-wide reservation.
--- Virtual lines are buffer-scoped, so different fold states in different
--- windows cannot have independent reservation anchors; prefer the current
--- window, then any non-hidden image.
local function reservation_window(buf, entry, preferred_win)
	local current = preferred_win or vim.api.nvim_get_current_win()
	local fallback
	for win in pairs(entry.images) do
		local folded = entry_fold_info(entry, win)
		if not fold_hides_image(folded) then
			fallback = fallback or win
			if win == current then
				return win
			end
		end
	end
	return fallback
end

--- Return image/reservation coordinates for one window. Folded blocks use
--- the visible fold-summary row as the image anchor, so `screenpos` can
--- resolve the block indentation even when the row after/before the fold is
--- empty or shorter than that indentation. The reservation itself remains
--- outside the fold:
--- below -> above the next visible row, above -> below the previous visible
--- row. At a file edge with no outside anchor, the image covers the fold
--- summary and there is no following text for it to overlap.
local function image_placement(buf, entry, win, rows)
	local folded = entry_fold_info(entry, win)
	local position = module.config.public.position
	if not folded then
		if position == "above" then
			return {
				image_row = entry.math_row,
				reservation_row = entry.math_row,
				reservation_above = true,
				offset = -(rows + 1),
				folded = false,
				detach_buffer = false,
			}
		end
		return {
			image_row = entry.erow,
			reservation_row = entry.erow,
			reservation_above = false,
			offset = 0,
			folded = false,
			detach_buffer = false,
		}
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local next_row = folded.end_row + 1
	local previous_row = folded.start_row - 1
	if position == "below" then
		if next_row < line_count then
			return {
				-- The fold-summary row is visible and normally contains the
				-- indented @math tag, so it is a stable horizontal anchor.
				image_row = folded.start_row,
				reservation_row = next_row,
				reservation_above = true,
				offset = 0,
				folded = true,
				detach_buffer = true,
			}
		end
		return {
			image_row = folded.start_row,
			reservation_row = nil,
			reservation_above = false,
			offset = 0,
			folded = true,
			detach_buffer = true,
		}
	end

	if previous_row >= 0 then
		return {
			-- The image starts in the virtual lines below the previous
			-- visible row and ends immediately before the fold summary.
			image_row = folded.start_row,
			reservation_row = previous_row,
			reservation_above = false,
			offset = -(rows + 1),
			folded = true,
			detach_buffer = true,
		}
	end
	-- There is no row before a fold at the top of the buffer. Prefer a
	-- visible reservation after the fold over placing an image off-screen.
	if next_row < line_count then
		return {
			image_row = folded.start_row,
			reservation_row = next_row,
			reservation_above = true,
			offset = 0,
			folded = true,
			detach_buffer = true,
		}
	end
	return {
		image_row = folded.start_row,
		reservation_row = nil,
		reservation_above = false,
		offset = 0,
		folded = true,
		detach_buffer = true,
	}
end

--- Reserve the screen rows the image occupies. Reservations are normally
--- attached to the block boundary; when the block is folded, the chosen
--- anchor moves outside the fold so virtual lines remain visible.
local function update_reservation(buf, entry, preferred_win)
	local chosen_win = reservation_window(buf, entry, preferred_win)
	local old_key = entry.reservation_key
	local old_id = entry.reservation_id
	local old_rows = entry.reservation_rows

	local rows = 0
	if chosen_win then
		for win, img in pairs(entry.images) do
			if not fold_hides_image(entry_fold_info(entry, win)) then
				rows = math.max(rows, image_rows(img))
			end
		end
	end

	local placement = chosen_win and image_placement(buf, entry, chosen_win, rows) or nil
	-- A stale block may still point past the end of a recently shortened
	-- buffer. Keep its old reservation from being used while full_render waits
	-- for tree-sitter to publish the replacement state.
	if placement and not buffer_position_valid(buf, placement.image_row) then
		placement = nil
		rows = 0
	end
	local key = placement and ("%s:%s:%d"):format(
		tostring(placement.reservation_row),
		tostring(placement.reservation_above),
		rows
	) or "none"

	entry.reservation_rows = rows
	entry.reservation_row = placement and placement.reservation_row or nil
	entry.reservation_above = placement and placement.reservation_above or false
	if old_key == key and old_id then
		local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, module.private.ns, old_id, {})
		if ok and mark and #mark > 0 and old_rows == rows then
			return
		end
	end

	if old_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, module.private.ns, old_id)
		entry.reservation_id = nil
	end
	entry.reservation_key = key
	if not placement or not placement.reservation_row or rows == 0 then
		return
	end

	local filler = {}
	for _ = 1, rows do
		filler[#filler + 1] = { { "", "" } }
	end
	local opts = {
		virt_lines = filler,
		strict = false,
		undo_restore = false,
		invalidate = true,
	}
	if placement.reservation_above then
		opts.virt_lines_above = true
	end
	entry.reservation_id = vim.api.nvim_buf_set_extmark(
		buf,
		module.private.ns,
		placement.reservation_row,
		0,
		opts
	)
end

--- Return current screen position of a buffer row/column in `win`.
--- Calling through nvim_win_call avoids cross-window screenpos quirks.
local function screen_position(win, row, col)
	local ok, position = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.screenpos(win, row + 1, col + 1)
	end)
	if not ok or not position or position.row == 0 or position.col == 0 then
		return nil
	end
	return position
end

--- Folded images are rendered with an absolute screen position because their
--- buffer row is inside a closed fold. Keep their bottom edge inside the
--- window content area; image.nvim cannot crop detached images to the window
--- and would otherwise paint over the statusline.
local function image_fits_window_bottom(win, screen_row, rows)
	local ok, info = pcall(function()
		return vim.fn.getwininfo(win)[1]
	end)
	if not ok or not info then
		return false
	end
	local winrow = tonumber(info.winrow)
	local height = tonumber(info.height)
	if not winrow or not height or type(screen_row) ~= "number" or type(rows) ~= "number" or rows <= 0 then
		return false
	end
	-- `screen_row` is the 1-based row returned by screenpos(), while the
	-- detached image backend starts at its zero-based y plus one.
	return screen_row + rows <= winrow + height - 1
end

--- Render one per-window image with current geometry. image.nvim normally
--- clears images whose buffer row is inside a fold. A math block image is an
--- intentional exception: keep it visible at the collapsed block position.
--- Temporarily detaching `image.buffer` bypasses image.nvim's fold guard and
--- also keeps its decoration provider from trying to clear this image while
--- the fold remains closed. The association is restored when the fold opens.
---
--- image.nvim's conceal-column correction expects a buffer whenever the
--- window conceallevel is >= 2, even though this module no longer conceals
--- source text. Temporarily lower that window-local option for the folded
--- render only, then restore the user's value.
local function render_entry_image(buf, entry, win, img)
	if not buffer_position_valid(buf, entry.math_row) then
		pcall(function()
			img:clear(true)
		end)
		return
	end
	local fold = entry_fold_info(entry, win)
	if fold_hides_image(fold) then
		if img.math_renderer_absolute then
			img.window = img.math_renderer_window
			img.inline = img.math_renderer_inline
			img.math_renderer_absolute = false
		end
		img.buffer = buf
		if not img.hidden_by_fold then
			pcall(function()
				img:clear()
			end)
		end
		img.hidden_by_fold = true
		return
	end

	img.hidden_by_fold = false
	local rows = entry.reservation_rows
	if type(rows) ~= "number" or rows <= 0 then
		rows = image_rows(img)
	end
	local placement = image_placement(buf, entry, win, rows)
	if not buffer_position_valid(buf, placement.image_row) then
		pcall(function()
			img:clear(true)
		end)
		return
	end

	if placement.folded then
		local position = screen_position(win, placement.image_row, entry.indent)
		local image_screen_row = position and position.row + placement.offset
		if not position or not image_fits_window_bottom(win, image_screen_row, image_rows(img)) then
			-- The folded anchor is outside the viewport or the image would cross
			-- the window's bottom edge. Clear the old absolute placement;
			-- otherwise it stays painted at its previous screen row and overlaps
			-- whatever has scrolled into view or the statusline. Keep the image
			-- object in entry.images so it can render again when it fits.
			pcall(function()
				img:clear(true)
			end)
			return
		end
		if not img.math_renderer_absolute then
			img.math_renderer_window = img.window or win
			img.math_renderer_inline = img.inline
			img.math_renderer_absolute = true
		end
		img.window = nil
		img.inline = false
		img.buffer = buf
		img.render_offset_top = 0
		-- screenpos() reports the fold summary's foldtext column, not the
		-- hidden source line's indentation. Use the same absolute x formula
		-- image.nvim uses for its out-of-bounds fallback.
		local info = vim.fn.getwininfo(win)[1]
		local absolute_x = position.col - 1
		if info then
			absolute_x = info.wincol - 1 + (info.textoff or 0) + entry.indent
		end
		pcall(function()
			img:render({
				x = absolute_x,
				y = position.row + placement.offset,
			})
		end)
		return
	end

	if img.math_renderer_absolute then
		img.window = img.math_renderer_window or win
		img.inline = img.math_renderer_inline
		img.math_renderer_absolute = false
	end
	img.buffer = buf
	img.render_offset_top = placement.offset
	pcall(function()
		img:render({ x = entry.indent, y = placement.image_row })
	end)
end

local function create_image(buf, entry, win)
	if not module.private.image or not entry.png or entry.images[win] then
		return
	end

	-- The image is anchored OUTSIDE the block, on its reserved virtual
	-- lines: "below" sits on the lines reserved after @end, "above"
	-- covers the lines reserved before @math (render_offset_top shifts
	-- it up by its own height, set right after creation).
	local position = module.config.public.position
	local y = (position == "above") and entry.math_row or entry.erow

	local ok, img = pcall(module.private.image.from_file, entry.png, {
		window = win,
		buffer = buf,
		inline = true,
		with_virtual_padding = false,
		x = entry.indent,
		y = y,
		-- Preserve block sizing behavior: `fit_window` controls whether the
		-- image.nvim window percentage caps apply. Inline `scale` is unrelated.
		max_width_window_percentage = module.config.public.fit_window and 100 or 100000,
		max_height_window_percentage = module.config.public.fit_window and 100 or 100000,
	})
	if ok and img then
		entry.images[win] = img
		guard_image_render(buf, img)
		-- Cloned image.nvim objects inherit caps from their source object;
		-- overwrite them so each block keeps its configured fit behavior.
		local max_percentage = module.config.public.fit_window and 100 or 100000
		img.max_width_window_percentage = max_percentage
		img.max_height_window_percentage = max_percentage
		-- Establish the fold-aware reservation before calculating screenpos.
		update_reservation(buf, entry, win)
		render_entry_image(buf, entry, win, img)
	end
end

--- Make sure `entry` has an image for every window currently displaying the
--- buffer, and none for windows that no longer do.
local function ensure_entry_images(buf, entry)
	local wins = vim.fn.win_findbuf(buf)
	local live = {}
	for _, w in ipairs(wins) do
		live[w] = true
	end
	for w, img in pairs(entry.images) do
		if not live[w] then
			pcall(function()
				img:clear()
			end)
			entry.images[w] = nil
		end
	end
	if entry.shown and entry.png then
		for _, w in ipairs(wins) do
			create_image(buf, entry, w)
		end
	end
end

--- Sync every entry of `buf` with the set of windows displaying it: new
--- splits get images, closed windows drop theirs.
local function sync_windows(buf)
	for _, entry in pairs(module.private.blocks[buf] or {}) do
		ensure_entry_images(buf, entry)
	end
end

--------------------------------------------------------------------------------
-- per-entry apply / reveal
--------------------------------------------------------------------------------

--- Deactivate `entry`: drop its images and its row reservation.
local function deactivate_entry(buf, entry)
	entry.shown = false
	clear_image(entry)
	update_reservation(buf, entry)
end

--- Drop `entry` completely (block vanished from the buffer).
local function destroy_entry(buf, entry)
	deactivate_entry(buf, entry)
end

--- Pending reposition sweeps per buffer (at most one per scheduler tick).
local reposition_pending = {}
local reposition_preferred = {}
local clear_stale_entries
local render_inline_state
local create_inline_image
local render_inline_entry

--- Re-render every image in `buf` on the next scheduler tick. Fold changes,
--- virtual-line reservation moves and other viewport layout changes can move
--- images without changing buffer rows, so every such change needs an
--- explicit reposition sweep.
---@param buf integer
---@param preferred_win? integer window whose fold state should drive the
--- buffer-wide reservation
local function schedule_reposition(buf, preferred_win)
	if preferred_win then
		reposition_preferred[buf] = preferred_win
	end
	if reposition_pending[buf] then
		return
	end
	reposition_pending[buf] = true
	vim.schedule(function()
		reposition_pending[buf] = nil
		local reservation_win = reposition_preferred[buf]
		reposition_preferred[buf] = nil
		if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		clear_stale_entries(buf)
		for _, entry in pairs(module.private.blocks[buf] or {}) do
			-- Fold state can change the reservation anchor, so update it before
			-- rendering any image against screenpos.
			update_reservation(buf, entry, reservation_win)
			for win, img in pairs(entry.images) do
				-- render with the entry's CURRENT anchor: a bare render() would
				-- keep a stale geometry and pin the image to an outdated row
				render_entry_image(buf, entry, win, img)
			end
		end
		-- Block reservations and folds change screen positions of inline images
		-- too. Reuse their PNGs and refresh geometry on the same sweep.
		render_inline_state(buf)
	end)
end

--------------------------------------------------------------------------------
-- inline math apply / conceal
--------------------------------------------------------------------------------

local function clear_inline_extmark(buf, entry)
	if entry.extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, module.private.ns, entry.extmark_id)
		entry.extmark_id = nil
	end
end

local function clear_inline_entry(buf, entry)
	clear_image(entry)
	clear_inline_extmark(buf, entry)
end

--- Return current cursor row and conceallevel for the window that displays
--- `buf`. Conceal is buffer-scoped, so use the current window when possible,
--- matching core.latex.renderer's single-window behavior.
local function inline_context(buf)
	local current = vim.api.nvim_get_current_win()
	local win
	if vim.api.nvim_win_is_valid(current) then
		local ok, current_buf = pcall(vim.api.nvim_win_get_buf, current)
		if ok and current_buf == buf then
			win = current
		end
	end
	if not win then
		local wins = vim.fn.win_findbuf(buf)
		win = wins[1]
	end
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil, nil, nil
	end
	local row = vim.api.nvim_win_get_cursor(win)[1] - 1
	local ok, conceallevel = pcall(vim.api.nvim_get_option_value, "conceallevel", { win = win })
	if not ok then
		conceallevel = 0
	end
	return row, conceallevel, win
end

--- Display width of source text in one inline node. This is used as a safe
--- image width cap when conceal is disabled: an image wider than its source
--- would otherwise paint over following buffer text.
local function inline_source_width(buf, range)
	if range[1] ~= range[3] then
		return 0
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
	return vim.fn.strdisplaywidth(line:sub(range[2] + 1, range[4]))
end

--- Return immediate horizontal whitespace after an inline range. The end
--- column is a byte column, while `display_width` is measured in terminal
--- cells from the source's actual display column; keeping both avoids treating
--- a multibyte source character or tab as one layout cell.
local function inline_trailing_whitespace(buf, entry)
	local range = entry.range
	if range[1] ~= range[3] then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
	local whitespace = line:sub(range[4] + 1):match("^[ \\t]*") or ""
	if whitespace == "" then
		return nil
	end
	local source_start_column = vim.fn.strdisplaywidth(line:sub(1, range[2]))
	local source_end_column = vim.fn.strdisplaywidth(line:sub(1, range[4]))
	local source = line:sub(range[2] + 1, range[4])
	return {
		end_col = range[4] + #whitespace,
		display_width = vim.fn.strdisplaywidth(whitespace, source_end_column),
		has_tab = whitespace:find("\t", 1, true) ~= nil,
		source_width = vim.fn.strdisplaywidth(source, source_start_column),
	}
end

--- Display width of non-whitespace text after an inline range. A following
--- inline node is also returned as layout suffix: its source is concealed,
--- but its image still needs a placeholder before later text can be safe.
--- Ignoring trailing whitespace is key for a formula at line end; raw source
--- bytes after that formula must not force its image to near-zero width.
local function inline_suffix_width(buf, entry)
	local range = entry.range
	if range[1] ~= range[3] then
		return math.huge, 0
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
	local following = {}
	for _, other in pairs(module.private.inlines[buf] or {}) do
		if
			other ~= entry
			and other.range[1] == range[1]
			and other.range[3] == range[3]
			and other.range[2] >= range[4]
		then
			table.insert(following, other)
		end
	end
	table.sort(following, function(a, b)
		return a.range[2] < b.range[2]
	end)

	local suffix_width = 0
	local cursor = range[4]
	local following_nodes = 0
	local function add_non_whitespace(text)
		local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" then
			suffix_width = suffix_width + vim.fn.strdisplaywidth(trimmed)
		end
	end
	for _, other in ipairs(following) do
		add_non_whitespace(line:sub(cursor + 1, other.range[2]))
		cursor = math.max(cursor, other.range[4])
		following_nodes = following_nodes + 1
	end
	add_non_whitespace(line:sub(cursor + 1))
	return suffix_width, following_nodes
end

--- Display width of complete raw source line. Neovim's wrapping calculation
--- can still account for concealed bytes when inline virtual text is present,
--- even though those bytes are not painted. Using the complete raw/display
--- width is conservative and keeps replacement text from creating a wrapped
--- screen row. This budget is used only when visible suffix/layout nodes
--- follow the formula. `strdisplaywidth` preserves tabs and wide CJK cells.
local function inline_raw_line_width(buf, range)
	if range[1] ~= range[3] then
		return math.huge
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
	return vim.fn.strdisplaywidth(line)
end

--- Text width available for normal wrapping in one window. `getwininfo().textoff`
--- covers number/sign/fold columns; subtracting it from the actual window width
--- avoids treating decorations as space available for the inline line.
local function inline_text_width(win)
	if not vim.api.nvim_win_is_valid(win) then
		return 0
	end
	local ok_width, win_width = pcall(vim.api.nvim_win_get_width, win)
	if not ok_width or type(win_width) ~= "number" then
		return 0
	end
	local info = vim.fn.getwininfo(win)[1]
	local textoff = info and tonumber(info.textoff) or 0
	return math.max(0, math.floor(win_width - textoff))
end

--- A source-width trailing-whitespace placeholder is only safe when the
--- formula starts at a known screen column in every window. A preceding inline
--- replacement makes the byte-column image anchor ambiguous; retain the normal
--- image-width placeholder in that case.
local function inline_trailing_whitespace_layout_safe(buf, entry)
	local range = entry.range
	if range[1] ~= range[3] then
		return false
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""

	for _, other in pairs(module.private.inlines[buf] or {}) do
		if
			other ~= entry
			and other.png
			and other.range[1] == range[1]
			and other.range[3] == range[3]
			and other.range[4] <= range[2]
		then
			return false
		end
	end

	local prefix_width = vim.fn.strdisplaywidth(line:sub(1, range[2]))
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local text_width = inline_text_width(win)
		if text_width <= prefix_width then
			return false
		end
		local position = screen_position(win, range[1], range[2])
		local info = vim.fn.getwininfo(win)[1]
		if not position or not info then
			return false
		end
		local expected_col = (tonumber(info.wincol) or 0) + (tonumber(info.textoff) or 0) + prefix_width
		if position.col ~= expected_col then
			return false
		end
	end
	return true
end

--- Width available from an inline range to the terminal edge. Unlike the
--- complete-line budget, this accounts only for the visible prefix before the
--- formula. It keeps line-end images inside a sensible edge when possible,
--- without shrinking them because concealed source text made the raw line long.
local function inline_edge_width(buf, entry)
	local range = entry.range
	if range[1] ~= range[3] then
		return 0
	end
	local line = vim.api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
	local prefix_width = vim.fn.strdisplaywidth(line:sub(1, range[2]))
	local limit = math.huge
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local available = inline_text_width(win) - prefix_width - 1
		-- A prefix which already wraps puts formula at start of continuation
		-- row; use almost full row rather than a misleading one-cell budget.
		if available <= 0 then
			available = math.max(1, inline_text_width(win) - 1)
		end
		limit = math.min(limit, available)
	end
	if limit == math.huge then
		return 0
	end
	return math.max(1, math.floor(limit))
end

--- Widths of other inline placeholders on same raw line. Buffer-scoped
--- conceal extmarks and window-scoped images mean every window must reserve
--- all placeholders when deciding whether this one may use inline text.
local function inline_other_placeholder_width(buf, entry)
	local total = 0
	for _, other in pairs(module.private.inlines[buf] or {}) do
		if other ~= entry and other.png and other.range[1] == entry.range[1] and other.range[3] == entry.range[3] then
			local image
			for _, candidate in pairs(other.images or {}) do
				image = candidate
				break
			end
			if other.box_geometry then
				total = total + other.box_geometry.width_cells
			elseif image then
				-- Box geometry is normally populated before this function runs;
				-- use raw dimensions only while a cache entry is being initialized.
				total = total + image_display_dimensions(image)
			end
		end
	end
	return total
end

--- Maximum safe inline placeholder width for a formula with visible text or
--- following inline nodes. Compare actual window text width against complete
--- raw/display line plus all placeholders. Leave one cell slack: exact-width
--- inline text can still wrap at terminal edge. Returning zero keeps source
--- visible and hides image instead of covering suffix text. Line-end formulas
--- use inline_edge_width instead and never enter this full-line budget.
local function inline_max_width(buf, entry)
	local suffix_width, following_nodes = inline_suffix_width(buf, entry)
	if suffix_width <= 0 and following_nodes == 0 then
		return nil
	end
	local raw_width = inline_raw_line_width(buf, entry.range)
	if raw_width == math.huge then
		return 0
	end
	local other_width = inline_other_placeholder_width(buf, entry)
	local limit = math.huge
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		limit = math.min(limit, inline_text_width(win) - raw_width - other_width - 1)
	end
	if limit == math.huge then
		return 0
	end
	return math.max(0, math.floor(limit))
end

--- Update one buffer-scoped conceal extmark. Inline extmarks deliberately
--- cover source delimiters; block entries never call this function. A formula
--- with visible suffix/layout nodes gets inline replacement text only when
--- complete-line budgeting leaves safe room. A line-end formula normally gets
--- conceal without replacement text, except for the opt-in safe trailing-space
--- width-preservation path.
local function update_inline_extmark(buf, entry, box)
	local range = entry.range
	local suffix_width, following_nodes = inline_suffix_width(buf, entry)
	local suffix_present = suffix_width > 0 or following_nodes > 0
	local cursor_row, conceallevel = inline_context(buf)
	local on_cursor_row = cursor_row ~= nil and cursor_row == range[1]
	local conceal_enabled = type(conceallevel) == "number" and conceallevel >= 2
	if not module.config.public.conceal or not conceal_enabled then
		clear_inline_extmark(buf, entry)
		return on_cursor_row, conceal_enabled, nil, suffix_present
	end

	-- Full-line budgeting is needed only to shift visible text after this
	-- formula. End-of-line math uses edge width for image geometry instead.
	local max_width = suffix_present and inline_max_width(buf, entry) or inline_edge_width(buf, entry)
	if suffix_present and not on_cursor_row and max_width <= 0 then
		clear_inline_extmark(buf, entry)
		return on_cursor_row, conceal_enabled, max_width, suffix_present
	end

	local ext_opts = {
		end_row = range[3],
		end_col = range[4],
		strict = false,
		invalidate = true,
		undo_restore = false,
		id = entry.extmark_id,
	}

	if not on_cursor_row then
		local width = box and box.width_cells or 0
		if max_width and width > max_width then
			width = 0
		end
		if width <= 0 then
			-- A width-constrained image cannot be made smaller without applying
			-- another scale factor. Keep source visible as a safe fallback.
			clear_inline_extmark(buf, entry)
			return on_cursor_row, conceal_enabled, 0, suffix_present
		end

		-- Normally the image-width replacement is enough. With a sufficiently
		-- wide run of literal spaces after the formula, a source-width
		-- replacement can keep later text in its original screen column. It
		-- conceals those spaces too, so the image occupies the first `width`
		-- cells and the remainder of the replacement stays visible to its right.
		local replacement_width = width
		local preserve_trailing = false
		if module.config.public.preserve_inline_spacing then
			local trailing = inline_trailing_whitespace(buf, entry)
			local source_plus_whitespace = trailing
				and trailing.source_width + trailing.display_width
			local candidate = trailing
				and (trailing.display_width > 1 or trailing.has_tab)
				and source_plus_whitespace > width
			local layout_safe = candidate
				and inline_trailing_whitespace_layout_safe(buf, entry)
			if layout_safe then
				if not max_width or source_plus_whitespace > max_width then
					-- A source-width replacement would wrap or cover suffix text.
					-- Keep source visible instead of silently shortening its layout.
					clear_inline_extmark(buf, entry)
					return on_cursor_row, conceal_enabled, 0, suffix_present
				end
				replacement_width = source_plus_whitespace
				preserve_trailing = true
				ext_opts.end_col = trailing.end_col
			end
		end
		if suffix_present or preserve_trailing then
			ext_opts.virt_text = { { string.rep(" ", replacement_width), "" } }
			ext_opts.virt_text_pos = "inline"
		end
		-- End-of-line conceal normally has no replacement text. The opt-in
		-- trailing-whitespace path is the exception: its replacement preserves
		-- the full source-plus-space width.
		ext_opts.conceal = ""
	else
		-- Explicitly clear replacement text left by the previous non-cursor
		-- pass. This matches core.latex renderer's cursor reveal behavior.
		ext_opts.virt_text = { { "", "" } }
	end

	local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, module.private.ns, range[1], range[2], ext_opts)
	if ok then
		entry.extmark_id = id
	end
	return on_cursor_row, conceal_enabled, max_width, suffix_present
end

--- Inline source is hidden by any closed fold in each window. Unlike block
--- images, inline images are never relocated to a fold boundary.
local function inline_is_folded(entry, win)
	if not vim.api.nvim_win_is_valid(win) then
		return true
	end
	local ok, folded = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.foldclosed(entry.range[1] + 1) ~= -1
	end)
	return ok and folded or false
end

--- Read PNG pixel dimensions from the IHDR chunk without any external
--- tool. Returns nil for non-PNG or unreadable files.
local function png_dimensions(path)
	local uv = vim.uv or vim.loop
	local ok, fd = pcall(uv.fs_open, path, "r", 438)
	if not ok or not fd then
		return nil
	end
	local ok_data, data = pcall(uv.fs_read, fd, 24, 0)
	pcall(uv.fs_close, fd)
	if not ok_data or type(data) ~= "string" or #data < 24 then
		return nil
	end
	local sig = string.char(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
	if data:sub(1, 8) ~= sig then
		return nil
	end
	-- Bytes 8..15 are the IHDR chunk header; width is at 16..19 and height at
	-- 20..23, both big-endian.
	local w = data:byte(17) * 16777216 + data:byte(18) * 65536 + data:byte(19) * 256 + data:byte(20)
	local h = data:byte(21) * 16777216 + data:byte(22) * 65536 + data:byte(23) * 256 + data:byte(24)
	if w <= 0 or h <= 0 then
		return nil
	end
	return w, h
end

local function magick_binary()
	if vim.fn.executable("magick") == 1 then
		return "magick"
	elseif vim.fn.executable("convert") == 1 then
		return "convert"
	end
	return nil
end

--- Letterbox one formula PNG into its ceil-cell box: scale proportionally by
--- the single `scale` factor, then pad to the exact box size with the
--- resolved background (transparent or a configured color).
--- Padding is centered vertically and horizontally. The result matches the box geometry
--- pixel-for-pixel, so image.nvim applies no transform of its own and the
--- formula is never stretched. Results are cached under `<cache_dir>/pad/`.
local function ensure_inline_box_png(buf, entry)
	if not entry.png then
		return
	end

	local source_png = entry.png
	local native_w, native_h = png_dimensions(source_png)
	local geometry = native_w and native_h and inline_box_geometry_from_size(native_w, native_h) or nil
	entry.box_geometry = geometry
	if not geometry then
		entry.box_png = nil
		entry.box_key = nil
		entry.box_pending = nil
		return
	end

	local bg = module.private.background_color or "transparent"
	local mtime = vim.fn.getftime(source_png)
	local key = vim.fn.sha256(
		("inline-letterbox-v1|%s|%d|%d|%d|%d|%s"):format(
			source_png,
			mtime,
			geometry.scaled_width,
			geometry.scaled_height,
			geometry.width_pixels,
			geometry.height_pixels,
			tostring(bg)
		)
	)
	local pad_dir = module.config.public.cache_dir .. "/pad"
	local out = pad_dir .. "/" .. key .. ".png"

	if entry.box_key == key then
		if entry.box_pending or entry.box_unavailable then
			return
		end
		if entry.box_png and vim.fn.filereadable(entry.box_png) == 1 then
			return
		end
		entry.box_key = nil
	end
	if entry.box_pending then
		return
	end
	if vim.fn.filereadable(out) == 1 then
		entry.box_png = out
		entry.box_key = key
		entry.box_unavailable = false
		return
	end

	local magick = magick_binary()
	if not magick then
		entry.box_png = nil
		entry.box_key = key
		entry.box_unavailable = true
		module.private.report_error("magick", "inline letterboxing requires magick or convert")
		return
	end

	entry.box_png = nil
	entry.box_key = key
	entry.box_unavailable = false
	entry.box_pending = true
	entry.box_generation = (entry.box_generation or 0) + 1
	local generation = entry.box_generation
	vim.fn.mkdir(pad_dir, "p")
	local background = bg == "transparent" and "none" or tostring(bg)
	vim.system({
		magick,
		source_png,
		"-resize", ("%dx%d"):format(geometry.scaled_width, geometry.scaled_height),
		"-background", background,
		"-gravity", "Center",
		"-extent", ("%dx%d"):format(geometry.width_pixels, geometry.height_pixels),
		out,
	}, { text = true }, function(res)
		vim.schedule(function()
			if entry.box_generation ~= generation or entry.png ~= source_png then
				return
			end
			entry.box_pending = nil
			if res.code ~= 0 or vim.fn.filereadable(out) ~= 1 then
				entry.box_unavailable = true
				module.private.report_error("magick", ("letterbox failed (%d)"):format(res.code))
				return
			end
			entry.box_png = out
			entry.box_unavailable = false
			if vim.api.nvim_buf_is_valid(buf) and module.private.do_render then
				-- Recreate window images from the padded PNG and lay them out.
				clear_image(entry)
				render_inline_state(buf)
			end
		end)
	end)
end

render_inline_entry = function(buf, entry)
	if not entry.png or not entry.box_png or not entry.box_geometry then
		clear_image(entry)
		clear_inline_extmark(buf, entry)
		return
	end
	if not buffer_range_valid(buf, entry.range) then
		clear_inline_entry(buf, entry)
		return
	end

	local first_image
	for _, image in pairs(entry.images) do
		first_image = image
		break
	end
	if not first_image then
		clear_inline_extmark(buf, entry)
		return
	end
	local box = entry.box_geometry
	if not box then
		clear_inline_extmark(buf, entry)
		return
	end
	local on_cursor_row, conceal_enabled, concealed_width, suffix_present = update_inline_extmark(buf, entry, box)
	local width_limit = concealed_width
	if not conceal_enabled then
		-- Without active conceal the source remains in normal layout. Keep the
		-- image within its source span when visible suffix follows it; a
		-- line-end image only needs the terminal-edge bound.
		width_limit = suffix_present and inline_source_width(buf, entry.range) or inline_edge_width(buf, entry)
	end

	for win, image in pairs(entry.images) do
		local no_conceal_room = conceal_enabled
			and module.config.public.conceal
			and suffix_present
			and not on_cursor_row
			and type(concealed_width) == "number"
			and concealed_width <= 0
		local hidden = inline_is_folded(entry, win)
			or (module.config.public.conceal and on_cursor_row and conceal_enabled)
			or no_conceal_room
		if not hidden then
			local width = box.width_cells
			if width_limit and width > width_limit then
				hidden = true
			end
		end
		if hidden then
			if not image.hidden_by_inline then
				pcall(function()
					image:clear()
				end)
			end
			image.hidden_by_inline = true
		else
			image.hidden_by_inline = false
			-- Keep external image.nvim limits from changing the box size
			-- independently of this module's scale policy.
			image.ignore_global_max_size = true
			-- The PNG (letterboxed by this module) already matches the ceil-cell
			-- box pixel-for-pixel, so image.nvim applies no transform and no
			-- second scale factor can distort the formula.
			image.geometry.width = box.width_cells
			image.geometry.height = box.height_rows
			image.buffer = buf
			image.window = win
			image.inline = true
			image.render_offset_top = -1
			pcall(function()
				image:render({ x = entry.range[2], y = entry.range[1] })
			end)
		end
	end
end

create_inline_image = function(buf, entry, win)
	-- Only use the letterboxed PNG. It matches the ceil-cell geometry
	-- pixel-for-pixel, so image.nvim performs no transform and the formula is
	-- never stretched. While padding is unavailable or in flight, source text
	-- remains visible and no image is created.
	local png = entry.box_png
	if not module.private.image or not png or not entry.box_geometry or entry.images[win] then
		return
	end

	local range = entry.range
	local ok, image = pcall(module.private.image.from_file, png, {
		window = win,
		buffer = buf,
		inline = true,
		-- Inline math never uses image.nvim virtual padding. Inline images do
		-- not reserve vertical space regardless of conceal configuration; their
		-- horizontal geometry is fitted below before rendering.
		with_virtual_padding = false,
		x = range[2],
		y = range[1],
		render_offset_top = -1,
		-- Disable image.nvim's global window caps. This module's scale limit is
		-- height-only and is applied after image dimensions are known.
		max_width_window_percentage = 100000,
		max_height_window_percentage = 100000,
	})
	if ok and image then
		entry.images[win] = image
		guard_image_render(buf, image)
		-- Inline scale is this module's only size policy. Ignore image.nvim
		-- global width/height caps so they cannot introduce a second, non-
		-- proportional scale factor.
		image.ignore_global_max_size = true
		image.max_width_window_percentage = 100000
		image.max_height_window_percentage = 100000
		apply_inline_box_geometry(image, entry.box_geometry)
	end
end

local function ensure_inline_images(buf, entry)
	local wins = vim.fn.win_findbuf(buf)
	local live = {}
	for _, win in ipairs(wins) do
		live[win] = true
	end
	-- Keep this check for image objects created before this invariant was
	-- introduced. Recreate them without virtual padding.
	local wanted_padding = false
	local wanted_png = entry.box_png and vim.fn.fnamemodify(entry.box_png, ":p") or nil
	for win, image in pairs(entry.images) do
		local image_png = image.original_path and vim.fn.fnamemodify(image.original_path, ":p") or nil
		if
			not live[win]
			or image.with_virtual_padding ~= wanted_padding
			or not wanted_png
			or image_png ~= wanted_png
		then
			pcall(function()
				image:clear()
			end)
			entry.images[win] = nil
		end
	end
	if entry.shown and entry.png and entry.box_png then
		for _, win in ipairs(wins) do
			create_inline_image(buf, entry, win)
		end
	end
end

local function sync_inline_windows(buf)
	for _, entry in pairs(module.private.inlines[buf] or {}) do
		ensure_inline_images(buf, entry)
	end
end

render_inline_state = function(buf)
	local state = module.private.inlines[buf] or {}
	-- Ensure every formula has its letterboxed box PNG first. While padding is
	-- pending, keep source text visible and do not create a stretched fallback.
	for _, entry in pairs(state) do
		if entry.shown and entry.png then
			ensure_inline_box_png(buf, entry)
		end
	end
	-- Create every window-scoped image before laying out any extmark. This
	-- lets each entry account for other placeholders on its raw line, even
	-- when several formulas share one line.
	for _, entry in pairs(state) do
		if entry.shown and entry.png and entry.box_png then
			ensure_inline_images(buf, entry)
		elseif entry.shown then
			clear_image(entry)
			clear_inline_extmark(buf, entry)
		end
	end
	for _, entry in pairs(state) do
		if entry.shown and entry.png and entry.box_png then
			render_inline_entry(buf, entry)
		end
	end
end

--- Cancel image.nvim work whose buffer anchor became stale before the
--- debounced tree-sitter pass catches up. Clearing an image also cancels its
--- pending transform callback, preventing that callback from calling
--- `screenpos()` with the deleted row.
clear_stale_entries = function(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	for _, entry in pairs(module.private.blocks[buf] or {}) do
		if not buffer_position_valid(buf, entry.math_row) then
			clear_image(entry)
			update_reservation(buf, entry)
		else
			for win, image in pairs(entry.images) do
				local row = image.geometry and image.geometry.y
				if not image.math_renderer_absolute and type(row) == "number" and not buffer_position_valid(buf, row) then
					pcall(function()
						image:clear(true)
					end)
					entry.images[win] = nil
				end
			end
			update_reservation(buf, entry)
		end
	end

	for _, entry in pairs(module.private.inlines[buf] or {}) do
		if not buffer_range_valid(buf, entry.range) then
			clear_inline_entry(buf, entry)
		else
			for win, image in pairs(entry.images) do
				local row = image.geometry and image.geometry.y
				if type(row) == "number" and not buffer_position_valid(buf, row) then
					pcall(function()
						image:clear(true)
					end)
					entry.images[win] = nil
				end
			end
		end
	end
end

local function deactivate_inline_entry(buf, entry)
	entry.shown = false
	clear_inline_entry(buf, entry)
end

local function destroy_inline_entry(buf, entry)
	deactivate_inline_entry(buf, entry)
end

local function show_inline_entry(buf, entry)
	if entry.shown then
		ensure_inline_images(buf, entry)
		render_inline_entry(buf, entry)
		return
	end
	entry.shown = true

	if entry.png then
		ensure_inline_images(buf, entry)
		render_inline_entry(buf, entry)
		return
	end
	if entry.pending or not module.private.backend then
		return
	end

	entry.pending = true
	local snippet = entry.snippet
	backends.render(snippet, module.private.backend, function(png, err)
		entry.pending = false
		if err then
			module.private.report_error(module.private.backend, err)
		end
		if not png or not vim.api.nvim_buf_is_valid(buf) or not module.private.do_render then
			return
		end
		clear_stale_entries(buf)
		local current = module.private.inlines[buf]
		local live = current and current[entry.key]
		if not live or live ~= entry or live.snippet ~= snippet then
			return
		end
		entry.png = png
		entry.box_png = nil
		entry.box_key = nil
		-- Lay out all ready inline entries together so multiple formulas on one
		-- raw line share the same complete-line width budget.
		render_inline_state(buf)
		-- Inline images have no virtual padding or row reservation, so they do
		-- not affect block placement.
	end, { inline = true })
end

--- Full refresh of `buf`: recreate every shown image from its cached PNG.
--- Used after any UI event that may wipe terminal cells: recreating bypasses
--- stale render state a plain re-render might hit. Deferred so the UI finishes
--- its own teardown first, and retried if another command-line UI is active.
local deep_redraw_pending = {}
local function deep_redraw(buf)
	if deep_redraw_pending[buf] then
		return
	end
	deep_redraw_pending[buf] = true
	vim.defer_fn(function()
		deep_redraw_pending[buf] = nil
		if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		if vim.fn.getcmdwintype() ~= "" or vim.api.nvim_get_mode().mode:find("^c") then
			deep_redraw(buf)
			return
		end
		clear_stale_entries(buf)
		for _, entry in pairs(module.private.blocks[buf] or {}) do
			if entry.shown and entry.png then
				clear_image(entry)
				ensure_entry_images(buf, entry)
				-- `ensure_entry_images` reuses existing objects, so explicitly
				-- render every block image after clearing its backend state.
				update_reservation(buf, entry)
				for win, img in pairs(entry.images) do
					render_entry_image(buf, entry, win, img)
				end
			end
		end
		local inline_state = module.private.inlines[buf] or {}
		for _, entry in pairs(inline_state) do
			if entry.shown and entry.png then
				clear_image(entry)
				ensure_inline_images(buf, entry)
			end
		end
		for _, entry in pairs(inline_state) do
			if entry.shown and entry.png then
				render_inline_entry(buf, entry)
			end
		end
	end, 100)
end

--- Schedule refresh for every tracked norg buffer visible in a window.
--- Float-close events can leave a different buffer active, so refreshing only
--- `nvim_get_current_buf()` can leave images in another visible split stale.
local function redraw_visible_buffers()
	local buffers = {}
	local function collect(state)
		for buf in pairs(state) do
			if
				vim.api.nvim_buf_is_valid(buf)
				and vim.bo[buf].ft == "norg"
				and #vim.fn.win_findbuf(buf) > 0
			then
				buffers[buf] = true
			end
		end
	end

	collect(module.private.blocks)
	collect(module.private.inlines)
	for buf in pairs(buffers) do
		deep_redraw(buf)
	end
end

--- Show `entry`: make sure every window has the image and the row
--- reservation is in place. The source is never concealed.
local function show_entry(buf, entry)
	if entry.shown then
		return
	end
	entry.shown = true

	if entry.png then
		ensure_entry_images(buf, entry)
		return
	end
	if entry.pending or not entry.has_content then
		return
	end

	entry.pending = true
	local snippet = entry.snippet
	backends.render(snippet, module.private.backend, function(png, err)
		entry.pending = false
		if err then
			module.private.report_error(module.private.backend, err)
		end
		if not png or not vim.api.nvim_buf_is_valid(buf) or not module.private.do_render then
			return
		end
		clear_stale_entries(buf)
		local current = module.private.blocks[buf]
		local live = current and current[entry.math_row]
		-- The block may have changed while we were converting.
		if not live or live ~= entry or live.snippet ~= snippet then
			return
		end
		entry.png = png
		ensure_entry_images(buf, entry)
		-- The new image (and its reservation) shifts every block below it.
		schedule_reposition(buf)
	end)
end

------------------------------------------------------------------------------
-- rendering passes
--------------------------------------------------------------------------------

--- Full render of the current buffer: re-discover blocks and inline nodes,
--- reconcile state, and apply images/reservations without regenerating
--- cached PNGs.
local function full_render(buf)
	if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	clear_stale_entries(buf)
	local desired = get_math_blocks(buf)
	local state = module.private.blocks[buf] or {}

	-- Drop blocks that vanished or moved.
	for row, entry in pairs(state) do
		local want = desired[row]
		if not want or want.snippet ~= entry.snippet or want.erow ~= entry.erow then
			destroy_entry(buf, entry)
			state[row] = nil
		end
	end
	-- Publish state before starting conversions. Custom backend functions may
	-- return synchronously, and their callbacks must see the live entry.
	module.private.blocks[buf] = state

	for row, want in pairs(desired) do
		local entry = state[row]
		if not entry then
			entry = {
				math_row = want.math_row,
				erow = want.erow,
				indent = want.indent,
				snippet = want.snippet,
				has_content = want.has_content,
				png = nil,
				images = {},
				reservation_id = nil,
				shown = false,
				pending = false,
			}
			state[row] = entry
		else
			entry.erow = want.erow
			entry.indent = want.indent
			entry.has_content = want.has_content
		end

		-- Empty blocks have nothing to render.
		if entry.has_content then
			show_entry(buf, entry)
		end
	end

	local desired_inline = get_inline_math(buf)
	local inline_state = module.private.inlines[buf] or {}
	for key, entry in pairs(inline_state) do
		local want = desired_inline[key]
		if not want or want.snippet ~= entry.snippet then
			destroy_inline_entry(buf, entry)
			inline_state[key] = nil
		end
	end
	for key, want in pairs(desired_inline) do
		local entry = inline_state[key]
		if not entry then
			entry = want
			inline_state[key] = entry
		else
			entry.range = want.range
		end
	end
	-- Publish state before starting async conversions, so callbacks reject
	-- results from nodes replaced while a backend was still running.
	module.private.inlines[buf] = inline_state
	for _, entry in pairs(inline_state) do
		show_inline_entry(buf, entry)
	end
	render_inline_state(buf)
	schedule_reposition(buf)
end

--- Light pass on cursor movement: re-sync window sets and refresh inline
--- conceal/image visibility. Existing PNGs and image objects are reused;
--- backend conversion is never called from this path.
local function update_cursor(buf)
	if not module.private.do_render then
		return
	end
	clear_stale_entries(buf)
	sync_windows(buf)
	sync_inline_windows(buf)
	render_inline_state(buf)
	schedule_reposition(buf)
end

--- Debounced full render for `buf`.
local function schedule_render(buf, delay)
	if not module.private.do_render then
		return
	end

	clear_stale_entries(buf)
	local existing = module.private.timers[buf]
	if existing then
		existing:stop()
		existing:close()
		module.private.timers[buf] = nil
	end

	module.private.timers[buf] = vim.defer_fn(function()
		module.private.timers[buf] = nil
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
			full_render(buf)
		end
	end, delay or module.config.public.debounce_ms)
end

--------------------------------------------------------------------------------
-- commands / lifecycle
--------------------------------------------------------------------------------

local function enable_rendering()
	if not module.private.image then
		return
	end
	module.private.do_render = true
	full_render(vim.api.nvim_get_current_buf())
end

local function disable_rendering()
	module.private.do_render = false
	for buf, timers in pairs(module.private.timers) do
		if timers then
			timers:stop()
			timers:close()
		end
		module.private.timers[buf] = nil
	end
	for buf, state in pairs(module.private.blocks) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
		end
		for _, entry in pairs(state) do
			clear_image(entry)
			entry.shown = false
		end
	end
	for buf, state in pairs(module.private.inlines) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
		end
		for _, entry in pairs(state) do
			clear_inline_entry(buf, entry)
			entry.shown = false
		end
	end
	module.private.blocks = {}
	module.private.inlines = {}
end

local function toggle_rendering()
	if module.private.do_render then
		disable_rendering()
	else
		enable_rendering()
	end
end

local function show_hidden(buf)
	if not module.private.do_render then
		return
	end
	clear_stale_entries(buf)
	-- image objects are window-bound; re-render every image of every entry
	-- with fresh geometry when a window re-enters the buffer.
	for _, entry in pairs(module.private.blocks[buf] or {}) do
		if entry.shown then
			update_reservation(buf, entry)
			for win, img in pairs(entry.images) do
				render_entry_image(buf, entry, win, img)
			end
		end
	end
	sync_inline_windows(buf)
	render_inline_state(buf)
end

local function colorscheme_changed()
	-- Aligned with core.latex.renderer: drop every cached conversion, then
	-- recompute the foreground and re-render on the next tick, once the new
	-- scheme's highlights are in place.
	vim.schedule(function()
		compute_foreground()
		for buf, state in pairs(module.private.blocks) do
			if vim.api.nvim_buf_is_valid(buf) then
				for _, entry in pairs(state) do
					deactivate_entry(buf, entry)
					entry.png = nil
				end
				schedule_render(buf, 0)
			end
		end
		for buf, state in pairs(module.private.inlines) do
			if vim.api.nvim_buf_is_valid(buf) then
				for _, entry in pairs(state) do
					deactivate_inline_entry(buf, entry)
					entry.png = nil
					entry.box_png = nil
					entry.box_geometry = nil
					entry.box_key = nil
					entry.box_pending = nil
					entry.box_unavailable = false
					entry.box_generation = (entry.box_generation or 0) + 1
				end
				schedule_render(buf, 0)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

local event_handlers = {
	["core.neorgcmd.events.math.render.render"] = function()
		enable_rendering()
	end,
	["core.neorgcmd.events.math.render.enable"] = enable_rendering,
	["core.neorgcmd.events.math.render.disable"] = disable_rendering,
	["core.neorgcmd.events.math.render.toggle"] = toggle_rendering,
	["core.autocommands.events.bufreadpost"] = function(event)
		if module.config.public.render_on_enter then
			-- default debounce: give tree-sitter a beat to parse the buffer
			schedule_render(event.buffer)
		end
	end,
	["core.autocommands.events.bufwinenter"] = function(event)
		sync_windows(event.buffer)
		sync_inline_windows(event.buffer)
		-- First entry into a buffer we have not rendered yet (e.g. BufReadPost
		-- fired before the module loaded or before ft was set to norg): render
		-- it now. full_render records state even for block-less buffers, so
		-- this stays a one-shot per buffer.
		if module.private.do_render
			and (module.private.blocks[event.buffer] == nil or module.private.inlines[event.buffer] == nil)
		then
			full_render(event.buffer)
		end
		show_hidden(event.buffer)
	end,
	["core.autocommands.events.winenter"] = function(event)
		sync_windows(event.buffer)
		sync_inline_windows(event.buffer)
		show_hidden(event.buffer)
	end,
	["core.autocommands.events.cursormoved"] = function(event)
		update_cursor(event.buffer)
	end,
	["core.autocommands.events.cursorhold"] = function(event)
		update_cursor(event.buffer)
	end,
	["core.autocommands.events.textchanged"] = function(event)
		schedule_render(event.buffer)
	end,
	["core.autocommands.events.textchangedi"] = function(event)
		-- TextChangedI can fire while an image.nvim transform is still
		-- pending. Clear deleted anchors immediately; full parsing waits for
		-- InsertLeave as usual.
		clear_stale_entries(event.buffer)
	end,
	["core.autocommands.events.insertleave"] = function(event)
		schedule_render(event.buffer)
	end,
	["core.autocommands.events.colorscheme"] = colorscheme_changed,
}

function module.on_event(event)
	if event.referrer == "core.autocommands" then
		-- ColorScheme is global (not tied to a buffer): it must be processed
		-- even when the current buffer is not a norg file.
		local is_colorscheme = event.type == "core.autocommands.events.colorscheme"
		if not is_colorscheme
			and (not vim.api.nvim_buf_is_valid(event.buffer) or vim.bo[event.buffer].ft ~= "norg")
		then
			return
		end
	end
	return event_handlers[event.type](event)
end

module.events.subscribed = {
	["core.autocommands"] = {
		bufreadpost = true,
		bufwinenter = true,
		winenter = true,
		cursormoved = true,
		cursorhold = true,
		textchanged = true,
		textchangedi = true,
		insertleave = true,
		colorscheme = true,
	},
	["core.neorgcmd"] = {
		["math.render.render"] = true,
		["math.render.enable"] = true,
		["math.render.disable"] = true,
		["math.render.toggle"] = true,
	},
}

--------------------------------------------------------------------------------
-- load
--------------------------------------------------------------------------------

module.load = function()
	ts = module.required["core.integrations.treesitter"]

	local ok, image = pcall(require, "image")
	if not ok then
		vim.notify(
			"neorg-math-renderer: image.nvim is not installed or could not be loaded; "
				.. "math rendering is disabled",
			vim.log.levels.ERROR
		)
		module.private.image = nil
	else
		module.private.image = image
	end

	module.private.ns = vim.api.nvim_create_namespace("neorg-math-renderer")

	-- render_on_enter implies rendering starts enabled (mirrors core.latex.renderer).
	module.private.do_render = module.config.public.render_on_enter == true

	compute_foreground()

	-- Resolve the rendering backend once; empty result means nothing usable.
	module.private.backend = backends.resolve(module.config.public.backends)
	if not module.private.backend then
		vim.notify(
			"neorg-math-renderer: no usable LaTeX backend found (tried: "
				.. table.concat(module.config.public.backends, ", ")
				.. "); see :h neorg-math-renderer for installation hints",
			vim.log.levels.ERROR
		)
	end

	-- Enable the autocmds this module reacts to.
	for _, name in ipairs({
		"BufReadPost",
		"BufWinEnter",
		"WinEnter",
		"CursorMoved",
		"CursorHold",
		"TextChanged",
		"TextChangedI",
		"InsertLeave",
	}) do
		module.required["core.autocommands"].enable_autocommand(name)
	end
	-- ColorScheme is NOT a buffer event: its match field is the colorscheme
	-- name, so the default "*.norg" isolation would make it never fire.
	-- Pass dont_isolate = true (same as neorg's own core.highlights does).
	module.required["core.autocommands"].enable_autocommand("Colorscheme", true)

	-- Float-based command-line UIs (e.g. noice.nvim) repaint the screen when
	-- the command line opens and closes, wiping the terminal cells the images
	-- were drawn on. image.nvim does not redraw on its own (no scroll or
	-- topline change), so refresh once the command line is left.
	local aug = vim.api.nvim_create_augroup("neorg-math-renderer", { clear = true })

	-- Fold changes can move every image without changing any buffer row.
	-- Neovim has no FoldClosed/FoldOpened events; WinScrolled is the
	-- supported signal for this viewport change. Re-sync windows first, then
	-- reposition all existing images on the next tick.
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = aug,
		callback = function(event)
			local buf = event.buf
			if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].ft ~= "norg" then
				return
			end
			local win = tonumber(event.match) or vim.api.nvim_get_current_win()
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
					sync_windows(buf)
					sync_inline_windows(buf)
					render_inline_state(buf)
					schedule_reposition(buf, win)
				end
			end)
		end,
	})

	-- A font or terminal-size change alters the cell dimensions every inline
	-- box is computed from. Drop the letterboxed PNGs so the next render pads
	-- for the new cell size (the pad cache is keyed by box size, so stale
	-- files simply become dead entries).
	vim.api.nvim_create_autocmd("VimResized", {
		group = aug,
		callback = function()
			for buf, state in pairs(module.private.inlines) do
				for _, entry in pairs(state) do
					entry.box_png = nil
					entry.box_geometry = nil
					entry.box_key = nil
					entry.box_pending = nil
					entry.box_unavailable = false
					entry.box_generation = (entry.box_generation or 0) + 1
					clear_image(entry)
					clear_inline_extmark(buf, entry)
				end
			end
			for buf, state in pairs(module.private.inlines) do
				if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
					schedule_render(buf, 0)
				end
			end
		end,
	})

	-- Folded images temporarily detach their buffer association to bypass
	-- image.nvim's fold guard. Clean them explicitly when a window leaves the
	-- buffer, because image.nvim cannot perform its normal buffer-mismatch
	-- cleanup while that association is detached.
	vim.api.nvim_create_autocmd("BufLeave", {
		group = aug,
		callback = function(event)
			local buf = event.buf
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
				-- BufLeave fires before the window has switched buffers, so
				-- defer until win_findbuf() sees the post-leave window set.
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
						sync_windows(buf)
						sync_inline_windows(buf)
						render_inline_state(buf)
					end
				end)
			end
		end,
	})

	-- `set background=light/dark` changes the resolved foreground without a
	-- ColorScheme event (e.g. when only a scheme's variant is toggled).
	vim.api.nvim_create_autocmd("OptionSet", {
		group = aug,
		pattern = "background",
		callback = function()
			colorscheme_changed()
		end,
	})

	-- Notification, Noice and other floating UI can wipe images when they
	-- close; WinClosed fires for every window. Coalesce redraw requests because
	-- one UI transition can emit several lifecycle events.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = aug,
		callback = function()
			redraw_visible_buffers()
		end,
	})

	-- Other non-key UI transitions can repaint the terminal without changing
	-- the viewport. There is no generic Redraw autocmd, so cover the lifecycle
	-- events Neovim exposes and leave direct redraws an explicit User hook below.
	vim.api.nvim_create_autocmd({
		"CmdlineLeave",
		"CmdwinLeave",
		"FocusGained",
		"VimResume",
		"UIEnter",
		"TabEnter",
	}, {
		group = aug,
		callback = function()
			redraw_visible_buffers()
		end,
	})

	-- Ctrl-L forces a terminal repaint without firing viewport autocmds.
	-- image.nvim's terminal graphics are erased by that repaint, so detect the
	-- key without replacing its mapping and refresh after it completes.
	if module.private.redraw_key_ns then
		vim.on_key(nil, module.private.redraw_key_ns)
	end
	module.private.redraw_key_ns = vim.api.nvim_create_namespace("neorg-math-renderer-redraw-key")
	local ctrl_l = vim.keycode("<C-L>")
	vim.on_key(function(key, typed)
		if key == ctrl_l or typed == ctrl_l then
			redraw_visible_buffers()
		end
	end, module.private.redraw_key_ns)

	-- Manual redraw hook: `doautocmd User NeorgMathRendererRedraw` (or
	-- module.public.redraw()) forces a sweep for redraws with no lifecycle
	-- event, e.g. a direct API `redraw!` call from another plugin.
	vim.api.nvim_create_autocmd("User", {
		group = aug,
		pattern = "NeorgMathRendererRedraw",
		callback = function()
			module.public.redraw()
		end,
	})

	modules.await("core.neorgcmd", function(neorgcmd)
		neorgcmd.add_commands_from_table({
			["render-math"] = {
				name = "math.render.render",
				min_args = 0,
				max_args = 1,
				subcommands = {
					enable = { args = 0, name = "math.render.enable" },
					disable = { args = 0, name = "math.render.disable" },
					toggle = { args = 0, name = "math.render.toggle" },
				},
				condition = "norg",
			},
		})
	end)
end

--------------------------------------------------------------------------------
-- public helpers
--------------------------------------------------------------------------------

---@class external.math-renderer
module.public = {
	--- Re-render all math blocks in `buf` (defaults to the current buffer).
	render = function(buf)
		buf = buf or vim.api.nvim_get_current_buf()
		if module.private.do_render then
			full_render(buf)
		end
	end,

	--- Clear all images and row reservations from `buf` (defaults to current).
	clear = function(buf)
		buf = buf or vim.api.nvim_get_current_buf()
		local state = module.private.blocks[buf] or {}
		local inline_state = module.private.inlines[buf] or {}
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
		end
		for _, entry in pairs(state) do
			clear_image(entry)
			entry.shown = false
		end
		for _, entry in pairs(inline_state) do
			clear_inline_entry(buf, entry)
			entry.shown = false
		end
	end,

	--- Name of the resolved backend, or nil if none was found.
	get_backend = function()
		return module.private.backend
	end,

	--- Force a full refresh of every visible norg buffer's images. Use when
	--- external code repaints the terminal without a lifecycle event.
	redraw = function()
		if module.private.do_render then
			redraw_visible_buffers()
		end
	end,
}

return module
