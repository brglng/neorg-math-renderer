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

Rendering requires `conceallevel >= 2` in the norg window: the block's source
lines are concealed character-by-character underneath the image. When the
cursor moves inside a block, the raw LaTeX source is revealed and the image is
hidden until the cursor leaves.

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

	-- When true, the `@math` and `@end` tag lines of math blocks are concealed
	-- (hidden when conceallevel >= 2). Whole-row hiding needs Neovim >= 0.11;
	-- older versions fall back to character-level conceal (blank tag rows).
	conceal_math_tags = false,

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
	-- foreground of the `@norg.rendered.latex` highlight group is used
	-- (falling back to black), like neorg's own latex renderer.
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

	--- Extmark namespace used for all concealment placed by this module.
	ns = nil,

	--- Whether rendering is currently active.
	do_render = false,

	--- Per-buffer block state: bufnr -> { [math_row] = entry }.
	--- Each entry: { math_row, erow, indent, anchor_row, snippet, png, image,
	---               conceal_ids, tag_ids, surplus_ids, filler_id, shown, pending }
	blocks = {},

	--- Per-buffer debounce timer handles.
	timers = {},

	--- Whether the whole-row `conceal_lines` warning has been shown.
	row_hide_notified = false,

	--- Last time an error was notified per backend (throttle).
	last_error_notify = {},
}

--- Whether whole-row conceal (`conceal_lines`) is supported by this Neovim.
local row_hide_supported = vim.fn.has("nvim-0.11") == 1

--- Compute the foreground color and push the user configuration into the
--- backends module.
local function configure_backends()
	local hex = module.config.public.foreground_color
	if not hex then
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "@norg.rendered.latex", link = false })
		if ok and type(hl) == "table" and hl.fg then
			hex = ("#%06x"):format(hl.fg)
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

			-- Anchor the image at the first non-blank content line: a blank
			-- first line would give the column anchor nothing to hold on to.
			local anchor_row = math_row + 1
			for i, l in ipairs(lines) do
				if l:match("%S") then
					anchor_row = math_row + i
					break
				end
			end

			entries[math_row] = {
				math_row = math_row,
				erow = erow,
				indent = #((tag_line:match("^(%s*)")) or ""),
				anchor_row = anchor_row,
				snippet = snippet,
				has_content = snippet ~= "" and erow > math_row + 1,
			}
		end,
		buf
	)

	return entries
end

--- Is the cursor row "inside" `entry`? With conceal_math_tags the tag rows
--- count as inside too, mirroring neorg-nabla.
---@param entry table
---@param cursor_row integer 0-based
---@return boolean
local function cursor_inside(entry, cursor_row)
	if module.config.public.conceal_math_tags then
		return cursor_row >= entry.math_row and cursor_row <= entry.erow
	end
	return cursor_row > entry.math_row and cursor_row < entry.erow
end

--------------------------------------------------------------------------------
-- concealment
--------------------------------------------------------------------------------

--- Conceal the source text of one line. `from_col` leaves leading columns
--- visible: on the anchor row the block's indentation must stay visible,
--- because nvim computes screen columns with concealed ranges as zero-width
--- -- concealing across the anchor column would shift the image left onto
--- column 0 instead of the block's indent.
local function hide_line(buf, entry, r, from_col)
	local line = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
	local start_col = math.min(from_col or 0, #line)
	if start_col >= #line then
		return
	end
	local id = vim.api.nvim_buf_set_extmark(buf, module.private.ns, r, start_col, {
		end_row = r,
		end_col = #line,
		conceal = "",
		strict = false,
		undo_restore = false,
		invalidate = true,
	})
	if id then
		table.insert(entry.conceal_ids, id)
	end
end

--- Whole-row conceal a tag row on nvim >= 0.11; character-level fallback
--- with a one-time notice on 0.10.
local function hide_row(buf, entry, r)
	if row_hide_supported then
		local id = vim.api.nvim_buf_set_extmark(buf, module.private.ns, r, 0, {
			end_row = r,
			conceal_lines = "",
			strict = false,
			undo_restore = false,
			invalidate = true,
		})
		if id then
			table.insert(entry.tag_ids, id)
		end
	else
		if not module.private.row_hide_notified then
			module.private.row_hide_notified = true
			vim.notify_once(
				"neorg-math-renderer: whole-row tag hiding needs Neovim >= 0.11; "
					.. "conceal_math_tags falls back to blank tag rows",
				vim.log.levels.WARN
			)
		end
		hide_line(buf, entry, r)
	end
end

--- Remove all concealment extmarks belonging to `entry`.
local function clear_concealment(buf, entry)
	for _, id in ipairs(entry.conceal_ids) do
		vim.api.nvim_buf_del_extmark(buf, module.private.ns, id)
	end
	for _, id in ipairs(entry.tag_ids) do
		vim.api.nvim_buf_del_extmark(buf, module.private.ns, id)
	end
	for _, id in ipairs(entry.surplus_ids) do
		vim.api.nvim_buf_del_extmark(buf, module.private.ns, id)
	end
	entry.conceal_ids = {}
	entry.tag_ids = {}
	entry.surplus_ids = {}
	if entry.filler_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, module.private.ns, entry.filler_id)
		entry.filler_id = nil
	end
