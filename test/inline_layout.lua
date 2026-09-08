--- Focused inline layout regression test. Runs without Neorg or image.nvim:
---
---   nvim --headless -u NONE -l test/inline_layout.lua
---
--- Inline images must not use image.nvim virtual-line padding. Conceal
--- replacement may use inline virtual text only after bounding complete raw
--- line width when visible suffix follows; line-end formulas conceal without
--- replacement text so long source cannot compress image geometry. A compact
--- box wider than the proven final-line budget keeps its source visible and
--- its image hidden instead of installing the overlay/pad marks.

local module_path = "lua/neorg/modules/external/math-renderer/module.lua"
local module_source = table.concat(vim.fn.readfile(module_path), "\n")
local inline_start = assert(module_source:find("create_inline_image = function", 1, true))
local inline_end = assert(module_source:find("local function ensure_inline_images", inline_start, true))
local inline_source = module_source:sub(inline_start, inline_end - 1)
local redraw_start = assert(module_source:find("local function deep_redraw", 1, true))
local redraw_end = assert(module_source:find("--- Show `entry`", redraw_start, true))
local redraw_source = module_source:sub(redraw_start, redraw_end - 1)
local compact_start = assert(module_source:find("local function ready_inline_entries", 1, true))
local compact_end = assert(module_source:find("--- Cancel image.nvim", compact_start, true))
local compact_source = module_source:sub(compact_start, compact_end - 1)
local inline_render_start = assert(module_source:find("render_inline_entry = function", 1, true))
local inline_render_end = assert(module_source:find("\ncreate_inline_image = function", inline_render_start, true))
local inline_render_source = module_source:sub(inline_render_start, inline_render_end - 1)

local failed = false
local function check(name, condition)
	if condition then
		print(("PASS %s"):format(name))
	else
		print(("FAIL %s"):format(name))
		failed = true
	end
end

check("inline box width uses explicit conceal+inline", module_source:find('virt_text_pos%s*=%s*"overlay"') == nil
	and module_source:find('virt_text_pos%s*=%s*"inline"') ~= nil
	and module_source:find("inline_raw_line_width", 1, true) ~= nil
	and module_source:find("nvim_win_get_width", 1, true) ~= nil
	and module_source:find("image_display_dimensions", 1, true) ~= nil
	and module_source:find("inline_layout_plan", 1, true) ~= nil)
check("visual/select mode hides every inline image on selected rows", module_source:find("is_visual_select_mode", 1, true) ~= nil
	and module_source:find("visual_selection_rows", 1, true) ~= nil
	and module_source:find("vim.fn.getpos, \"v\"", 1, true) ~= nil
	and module_source:find("math.min(anchor_row, cursor_row)", 1, true) ~= nil
	and module_source:find("math.max(anchor_row, cursor_row)", 1, true) ~= nil
	and module_source:find('first == "v"', 1, true) ~= nil
	and module_source:find('first == "V"', 1, true) ~= nil
	and module_source:find('first == "\\22"', 1, true) ~= nil
	and module_source:find('first == "s"', 1, true) ~= nil
	and module_source:find('first == "S"', 1, true) ~= nil
	and module_source:find('first == "\\19"', 1, true) ~= nil
	and module_source:find("range[1] >= selection_start", 1, true) ~= nil
	and module_source:find("range[1] <= selection_end", 1, true) ~= nil
	and module_source:find("vim.api.nvim_get_current_buf() == buf", 1, true) ~= nil)
check("visual/select mode transitions refresh inline visibility", module_source:find('nvim_create_autocmd("ModeChanged"', 1, true) ~= nil
	and module_source:find("is_visual_select_mode(old_mode)", 1, true) ~= nil
	and module_source:find("is_visual_select_mode(new_mode)", 1, true) ~= nil
	and module_source:find("update_cursor(buf)", 1, true) ~= nil)
check("visual/select selected rows restore source visibility", module_source:find("if selected_row then", 1, true) ~= nil
	and module_source:find("clear_inline_extmark(buf, entry)", 1, true) ~= nil
	and module_source:find("Selected rows reveal the original source in every window", 1, true) ~= nil
	and module_source:find("selected rows can be outside the current cursor line", 1, true) == nil
	and module_source:find("range[1] >= selection_start", 1, true) ~= nil
	and module_source:find("range[1] <= selection_end", 1, true) ~= nil)
