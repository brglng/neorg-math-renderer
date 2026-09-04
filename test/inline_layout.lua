--- Focused inline layout regression test. Runs without Neorg or image.nvim:
---
---   nvim --headless -u NONE -l test/inline_layout.lua
---
--- Inline images must not use image.nvim virtual-line padding. Conceal
--- replacement may use inline virtual text only after bounding complete raw
--- line width when visible suffix follows; line-end formulas conceal without
--- replacement text so long source cannot compress image geometry.

local module_path = "lua/neorg/modules/external/math-renderer/module.lua"
local module_source = table.concat(vim.fn.readfile(module_path), "\n")
local inline_start = assert(module_source:find("create_inline_image = function", 1, true))
local inline_end = assert(module_source:find("local function ensure_inline_images", inline_start, true))
local inline_source = module_source:sub(inline_start, inline_end - 1)
local redraw_start = assert(module_source:find("local function deep_redraw", 1, true))
local redraw_end = assert(module_source:find("--- Show `entry`", redraw_start, true))
local redraw_source = module_source:sub(redraw_start, redraw_end - 1)

local failed = false
local function check(name, condition)
	if condition then
		print(("PASS %s"):format(name))
	else
		print(("FAIL %s"):format(name))
		failed = true
	end
end

check("inline placeholder width is layout-bounded", module_source:find('virt_text_pos%s*=%s*"inline"') ~= nil
	and module_source:find("inline_raw_line_width", 1, true) ~= nil
	and module_source:find("nvim_win_get_width", 1, true) ~= nil
	and module_source:find("image_display_dimensions", 1, true) ~= nil
	and module_source:find('virt_text_pos%s*=%s*"overlay"') == nil)
check("line-end layout bypasses raw-line budget", module_source:find("inline_suffix_width", 1, true) ~= nil
	and module_source:find("inline_edge_width", 1, true) ~= nil
	and module_source:find("suffix_present and inline_max_width", 1, true) ~= nil
	and module_source:find("End-of-line conceal intentionally has no replacement text", 1, true) ~= nil)
check("inline image disables virtual padding", inline_source:find("with_virtual_padding%s*=%s*false") ~= nil)
check("inline image has no virtual-line options", inline_source:find("virt_lines") == nil)
check("inline geometry uses ceil-cell box", module_source:find("math.ceil(scaled_width / term.cell_width)", 1, true) ~= nil
	and module_source:find("math.ceil(scaled_height / term.cell_height)", 1, true) ~= nil
	and module_source:find("image.geometry.width = box.width_cells", 1, true) ~= nil
	and module_source:find("image.geometry.height = box.height_rows", 1, true) ~= nil)
check("inline letterbox pads without stretching", module_source:find('"-gravity", "Center"', 1, true) ~= nil
	and module_source:find('"-extent"', 1, true) ~= nil
	and module_source:find('"-resize"', 1, true) ~= nil)
check("letterbox honors background_color", module_source:find('background = bg == "transparent" and "none" or tostring(bg)', 1, true) ~= nil)
check("PNG signature parser uses 0x1a", module_source:find("0x1a", 1, true) ~= nil
	and module_source:find("\\032", 1, true) == nil)
check("letterbox result is cached", module_source:find("/pad", 1, true) ~= nil
	and module_source:find("ensure_inline_box_png", 1, true) ~= nil
	and module_source:find("box_key", 1, true) ~= nil)
check("resize invalidates letterbox cache", module_source:find('create_autocmd("VimResized"', 1, true) ~= nil)
check("inline ignores global image size caps", module_source:find("image.ignore_global_max_size = true", 1, true) ~= nil)
check("scale cap uses strict greater comparison", module_source:find("native_rows > cap", 1, true) ~= nil)
check("width overflow uses safe fallback", module_source:find("return 0, 0, 0, 0", 1, true) ~= nil)
check("renderer config is removed", module_source:find("renderer%s*=", 1) == nil
	and module_source:find("compatibility-only", 1, true) == nil)
