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
local inline_start = assert(module_source:find("local function create_inline_image", 1, true))
local inline_end = assert(module_source:find("local function ensure_inline_images", inline_start, true))
local inline_source = module_source:sub(inline_start, inline_end - 1)

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
	and module_source:find("exact_height", 1, true) ~= nil
	and module_source:find('virt_text_pos%s*=%s*"overlay"') == nil)
check("line-end layout bypasses raw-line budget", module_source:find("inline_suffix_width", 1, true) ~= nil
	and module_source:find("inline_edge_width", 1, true) ~= nil
	and module_source:find("suffix_present and inline_max_width", 1, true) ~= nil
	and module_source:find("End-of-line conceal intentionally has no replacement text", 1, true) ~= nil)
check("inline image disables virtual padding", inline_source:find("with_virtual_padding%s*=%s*false") ~= nil)
check("inline image has no virtual-line options", inline_source:find("virt_lines") == nil)
check("render guards stale buffer positions", module_source:find("buffer_position_valid", 1, true) ~= nil)
check("deferred image renders are guarded", module_source:find("guard_image_render", 1, true) ~= nil)
check("insert edits clear stale images", module_source:find("events.textchangedi", 1, true) ~= nil)

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
