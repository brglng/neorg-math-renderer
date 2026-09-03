--[[
    file: external.math-renderer
    title: Render `@math` blocks as images with image.nvim
    summary: Renders Neorg `@math ... @end` blocks as LaTeX images using image.nvim.
    ---

Renders Neorg `@math ... @end` blocks (and *only* those -- inline `$...$`
math is deliberately left untouched) by converting each block's LaTeX source
into a PNG image and displaying it in place with
[image.nvim](https://github.com/3rd/image.nvim).

Toggle rendering with `:Neorg render-math enable|disable|toggle`.

The LaTeX source stays visible. The rendered image is placed on reserved
virtual lines above or below the block; when the block is folded, the image
and its reservation move to a visible boundary outside the fold.

Image backends are probed in the configured `backends` preference order:

- `ratex`   -- the Rust [RaTeX](https://github.com/erweixin/RaTeX) `ratex-render` CLI
- `tex2svg` -- the MathJax `tex2svg` CLI plus `rsvg-convert`/`magick`/`convert`
- `latex`   -- traditional `latex` + `dvipng` (same pipeline as `core.latex.renderer`)

Requires:
- The [image.nvim](https://github.com/3rd/image.nvim) neovim plugin.
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
	-- executables are found is used for every block.
	--   "ratex"   -> `ratex-render` (RaTeX CLI, KaTeX-compatible, pure Rust)
	--   "tex2svg" -> MathJax `tex2svg` CLI + rsvg-convert/magick/convert
	--   "latex"   -> traditional `latex` + `dvipng`
	backends = { "ratex", "tex2svg", "latex" },

	-- When false, images render at their native pixel size and are never
	-- scaled up or down -- a formula wider than the window simply overflows.
	-- When true (default), oversized images are scaled down to fit the window
	-- (never scaled up).
	fit_window = true,

	-- Dots per inch used by dvipng for the traditional `latex` backend.
	dpi = 350,

	-- Foreground color of rendered formulas as "#rrggbb". When nil, the
	-- foreground of `@neorg.rendered.latex` is used (falling back to 50%
	-- grey), matching core.latex.renderer.
	foreground_color = nil,

	-- Background of rendered formulas: "transparent" (default) or "#rrggbb".
	background_color = "transparent",

	-- Directory for cached PNG files (one file per unique formula).
	cache_dir = vim.fn.stdpath("cache") .. "/nvim/neorg-math-renderer",

	-- Per-backend invocation configuration. Each of these accepts either:
	--   * a string: executable name probed on PATH and called by the built-in
	--     pipeline, or
	--   * a function: a full custom invocation taking over that backend:
	--       fn(snippet, opts, callback)
	--     where opts = { foreground_color, background_color, cache_dir }.
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

	--- Per-buffer debounce timer handles.
	timers = {},

	--- Last time an error was notified per backend (throttle).
	last_error_notify = {},
}

--- Compute the foreground color and push the user configuration into the
--- Recompute the formula foreground from the active colorscheme. Mirrors
--- core.latex.renderer: read `@neorg.rendered.latex` (the editor resolves
--- its link for us) and fall back to 50% grey when the group has no
--- definition. An explicit `foreground_color` config always wins.
local function compute_foreground()
	local hex = module.config.public.foreground_color
	if not hex then
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "@neorg.rendered.latex", link = false })
		if ok and type(hl) == "table" and not vim.tbl_isempty(hl) and hl.fg then
			hex = ("#%06x"):format(hl.fg)
		else
			hex = "#808080" -- 50% grey, same fallback core.latex.renderer uses
		end
	end

	backends.setup({
		cache_dir = module.config.public.cache_dir,
		ratex = module.config.public.ratex,
		tex2svg = module.config.public.tex2svg,
		latex = module.config.public.latex,
		dpi = module.config.public.dpi,
		foreground_hex = hex,
		background_color = module.config.public.background_color,
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
--- Inline math is intentionally not matched: the query only targets ranged
--- verbatim tags named "math".
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

local function clear_image(entry)
	for win, img in pairs(entry.images or {}) do
		pcall(function()
			img:clear()
		end)
		entry.images[win] = nil
	end
end

--- Terminal rows the rendered image occupies: prefer the height reported
--- by the last successful render, fall back to a pixel estimate.
local function image_rows(img)
	local ok, rendered = pcall(function()
		return img.rendered_geometry and img.rendered_geometry.height
	end)
	if ok and type(rendered) == "number" and rendered > 0 then
		return rendered
	end
	local ok_term, term = pcall(function()
		return require("image.utils.term").get_size()
	end)
	local ok_px, px = pcall(function()
		return img.image_height
	end)
	if ok_term and ok_px and term and term.cell_height and px and px > 0 then
		return math.max(1, math.floor(px / term.cell_height))
	end
	return 1
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

	if placement.folded then
		local position = screen_position(win, placement.image_row, entry.indent)
		if not position then
			-- The folded anchor is outside the viewport. Clear the old
			-- absolute placement; otherwise it stays painted at its previous
			-- screen row and overlaps whatever has scrolled into view. Keep
			-- the image object in entry.images so it can render again when
			-- the fold returns to the viewport.
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
		-- Native size by default: image.nvim's global max_*_window_percentage
		-- defaults (100% width / 50% height) must never shrink block images.
		-- 100000% effectively disables both caps; `fit_window` restores sane
		-- 100% caps (downscale only, never upscale).
		max_width_window_percentage = module.config.public.fit_window and 100 or 100000,
		max_height_window_percentage = module.config.public.fit_window and 100 or 100000,
	})
	if ok and img then
		entry.images[win] = img
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
	end)
end

--- Full refresh of `buf`: recreate every shown image from its cached PNG.
--- Used after floating UI (command-line or notification popups) wiped the
--- terminal cells: recreating bypasses any stale render state a plain
--- re-render might hit. Deferred so the UI finishes its own teardown first,
--- and retried while a command-line UI is still active.
local function deep_redraw(buf)
	vim.defer_fn(function()
		if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		if vim.fn.getcmdwintype() ~= "" or vim.api.nvim_get_mode().mode:find("^c") then
			deep_redraw(buf)
			return
		end
		for _, entry in pairs(module.private.blocks[buf] or {}) do
			if entry.shown and entry.png then
				clear_image(entry)
				ensure_entry_images(buf, entry)
			end
		end
	end, 100)
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

--- Full render of the current buffer: re-discover blocks, reconcile state,
--- and apply images/reservations to every block.
local function full_render(buf)
	if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

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

	module.private.blocks[buf] = state
	schedule_reposition(buf)
end

--- Light pass on cursor movement: re-sync the window set (splits may have
--- been opened or closed while focus moved). The source is always visible,
--- so there is no reveal/conceal state to maintain anymore.
local function update_cursor(buf)
	if not module.private.do_render then
		return
	end
	-- Cursor events only need a reposition/window sync. Existing PNGs and
	-- image objects are reused; full_render/backend conversion is never
	-- called from this path.
	sync_windows(buf)
	schedule_reposition(buf)
end

--- Debounced full render for `buf`.
local function schedule_render(buf, delay)
	if not module.private.do_render then
		return
	end

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
	module.private.blocks = {}
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
		-- First entry into a buffer we have not rendered yet (e.g. BufReadPost
		-- fired before the module loaded or before ft was set to norg): render
		-- it now. full_render records state even for block-less buffers, so
		-- this stays a one-shot per buffer.
		if module.private.do_render and module.private.blocks[event.buffer] == nil then
			full_render(event.buffer)
		end
		show_hidden(event.buffer)
	end,
	["core.autocommands.events.winenter"] = function(event)
		sync_windows(event.buffer)
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
				.. "math block rendering is disabled",
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
	for _, name in ipairs({ "BufReadPost", "BufWinEnter", "WinEnter", "CursorMoved", "CursorHold", "TextChanged", "InsertLeave" }) do
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
					schedule_reposition(buf, win)
				end
			end)
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

	vim.api.nvim_create_autocmd({ "CmdlineLeave", "CmdwinLeave" }, {
		group = aug,
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
				deep_redraw(buf)
			end
		end,
	})

	-- Notification popups and other floating UI wipe images the same way
	-- when they close; WinClosed fires for every floating window, so this
	-- stays fully event-driven (no timer).
	vim.api.nvim_create_autocmd("WinClosed", {
		group = aug,
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].ft == "norg" then
				deep_redraw(buf)
			end
		end,
	})

	-- Manual redraw hook: `doautocmd User NeorgMathRendererRedraw` (or
	-- module.public.redraw()) forces a sweep, e.g. from an autocmd of a
	-- specific notification plugin.
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
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
		end
		for _, entry in pairs(state) do
			clear_image(entry)
			entry.shown = false
		end
	end,

	--- Name of the resolved backend, or nil if none was found.
	get_backend = function()
		return module.private.backend
	end,

	--- Force a full refresh of the current buffer's images. Use when some
	--- floating UI wiped the terminal cells they were drawn on and no
	--- WinClosed/CmdlineLeave event fired for it.
	redraw = function()
		if module.private.do_render then
			deep_redraw(vim.api.nvim_get_current_buf())
		end
	end,
}

return module