check("color config uses Normal fallback", module_source:find('highlight_color("Normal", "fg")', 1, true) ~= nil
	and module_source:find("#808080", 1, true) == nil
	and module_source:find("background_color = nil", 1, true) ~= nil)
check("render guards stale buffer positions", module_source:find("buffer_position_valid", 1, true) ~= nil)
check("deferred image renders are guarded", module_source:find("guard_image_render", 1, true) ~= nil)
check("insert edits clear stale images", module_source:find("events.textchangedi", 1, true) ~= nil)
check("floating redraw renders block images", redraw_source:find("update_reservation(buf, entry)", 1, true) ~= nil
	and redraw_source:find("render_entry_image(buf, entry, win, img)", 1, true) ~= nil)
local redraw_definition = module_source:find("local function redraw_visible_buffers", 1, true)
local redraw_definition_end = redraw_definition and module_source:find("\n", redraw_definition, true)
local first_redraw_handler = redraw_definition_end
	and module_source:find("redraw_visible_buffers()", redraw_definition_end + 1, true)
check("floating redraw covers visible split buffers", redraw_definition ~= nil
	and module_source:find("#vim.fn.win_findbuf(buf) > 0", redraw_definition, true) ~= nil
	and first_redraw_handler ~= nil)
check("floating redraw uses window-close hook", module_source:find('nvim_create_autocmd("WinClosed"', 1, true) ~= nil
	and module_source:find('nvim_create_autocmd({ "CmdlineLeave"', 1, true) == nil
	and module_source:find('nvim_create_autocmd("CmdlineEnter"', 1, true) == nil)

-- Production letterboxes every inline formula: scale by one proportional
-- factor, round the terminal-cell box UP to whole cells, then pad the PNG to
-- the exact box (centered vertically and horizontally). The padded
-- PNG matches the geometry pixel-for-pixel, so image.nvim applies no
-- transform and no second rounding rule can distort the formula.
local function inline_box(image_width, image_height, cell_width, cell_height, scale_cap)
	local native_rows = image_height / cell_height
	local factor = 1
	if scale_cap and native_rows > scale_cap then
		factor = scale_cap / native_rows
	end
	local scaled_w = math.max(1, math.floor(image_width * factor + 0.5))
	local scaled_h = math.max(1, math.floor(image_height * factor + 0.5))
	local box_w = math.max(1, math.ceil(scaled_w / cell_width))
	local box_h = math.max(1, math.ceil(scaled_h / cell_height))
	return scaled_w, scaled_h, box_w, box_h, factor
end

local image_width, image_height = 1010, 100
local cell_width, cell_height = 10, 16
local native_rows = image_height / cell_height
local scale_cap = 0.5
local scaled_w, scaled_h, box_w, box_h, factor = inline_box(
	image_width,
	image_height,
	cell_width,
	cell_height,
	scale_cap
)
local box_pw, box_ph = box_w * cell_width, box_h * cell_height
local box_aspect = box_pw / box_ph
local scaled_aspect = scaled_w / scaled_h
check("box is at least the scaled formula", box_pw >= scaled_w and box_ph >= scaled_h)
check("box rounds up to whole cells", box_w == math.ceil(scaled_w / cell_width)
	and box_h == math.ceil(scaled_h / cell_height))
check("scaled size respects the height cap", scaled_h <= scale_cap * cell_height + 0.5)
check("scaled size never upscales", scaled_w <= image_width and scaled_h <= image_height)
check("padding never exceeds one cell per axis", box_pw - scaled_w < cell_width
	and box_ph - scaled_h < cell_height)

-- Equal-to-cap native height keeps the native factor; a sub-cap formula is
-- never enlarged.
local _, _, _, _, native_factor = inline_box(image_width, image_height, cell_width, cell_height, native_rows)
local _, _, _, _, short_factor = inline_box(image_width, image_height, cell_width, cell_height, native_rows + 1)
check("height at cap keeps native factor", native_factor == 1)
check("height below cap keeps native factor", short_factor == 1)

vim.o.lines = 12
vim.wo.conceallevel = 2
vim.wo.concealcursor = ""