end

--------------------------------------------------------------------------------
-- image management
--------------------------------------------------------------------------------

--- Destroy the image object of `entry` (if any).
local function clear_image(entry)
	if entry.image then
		pcall(function()
			entry.image:clear()
		end)
		entry.image = nil
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

--- Whole-row conceal a surplus source row (below the rendered image). No
--- fallback on nvim < 0.11: the row keeps occupying a blank screen row there.
--- NOTE: surplus rows never coexist with filler virt_lines (surplus exists
--- only when the image is SHORTER than the content, filler only when it is
--- taller), so the nvim 0.12 conceal_lines + virt_lines viewport quirk seen
--- in neorg-nabla cannot trigger here.
local function hide_surplus_row(buf, entry, r)
	if not row_hide_supported then
		return
	end
	local id = vim.api.nvim_buf_set_extmark(buf, module.private.ns, r, 0, {
		end_row = r,
		conceal_lines = "",
		strict = false,
		undo_restore = false,
		invalidate = true,
	})
	if id then
		table.insert(entry.surplus_ids, id)
	end
end

--- Sync the vertical layout of `entry` with the rendered image size:
--- 1. the concealed content rows provide `covered` screen rows under the
---    image;
--- 2. when the image is taller, the remainder is added as virt_lines on the
---    last content row (mirrors neorg-nabla);
--- 3. when the image is shorter, the surplus content rows are hidden
---    entirely (whole-row conceal) instead of leaving blank rows.
--- This replaces image.nvim's own virtual padding, which would reserve the
--- FULL image height on top of the concealed source rows and produce
--- surplus blank lines.
local function update_layout(buf, entry)
	if entry.filler_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, module.private.ns, entry.filler_id)
		entry.filler_id = nil
	end
	for _, id in ipairs(entry.surplus_ids) do
		pcall(vim.api.nvim_buf_del_extmark, buf, module.private.ns, id)
	end
	entry.surplus_ids = {}
	if not entry.image then
		return
	end
	local rows = image_rows(entry.image)
	local covered = entry.erow - entry.anchor_row

	-- image shorter than the content: vanish the surplus source rows
	for r = entry.anchor_row + rows, entry.erow - 1 do
		hide_surplus_row(buf, entry, r)
	end

	-- image taller than the content: top up the remainder
	local extra = rows - covered
	if extra > 0 then
		local filler = {}
		for _ = 1, extra do
			filler[#filler + 1] = { { "", "" } }
		end
		entry.filler_id = vim.api.nvim_buf_set_extmark(buf, module.private.ns, entry.erow - 1, 0, {
			virt_lines = filler,
			strict = false,
			undo_restore = false,
			invalidate = true,
		})
	end
end

--- Create and render the image for `entry` from its cached PNG.
local function create_image(buf, entry)
	if not module.private.image or not entry.png then
		return
	end
	clear_image(entry)

	local ok, img = pcall(module.private.image.from_file, entry.png, {
		window = vim.api.nvim_get_current_win(),
		buffer = buf,
		inline = true,
		-- Space is managed by this module: the concealed content rows provide
		-- the screen rows they occupy, and update_filler() tops up the
		-- remainder. image.nvim's own padding would reserve the FULL image
		-- height on top of those rows, producing surplus blank lines.
		with_virtual_padding = false,
		x = entry.indent,
		y = entry.anchor_row,
		-- Without virtual padding the renderer lands the image one terminal
		-- row low; -1 compensates (same compensation core.integrations.image
		-- uses for inline math without padding).
		render_offset_top = -1,
		-- Native size by default: image.nvim's global max_*_window_percentage
		-- defaults (100% width / 50% height) must never shrink block images.
		-- 100000% effectively disables both caps; `fit_window` restores sane
		-- 100% caps (downscale only, never upscale).
		max_width_window_percentage = module.config.public.fit_window and 100 or 100000,
		max_height_window_percentage = module.config.public.fit_window and 100 or 100000,
	})
	if ok and img then
		entry.image = img
		pcall(function()
			img:render()
		end)
		update_layout(buf, entry)
	end
end

--------------------------------------------------------------------------------
-- per-entry apply / reveal
--------------------------------------------------------------------------------

--- Hide `entry`'s image and reveal the raw source.
local function reveal_entry(buf, entry)
	entry.shown = false
	clear_image(entry)
	clear_concealment(buf, entry)
end

--- Drop `entry` completely (block vanished from the buffer).
local function destroy_entry(buf, entry)
	reveal_entry(buf, entry)
end

--- Pending reposition sweeps per buffer (at most one per scheduler tick).
local reposition_pending = {}

--- Re-render every image in `buf` on the next scheduler tick. Revealing or
--- concealing one block changes the number of screen rows ABOVE other blocks
--- (and image.nvim only recomputes screen positions when an image is
--- rendered -- its decoration provider does not fire on extmark-caused row
--- shifts), so every layout change needs an explicit reposition sweep.
local function schedule_reposition(buf)
	if reposition_pending[buf] then
		return
	end
	reposition_pending[buf] = true
	vim.schedule(function()
		reposition_pending[buf] = nil
		if not module.private.do_render or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		for _, entry in pairs(module.private.blocks[buf] or {}) do
			if entry.image then
				pcall(function()
					entry.image:render()
				end)
			end
		end
	end)
end

--- Show `entry`: conceal the source and make sure the image is rendered.
local function show_entry(buf, entry)
	if entry.shown then
		return
	end
	entry.shown = true
	clear_concealment(buf, entry)

	-- content lines; the anchor row keeps its leading indentation columns
	-- visible so the image's x anchor is not shifted left by conceal width
	for r = entry.math_row + 1, entry.erow - 1 do
		if r == entry.anchor_row then
			hide_line(buf, entry, r, entry.indent)
		else
			hide_line(buf, entry, r)
		end
	end
	-- tag rows
	if module.config.public.conceal_math_tags then
		hide_row(buf, entry, entry.math_row)
		hide_row(buf, entry, entry.erow)
	end

	if entry.png then
		create_image(buf, entry)
	elseif not entry.pending and entry.has_content then
		entry.pending = true
		local snippet = entry.snippet
		backends.render(snippet, module.private.backend, function(png, err)
			entry.pending = false
			if err then
				module.private.report_error(module.private.backend, err)
			end
			if not vim.api.nvim_buf_is_valid(buf) or not module.private.do_render then
				return
			end
			local current = module.private.blocks[buf]
			local live = current and current[entry.math_row]
			-- The block may have changed while we were converting.
			if not live or live ~= entry or live.snippet ~= snippet then
				return
			end
			if not png then
				-- Nothing to show: un-conceal the source instead of hiding it
				-- under a nonexistent image.
				if entry.shown then
					reveal_entry(buf, entry)
				end
				return
			end
			-- Don't pop an image under the cursor while the user reads the source.
			local row = vim.api.nvim_win_get_cursor(0)[1] - 1
			if not vim.wo.conceallevel or vim.wo.conceallevel < 2 or cursor_inside(entry, row) then
				return
			end
			entry.png = png
			if not entry.shown then
				show_entry(buf, entry)
			else
				create_image(buf, entry)
			end
			-- The new image (and its filler) shifts every block below it.
			schedule_reposition(buf)
		end)
	end
end

------------------------------------------------------------------------------
-- rendering passes
--------------------------------------------------------------------------------

--- Full render of the current buffer: re-discover blocks, reconcile state,
--- and apply concealment/images to every block.
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
				anchor_row = want.anchor_row,
				snippet = want.snippet,
				has_content = want.has_content,
				png = nil,
				image = nil,
				conceal_ids = {},
				tag_ids = {},
				surplus_ids = {},
				filler_id = nil,
				shown = false,
				pending = false,
			}
			state[row] = entry
		else
			entry.erow = want.erow
			entry.indent = want.indent
			entry.anchor_row = want.anchor_row
			entry.has_content = want.has_content
		end

		-- Empty blocks have nothing to render; only conceal their tags.
		if not entry.has_content then
			if module.config.public.conceal_math_tags and vim.wo.conceallevel >= 2 then
				clear_concealment(buf, entry)
				hide_row(buf, entry, entry.math_row)
				hide_row(buf, entry, entry.erow)
			else
				clear_concealment(buf, entry)
				clear_image(entry)
				entry.shown = false
			end
		else
			local row = vim.api.nvim_win_get_cursor(0)[1] - 1
			if cursor_inside(entry, row) or (vim.wo.conceallevel or 0) < 2 then
				reveal_entry(buf, entry)
			else
				show_entry(buf, entry)
			end
		end
	end

	module.private.blocks[buf] = state
	schedule_reposition(buf)