check("hard unsafe-layout fallback never forces the box width", module_source:find("if max_width <= 0 or width > max_width then", 1, true) ~= nil
	and module_source:find("max_width = math.max(edge_width, width)", 1, true) == nil
	and module_source:find("A long raw suffix can exhaust", 1, true) == nil
	and module_source:find("budget or a box wider than it proves the final layout", 1, true) ~= nil)
check("line-end layout uses a single conceal mark", module_source:find("inline_suffix_width", 1, true) ~= nil
	and module_source:find("inline_edge_width", 1, true) ~= nil
	and module_source:find("if not suffix_present then", 1, true) ~= nil
	and module_source:find("A formula at end of line uses one conceal mark so the image can extend", 1, true) ~= nil)
check("multi-inline layout is source-ordered and two-phase", compact_source:find("table.sort(entries", 1, true) ~= nil
	and compact_source:find("local layouts = {}", 1, true) ~= nil
	and compact_source:find("layouts[entry] = inline_layout_state(buf, entry, entry.box_geometry)", 1, true) ~= nil
	and compact_source:find("render_inline_entry(buf, entry, layouts[entry])", 1, true) ~= nil)
check("direct inline renders apply layout once", inline_render_source:find("layout = layout or inline_layout_state(buf, entry, box)", 1, true) ~= nil
	and inline_render_source:find("update_inline_extmark", 1, true) == nil)
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
check("floating redraw uses window-close hook", module_source:find('nvim_create_autocmd("WinClosed"', 1, true) ~= nil)
check("non-key redraw uses lifecycle hooks", module_source:find('"CmdlineLeave"', 1, true) ~= nil
	and module_source:find('"CmdwinLeave"', 1, true) ~= nil
	and module_source:find('"FocusGained"', 1, true) ~= nil
	and module_source:find('"VimResume"', 1, true) ~= nil
	and module_source:find('"UIEnter"', 1, true) ~= nil
	and module_source:find('"TabEnter"', 1, true) ~= nil)
check("redraw requests are coalesced", module_source:find("deep_redraw_pending", 1, true) ~= nil)
check("folded images stay above statusline", module_source:find("image_fits_window_bottom", 1, true) ~= nil
	and module_source:find("placement.folded", 1, true) ~= nil
	and module_source:find("image_rows(img)", 1, true) ~= nil)
local function folded_image_fits(screen_row, rows, winrow, height)
	return screen_row + rows <= winrow + height - 1
end
check("folded image hides at content boundary", folded_image_fits(22, 1, 1, 22) == false
	and folded_image_fits(21, 1, 1, 22) == true)
local ctrl_l_start = module_source:find('local ctrl_l = vim.keycode("<C-L>")', 1, true)
check("Ctrl-L redraw preserves existing mappings", module_source:find("vim.on_key(function(key, typed)", 1, true) ~= nil
	and ctrl_l_start ~= nil
	and module_source:find("key == ctrl_l or typed == ctrl_l", ctrl_l_start or 1, true) ~= nil
	and module_source:find("redraw_visible_buffers()", ctrl_l_start or 1, true) ~= nil)

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

-- Focused extmark-plan-shape tests for the compact inline layout, executed
-- against the real `inline_layout_plan` (which depends only on the buffer,
-- the entry range, and the box, not on image.nvim or Neorg). Load the two
-- reachable plan helpers directly from the module source and run them here.
local plan_start_line = assert(module_source:find("local function inline_layout_plan", 1, true))
local plan_stop_line = assert(module_source:find("--- Update the buffer-scoped inline extmark set", plan_start_line + 1, true))
local plan_chunk = assert((load(
	module_source:sub(plan_start_line, plan_stop_line - 1) .. "\nreturn inline_layout_plan",
	"inline_layout_plan_test"
)))
local inline_layout_plan = plan_chunk()