local namespace = vim.api.nvim_create_namespace("neorg-math-renderer-inline-layout-test")
local sos_line = [[    - $|G_{\text{SOS}} = -26.0342|$：`tf2sos(b,a)` 产生的标量增益]]

local function next_line_screen_row(line, virtual_text_pos, width)
	local open = assert(line:find("$|", 1, true))
	local close = assert(line:find("|$", open + 2, true))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { line, "NEXT" })
	vim.api.nvim_buf_clear_namespace(0, namespace, 0, -1)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	local opts = {
		end_col = close + 1,
		conceal = "",
		strict = false,
	}
	if virtual_text_pos and width then
		opts.virt_text = { { string.rep(" ", width), "" } }
		opts.virt_text_pos = virtual_text_pos
	end
	vim.api.nvim_buf_set_extmark(0, namespace, 0, open - 1, opts)
	vim.cmd("redraw!")
	local first = vim.fn.screenpos(0, 1, 1)
	local next_line = vim.fn.screenpos(0, 2, 1)
	return first.row, next_line.row
end

vim.wo.wrap = true

-- An unbounded inline replacement reproduces unwanted wrapping. Production
-- code must never choose this width; it is retained as a focused TUI guard.
local window_width = vim.api.nvim_win_get_width(0)
local unsafe_row, unsafe_next_row = next_line_screen_row(sos_line, "inline", window_width)
check("unbounded inline placeholder reproduces wrapping", unsafe_next_row > unsafe_row + 1)

-- Regress exact reported line: production bounds replacement width by the
-- actual window width and complete raw/display line. Assert rendered screen
-- cells, not only buffer bytes, so concealed image cannot hide the CJK suffix
-- or create an extra row for the next buffer line.
local raw_width = vim.fn.strdisplaywidth(sos_line)
local safe_width = math.max(1, math.min(25, window_width - raw_width - 1))
local sos_row, sos_next_row = next_line_screen_row(sos_line, "inline", safe_width)
local screen = ""
for col = 1, window_width do
	screen = screen .. vim.fn.screenstring(sos_row, col)
end
local marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
local details_opts = marks[1] and marks[1][4] or {}
check("G_SOS list indentation remains visible", screen:sub(1, 6) == "    - ")
check("G_SOS suffix remains visible", screen:find("产生的", 1, true) ~= nil
	and screen:find("标量增益", 1, true) ~= nil)
check("G_SOS placeholder is bounded", safe_width + raw_width < window_width)
check("G_SOS bounded placeholder adds no screen row", sos_next_row == sos_row + 1)
check("G_SOS uses no virtual lines", details_opts.virt_lines == nil)

-- Exact regression line from reported failure. Its raw source is wider than
-- normal headless window, but formula starts near left edge. Production must
-- use edge width after classifying suffix as whitespace-only, not raw-line
-- leftover (which is zero here); the resulting width remains substantial.
local line_end = [[    - $|\text{bit} = \text{LFSR} \;\&\; 1, \quad \text{feedback} = \text{popcount}(\text{LFSR} \;\&\; \text{poly}) \bmod 2|$]]
local line_end_raw_width = vim.fn.strdisplaywidth(line_end)
local line_end_open = assert(line_end:find("$|", 1, true))
local line_end_prefix_width = vim.fn.strdisplaywidth(line_end:sub(1, line_end_open - 1))
local raw_leftover = math.max(0, window_width - line_end_raw_width - 1)
local edge_width = math.max(1, window_width - line_end_prefix_width - 1)
next_line_screen_row(line_end, nil, nil)
local end_marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
local end_details = end_marks[1] and end_marks[1][4] or {}
check("exact long line-end formula is wider than window", line_end_raw_width > window_width)
check("line-end production width is not near-zero", edge_width > raw_leftover
	and edge_width >= math.max(2, math.floor(window_width / 2)))
check("line-end conceal has no replacement text", end_details.virt_text == nil)
check("line-end conceal uses no virtual lines", end_details.virt_lines == nil)

if failed then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