end

--- Light pass on cursor movement: only toggle reveal/conceal for blocks the
--- cursor entered or left. No tree-sitter query, no conversions.
local function update_cursor(buf)
	local state = module.private.blocks[buf]
	if not state or not module.private.do_render then
		return
	end

	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local conceal_ok = (vim.wo.conceallevel or 0) >= 2
	local changed = false

	for _, entry in pairs(state) do
		local want_shown = conceal_ok and entry.has_content and not cursor_inside(entry, row)
		if want_shown ~= entry.shown then
			if want_shown then
				show_entry(buf, entry)
			else
				reveal_entry(buf, entry)
			end
			changed = true
		end
	end

	-- A reveal/conceal toggles screen rows; every other image must re-anchor.
	if changed then
		schedule_reposition(buf)
	end
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
			entry.conceal_ids = {}
			entry.tag_ids = {}
			entry.surplus_ids = {}
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
	-- image objects are window-bound; re-render them when a window re-enters
	-- the buffer (mirrors core.latex.renderer's show_hidden).
	for _, entry in pairs(module.private.blocks[buf] or {}) do
		if entry.shown and entry.image then
			pcall(function()
				entry.image:render()
			end)
		end
	end
end

local function colorscheme_changed()
	-- The foreground color is part of the cache key, so stale images are
	-- invalidated automatically; just forget the in-memory copies.
	configure_backends()
	for _, state in pairs(module.private.blocks) do
		for _, entry in pairs(state) do
			clear_image(entry)
			entry.png = nil
		end
	end
	if module.private.do_render then
		for buf in pairs(module.private.blocks) do
			if vim.api.nvim_buf_is_valid(buf) then
				schedule_render(buf, 0)
			end
		end
	end
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
		-- First entry into a buffer we have not rendered yet (e.g. BufReadPost
		-- fired before the module loaded or before ft was set to norg): render
		-- it now. full_render records state even for block-less buffers, so
		-- this stays a one-shot per buffer.
		if module.private.do_render and module.private.blocks[event.buffer] == nil then
			full_render(event.buffer)
		end
		show_hidden(event.buffer)
	end,
	["core.autocommands.events.cursormoved"] = function(event)
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
		if not vim.api.nvim_buf_is_valid(event.buffer) or vim.bo[event.buffer].ft ~= "norg" then
			return
		end
	end
	return event_handlers[event.type](event)
end

module.events.subscribed = {
	["core.autocommands"] = {
		bufreadpost = true,
		bufwinenter = true,
		cursormoved = true,
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

	configure_backends()

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
	for _, name in ipairs({ "BufReadPost", "BufWinEnter", "CursorMoved", "TextChanged", "InsertLeave", "Colorscheme" }) do
		module.required["core.autocommands"].enable_autocommand(name)
	end

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

	--- Clear all images and concealment from `buf` (defaults to current).
	clear = function(buf)
		buf = buf or vim.api.nvim_get_current_buf()
		local state = module.private.blocks[buf] or {}
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, module.private.ns, 0, -1)
		end
		for _, entry in pairs(state) do
			clear_image(entry)
			entry.conceal_ids = {}
			entry.tag_ids = {}
			entry.shown = false
		end
	end,

	--- Name of the resolved backend, or nil if none was found.
	get_backend = function()
		return module.private.backend
	end,
}

return module