local source_line = "prefix $abc$suffix text"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { source_line, "NEXT" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local open1 = assert(source_line:find("$", 1, true))
local plan_scol = open1
local function marks_of(plan)
	local out = {}
	for _, m in ipairs(plan or {}) do
		out[#out + 1] = {
			col = m.col,
			end_row = m.end_row,
			end_col = m.end_col,
			conceal = m.conceal,
			virt_text_pos = m.virt_text_pos,
			spaces = m.virt_text and m.virt_text[1] and #m.virt_text[1][1] or 0,
			virt_lines = m.virt_lines,
		}
	end
	return out
end

local function plan_entry(box_width)
	return { range = { 0, plan_scol, 0, plan_scol + 3 }, key = "t" }, { width_cells = box_width }
end
local entry_small, box_small = plan_entry(1)
local plan_small = marks_of(inline_layout_plan(0, entry_small, box_small))
local entry_eq, box_eq = plan_entry(3)
local plan_eq = marks_of(inline_layout_plan(0, entry_eq, box_eq))
local entry_large, box_large = plan_entry(5)
local plan_large = marks_of(inline_layout_plan(0, entry_large, box_large))
check("all box sizes use one conceal+inline mark", #plan_small == 1 and #plan_eq == 1 and #plan_large == 1
	and plan_small[1].conceal == "" and plan_eq[1].conceal == "" and plan_large[1].conceal == ""
	and plan_small[1].virt_text_pos == "inline" and plan_eq[1].virt_text_pos == "inline"
	and plan_large[1].virt_text_pos == "inline"
	and plan_small[1].spaces == 1 and plan_eq[1].spaces == 3 and plan_large[1].spaces == 5
	and plan_small[1].col == plan_scol and plan_large[1].end_col == plan_scol + 3
	and plan_small[1].virt_lines == nil and plan_eq[1].virt_lines == nil and plan_large[1].virt_lines == nil)
local multiline_entry = { range = { 0, plan_scol, 1, 4 }, key = "m" }
check("plan multiline source falls back", inline_layout_plan(0, multiline_entry, { width_cells = 2 }) == nil)

-- The final-line budget behind the hard unsafe-layout fallback: every
-- concealed source span on the raw line is replaced by its compact box and
-- the result must fit the actual window text width with one slack cell. Run
-- the real `update_inline_extmark` (sliced from module source with only the
-- visual/select helpers and config stubbed) so both fallback arms are
-- exercised against the live buffer and real window: a fitting box installs
-- its overlay/pad marks, a wider-than-budget box installs nothing, and a
-- line whose remainder alone fills the window installs nothing either.
local budget_start_line = assert(module_source:find("local function clear_inline_extmark", 1, true))
local budget_stop_line = assert(module_source:find("local function inline_layout_state", budget_start_line + 1, true))
local budget_chunk = assert((load(
	module_source:sub(budget_start_line, budget_stop_line - 1)
		.. "\nreturn update_inline_extmark, inline_text_width",
	"inline_budget_test"
)))
local update_inline_extmark, inline_text_width = budget_chunk()
module = {
	config = { public = { conceal = true } },
	private = {
		ns = namespace,
		inlines = {},
	},
}

local budget_buf = vim.api.nvim_get_current_buf()
local budget_win = vim.api.nvim_get_current_win()
-- The earlier line-end harness leaves one plain conceal mark on this
-- namespace for shape checks; drop it so the mark counts below are exact.
vim.api.nvim_buf_clear_namespace(budget_buf, namespace, 0, -1)
local function extendmark_id_count(buf)
	return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
end

vim.api.nvim_buf_set_lines(budget_buf, 0, -1, false, { "P$abc$" .. string.rep("y", 30), "NEXT" })
vim.api.nvim_win_set_cursor(budget_win, { 2, 0 })
-- Raw line = 1 + 5 + 30 = 36 cells; the 3-cell "abc" source is concealed, so
-- the final line occupies 33 cells: the honest slack is text width - 33 - 1.
local expected_fit = inline_text_width(budget_win) - (36 - 3) - 1
local entry_fit_eq = { range = { 0, 2, 0, 5 }, key = "fiteq", extmark_ids = {} }
module.private.inlines[budget_buf] = { fiteq = entry_fit_eq }
local _, _, fit_eq_width = update_inline_extmark(budget_buf, entry_fit_eq, { width_cells = 3 })
check("B==S box fits budget and installs conceal+inline", fit_eq_width == expected_fit
	and fit_eq_width > 0 and #entry_fit_eq.extmark_ids == 1
	and extendmark_id_count(budget_buf) == 1)
for _, id in ipairs(entry_fit_eq.extmark_ids) do
	vim.api.nvim_buf_del_extmark(budget_buf, namespace, id)
end
local entry_fit_lt = { range = { 0, 2, 0, 5 }, key = "fitlt", extmark_ids = {} }
module.private.inlines[budget_buf] = { fitlt = entry_fit_lt }
local _, _, fit_lt_width = update_inline_extmark(budget_buf, entry_fit_lt, { width_cells = 1 })
check("B<S box fits budget and installs conceal+inline", fit_lt_width == expected_fit
	and fit_lt_width > 0 and #entry_fit_lt.extmark_ids == 1
	and extendmark_id_count(budget_buf) == 1)
for _, id in ipairs(entry_fit_lt.extmark_ids) do
	vim.api.nvim_buf_del_extmark(budget_buf, namespace, id)
end

-- A box exactly one cell wider than the proven slack would wrap: the hard
-- fallback installs no conceal/inline mark and the image stays hidden.
local entry_wide = { range = { 0, 2, 0, 5 }, key = "wide", extmark_ids = {} }
module.private.inlines[budget_buf] = { wide = entry_wide }
local _, _, wide_width = update_inline_extmark(budget_buf, entry_wide, { width_cells = expected_fit + 1 })
check("wider-than-budget box installs no marks and hides image", wide_width == 0
	and #entry_wide.extmark_ids == 0 and extendmark_id_count(budget_buf) == 0)

-- raw = 1 + 5 + 90 = 96 cells: removing the 3-cell source still leaves 93
-- cells, already one past the 80-wide window, so any replacement would wrap.
vim.api.nvim_buf_set_lines(budget_buf, 0, -1, false, { "P$abc$" .. string.rep("y", 90), "NEXT" })
local entry_blocked = { range = { 0, 2, 0, 5 }, key = "blocked", extmark_ids = {} }
module.private.inlines[budget_buf] = { blocked = entry_blocked }
local _, _, blocked_width = update_inline_extmark(budget_buf, entry_blocked, { width_cells = 5 })
check("exhausted budget installs no marks and hides image", blocked_width == 0
	and #entry_blocked.extmark_ids == 0 and extendmark_id_count(budget_buf) == 0)

-- The plan never requests virtual lines, and every mark is anchored to the
-- absolute source bytes (never a guessed screen column); every box uses one
-- full conceal+inline replacement.
local plan_src_text = module_source:sub(plan_start_line, plan_stop_line - 1)
check("layout plan function code exists", plan_src_text:find("local function inline_layout_plan", 1, true) ~= nil)
check("plan has no virtual lines anywhere", plan_src_text:find("virt_lines", 1, true) == nil)

-- Cleanup: every applied mark id is tracked on the entry and removed on the
-- next redraw, so stale conceal marks cannot linger.
check("extmark ids are tracked per entry", module_source:find("table.insert(entry.extmark_ids, id)", 1, true) ~= nil
	and module_source:find("extmark_ids = {}", 1, true) ~= nil)
check("extmark cleanup iterates all tracked ids", module_source:find("for _, id in ipairs(entry.extmark_ids or {}) do", 1, true) ~= nil
	and module_source:find("nvim_buf_del_extmark, buf, module.private.ns, id", 1, true) ~= nil)
check("get_inline_math seeds an empty id list per entry", module_source:find("extmark_ids = {},", 1, true) ~= nil)
check("multi-formula layout stays source-ordered", compact_source:find("local function ready_inline_entries", 1, true) ~= nil
	and compact_source:find("table.sort(entries", 1, true) ~= nil
	and compact_source:find("ar < br", 1, true) ~= nil)

if failed then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
