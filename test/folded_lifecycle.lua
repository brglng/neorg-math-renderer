--- Folded block regressions using the installed image.nvim renderer, Image
--- objects, and native focus/resize handlers with real Neovim folds/extmarks.
--- Terminal geometry, tmux queries, PNG processing, and graphics output are
--- controlled doubles: this is not a live tmux or physical-display test.
---
---   nvim --headless -u NONE -l test/folded_lifecycle.lua
---   IMAGE_NVIM_PATH=/path/to/image.nvim nvim --headless -u NONE -l test/folded_lifecycle.lua

package.path = "lua/?.lua;" .. package.path
local image_path = vim.env.IMAGE_NVIM_PATH or (vim.fn.stdpath("data") .. "/lazy/image.nvim")
assert(vim.fn.isdirectory(image_path .. "/lua/image") == 1, "Set IMAGE_NVIM_PATH to an installed image.nvim checkout")
vim.opt.runtimepath:prepend(image_path)

local failed = false
local function check(name, condition)
	print((condition and "PASS " or "FAIL ") .. name)
	failed = failed or not condition
end

local term = { screen_cols = 80, screen_rows = 24, cell_width = 20, cell_height = 40 }
package.loaded["image/utils/term"] = {
	get_size = function() return term end,
	get_tty = function() return "/dev/null" end,
}
local tmux_window, tmux_session = "@editor", "$editor"
package.loaded["image/utils/tmux"] = {
	is_tmux = true,
	get_window_id = function() return tmux_window end,
	get_current_session = function() return tmux_session end,
}
local transforms, conversions = 0, 0
local pending_transforms = {}
local defer_transforms = false
package.loaded["image/processors"] = {
	create_lazy_processor = function()
		return {
			get_format = function() return "png" end,
			get_dimensions = function() return { width = 480, height = 160 } end,
			transform = function(source, _, path, callback)
				transforms = transforms + 1
				local complete = function()
					assert(vim.uv.fs_copyfile(source, path))
					callback({ ok = true, path = path })
				end
				if defer_transforms then
					pending_transforms[#pending_transforms + 1] = complete
				else
					vim.schedule(complete)
				end
			end,
		}
	end,
}
package.loaded["neorg.core"] = {
	modules = {
		create = function(name)
			return { name = name, config = { public = {} }, private = {}, required = {}, events = {}, public = {} }
		end,
		await = function(_, callback) callback({ add_commands_from_table = function() end }) end,
	},
}
package.loaded["neorg.modules.external.math-renderer.backends"] = {
	setup = function() end,
	resolve = function() return "test" end,
	render = function() conversions = conversions + 1; error("Cached blocks must not reconvert") end,
}

-- Only the file signature/stat is needed by the controlled processor. The
-- renderer uses its reported 480x160 dimensions; graphics bytes are not sent.
local png = vim.fn.tempname() .. ".png"
local file = assert(io.open(png, "wb"))
file:write(vim.base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jlp8AAAAASUVORK5CYII="))
file:close()

local image = require("image")
image.setup({
	integrations = {
		markdown = { enabled = false }, asciidoc = { enabled = false }, typst = { enabled = false },
		neorg = { enabled = false }, syslang = { enabled = false }, html = { enabled = false },
		css = { enabled = false }, org = { enabled = false },
	},
	tmux_show_only_in_active_window = true,
	hijack_file_patterns = {},
})
local state = assert(image.from_file(png)).global_state
local paints, clears = 0, 0
package.loaded["image/backends/kitty/helpers"] = {
	write_graphics = function() end,
	restore_cursor = function() end,
	write_placeholder = function() end,
	write_graphics_at = function(payload, x, y)
		state.last_display = { payload = vim.deepcopy(payload), x = x - 1, y = y - 1 }
	end,
}
local kitty = require("image/backends/kitty")
kitty.state = state
state.backend = {
	features = { crop = true },
	render = function(img, x, y, width, height)
		paints = paints + 1
		state.images[img.id] = img
		img.is_rendered = true
		img.last_paint = { x = x, y = y, width = width, height = height }
		-- Exercise Kitty's actual source-pixel crop payload with graphics I/O
		-- stubbed, rather than assuming the requested bounds imply clipping.
		kitty.render(img, x, y, width, height)
		img.last_display = vim.deepcopy(state.last_display)
	end,
	clear = function(id, shallow)
		clears = clears + 1
		local img = state.images[id]
		if img then img.is_rendered = false end
		if not shallow then state.images[id] = nil end
	end,
}

local module = require("neorg.modules.external.math-renderer.module")
module.required["core.autocommands"] = { enable_autocommand = function() end }
module.load()
module.private.do_render = true
vim.o.lines = 24
vim.o.columns = 80
vim.o.laststatus = 2
vim.o.showtabline = 0
vim.wo.number = false
vim.wo.signcolumn = "no"
vim.wo.foldcolumn = "0"
vim.wo.conceallevel = 2
vim.wo.foldmethod = "manual"

local function settle()
	vim.wait(30, function() return false end)
end

local function refresh(buf)
	module.on_event({ referrer = "core.autocommands", type = "core.autocommands.events.winenter", buffer = buf })
	vim.cmd("redraw!")
	settle()
end

local function seed(lines, math_row, erow, indent, position, fit_window)
	vim.cmd("enew!")
	vim.bo.filetype = "norg"
	vim.wo.foldmethod = "manual"
	vim.cmd("normal! zE")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	module.config.public.position = position or "below"
	module.config.public.hide_on_fold = false
	module.config.public.fit_window = fit_window ~= false
	local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	local entry = {
		math_row = math_row, erow = erow, indent = indent, snippet = "x^2", has_content = true,
		png = png, images = {}, shown = true,
	}
	module.private.blocks[buf] = { [math_row] = entry }
	module.private.inlines[buf] = nil
	refresh(buf)
	return buf, win, entry, assert(entry.images[win])
end

local function close_fold(buf, entry)
	vim.cmd(("%d,%dfold"):format(entry.math_row + 1, entry.erow + 1))
	refresh(buf)
end

local function reservation_height(buf, entry)
	if not entry.reservation_id then return 0 end
	local mark = vim.api.nvim_buf_get_extmark_by_id(buf, module.private.ns, entry.reservation_id, { details = true })
	return mark[3] and #(mark[3].virt_lines or {}) or 0
end

-- Empty adjacent rows cannot resolve an indented buffer column. Preserve
-- indentation and native size in the absolute fallback, including density
-- changes while the image's previous rendered_geometry is still populated.
local buf, win, entry, img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4)
local native_width, native_height = img.rendered_geometry.width, img.rendered_geometry.height
local native_transforms = transforms
close_fold(buf, entry)
check("folding reuses the native PNG/transform", transforms == native_transforms)
check("short adjacent row preserves absolute indentation", img.math_renderer_absolute
	and img.last_paint.x == vim.fn.getwininfo(win)[1].wincol - 1 + 4)
check("folded size equals unfolded native size", img.last_paint.width == native_width and img.last_paint.height == native_height)
check("folded reservation remains outside the fold", entry.reservation_row == 4 and entry.reservation_above
	and reservation_height(buf, entry) == native_height)
check("folded formula starts immediately below summary", img.last_paint.y == vim.fn.screenpos(win, 2, 1).row)

term.cell_width, term.cell_height = 10, 20
vim.api.nvim_exec_autocmds("VimResized", {})
settle()
vim.cmd("redraw!")
img:render()
settle()
check("non-Retina cell geometry preserves reference folded size", img.last_paint.width == native_width
	and img.last_paint.height == native_height and native_width == 24 and native_height == 4)
check("non-Retina geometry preserves reserved rows", entry.reservation_rows == 4 and reservation_height(buf, entry) == 4)
vim.cmd("normal! zR")
refresh(buf)
check("unfolding refreshes normalized geometry and restores binding", img.window == win and img.buffer == buf
	and img.inline and img.geometry.width == 24 and img.geometry.height == 4)
check("non-Retina folded/unfolded sizes agree", img.last_paint.width == 24 and img.last_paint.height == 4)
term.cell_width, term.cell_height = 20, 40
vim.api.nvim_exec_autocmds("VimResized", {})
img:render()
settle()
check("returning to Retina geometry preserves folded size", img.last_paint.width == 24
	and img.last_paint.height == 4 and reservation_height(buf, entry) == 4)
term.cell_width, term.cell_height = 10, 20
vim.api.nvim_exec_autocmds("VimResized", {})
img:render()
settle()
close_fold(buf, entry)

-- Exercise image.nvim's real FocusLost/FocusGained handlers, not a custom
-- imitation. Module sweeps and transform callbacks must respect their state.
tmux_window = "@other"
vim.api.nvim_exec_autocmds("FocusLost", {})
settle()
check("native tmux window switch clears folded fallback", state.disable_decorator_handling and not img.is_rendered)
local inactive_paints = paints
img:render()
vim.api.nvim_exec_autocmds("WinResized", {})
refresh(buf)
check("inactive native callbacks and module sweeps do not repaint", paints == inactive_paints and not img.is_rendered)
tmux_window = "@editor"
vim.api.nvim_exec_autocmds("FocusGained", {})
settle()
check("native tmux return restores existing folded image", not state.disable_decorator_handling and img.is_rendered)
check("tmux return preserves fold position and indentation", img.last_paint.x == 4
	and img.last_paint.y == vim.fn.screenpos(win, 2, 1).row)

-- Finish the existing delayed FocusGained object recreation before keeping
-- resize references. Explicitly sync both splits: the stubbed Neorg event
-- system does not create the new split's image automatically.
vim.wait(150, function() return false end)

-- Per-image native window caps can give the same PNG different heights in
-- each split. The shared reservation must equal their maximum.
vim.cmd("vsplit")
local wider_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(win, 20)
vim.api.nvim_set_current_win(win)
refresh(buf)
check("fit_window true keeps native window cap after normalization", entry.images[win].rendered_geometry.width == 20
	and entry.images[win].rendered_geometry.height == 4)
entry.images[win].max_height_window_percentage = 10
vim.api.nvim_exec_autocmds("WinResized", {})
vim.cmd("redraw!")
local resize_ready = vim.wait(1000, function()
	local narrow = entry.images[win]
	local wider = entry.images[wider_win]
	return narrow and wider and narrow.is_rendered and wider.is_rendered
		and narrow.rendered_geometry.width == 12 and narrow.rendered_geometry.height == 2
		and wider.rendered_geometry.width == 24 and wider.rendered_geometry.height == 4
end)
check("window resize completes both split renders", resize_ready)
img = assert(entry.images[win])
local wider_img = assert(entry.images[wider_win])
check("folded fallback honors native window caps", img.rendered_geometry.width == 12 and img.rendered_geometry.height == 2)
check("wider split retains its normalized image height", wider_img.rendered_geometry.width == 24 and wider_img.rendered_geometry.height == 4)
local max_height = math.max(img.rendered_geometry.height, wider_img.rendered_geometry.height)
check("window resize refreshes reservations", reservation_height(buf, entry) == max_height
	and entry.reservation_rows == max_height and max_height == 4)
check("window resize preserves chosen fold driver and outside anchor", entry.reservation_win == win
	and entry.reservation_row == 4 and entry.reservation_above)
local capped_width, capped_height = img.rendered_geometry.width, img.rendered_geometry.height
vim.cmd("normal! zR")
refresh(buf)
check("window-capped folded/unfolded sizes agree", img.last_paint.width == capped_width and img.last_paint.height == capped_height)
vim.cmd("only")
settle()

-- A pending native transform must not repaint on completion after focus loss.
local pending_buf, _, pending_entry, pending_img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4)
close_fold(pending_buf, pending_entry)
state.options.scale_factor = 0.81
pending_img:clear(true)
defer_transforms = true
pending_img:render()
check("native transform is pending for new geometry", #pending_transforms > 0)
tmux_session = "$other"
vim.api.nvim_exec_autocmds("FocusLost", {})
settle()
inactive_paints = paints
for _, complete in ipairs(pending_transforms) do complete() end
pending_transforms = {}
settle()
check("pending transform cannot repaint inactive tmux session", paints == inactive_paints and not pending_img.is_rendered)
defer_transforms = false
tmux_session = "$editor"
vim.api.nvim_exec_autocmds("FocusGained", {})
vim.wait(150, function() return false end)
pending_img = assert(pending_entry.images[vim.api.nvim_get_current_win()])
check("image pending at focus loss returns without reconversion", pending_img.is_rendered and pending_entry.png == png)
check("explicit scale_factor composes with density normalization", pending_img.last_paint.width == 18
	and pending_img.last_paint.height == 3 and reservation_height(pending_buf, pending_entry) == 3)
term.cell_width, term.cell_height = 20, 40
vim.api.nvim_exec_autocmds("VimResized", {})
pending_img:render()
settle()
check("explicit scale_factor preserves same reference cells on Retina", pending_img.last_paint.width == 18
	and pending_img.last_paint.height == 3 and reservation_height(pending_buf, pending_entry) == 3)
term.cell_width, term.cell_height = 10, 20
vim.api.nvim_exec_autocmds("VimResized", {})
settle()
state.options.scale_factor = 1

-- fit_window=false must not revert to native 48-cell size at low density;
-- only explicit user scaling or image.nvim caps should change the cell size.
local uncapped_buf, _, uncapped_entry, uncapped_img = seed(
	{ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4, "below", false)
check("fit_window false retains normalized unfolded cells", uncapped_img.last_paint.width == 24
	and uncapped_img.last_paint.height == 4)
close_fold(uncapped_buf, uncapped_entry)
check("fit_window false retains normalized folded cells", uncapped_img.last_paint.width == 24
	and uncapped_img.last_paint.height == 4 and reservation_height(uncapped_buf, uncapped_entry) == 4)
term.cell_width, term.cell_height = 20, 40
vim.api.nvim_exec_autocmds("VimResized", {})
uncapped_img:render()
settle()
check("fit_window false preserves reference cells after density transition", uncapped_img.last_paint.width == 24
	and uncapped_img.last_paint.height == 4 and reservation_height(uncapped_buf, uncapped_entry) == 4)
term.cell_width, term.cell_height = 10, 20
vim.api.nvim_exec_autocmds("VimResized", {})
settle()

-- Ordinary outside-fold anchors retain native buffer/window clipping. Above
-- and below positions must keep source indentation and their reservation gap.
for _, position in ipairs({ "below", "above" }) do
	buf, win, entry, img = seed({ "    BEFORE", "    @math", "    x^2", "    @end", "    NEXT" }, 1, 3, 4, position)
	native_width, native_height = img.last_paint.width, img.last_paint.height
	close_fold(buf, entry)
	local summary_row = vim.fn.screenpos(win, 2, 1).row
	check(position .. " uses outside-fold native window/buffer anchor", img.window == win and img.buffer == buf
		and img.inline and not img.math_renderer_absolute and vim.fn.foldclosed(img.geometry.y + 1) == -1)
	check(position .. " retains indentation and unfolded size", img.last_paint.x == 4
		and img.last_paint.width == native_width and img.last_paint.height == native_height)
	check(position .. " retains reservation placement", entry.reservation_row == (position == "below" and 4 or 0)
		and reservation_height(buf, entry) == native_height)
	check(position .. " retains fold-relative image placement", img.last_paint.y == (position == "below" and summary_row or summary_row - native_height - 1))
	check(position .. " retains native window crop bounds", img.bounds.right == vim.api.nvim_win_get_width(win)
		and img.bounds.bottom < term.screen_rows)
	tmux_window = "@other"
	vim.api.nvim_exec_autocmds("FocusLost", {})
	settle()
	inactive_paints = paints
	img:render()
	check(position .. " native anchor respects tmux inactivity", not img.is_rendered and paints == inactive_paints)
	tmux_window = "@editor"
	vim.api.nvim_exec_autocmds("FocusGained", {})
	settle()
	check(position .. " native anchor returns with tmux focus", img.is_rendered)
	-- The module's existing delayed FocusGained redraw recreates objects.
	vim.wait(150, function() return false end)
	img = assert(entry.images[win])
	module.config.public.hide_on_fold = true
	refresh(buf)
	check(position .. " hide_on_fold removes image and reservation", not img.is_rendered and reservation_height(buf, entry) == 0)
	module.config.public.hide_on_fold = false
	refresh(buf)
	check(position .. " hide_on_fold false restores cached image", img.is_rendered and reservation_height(buf, entry) > 0)
	vim.cmd("normal! zE")
	vim.cmd("1,5fold")
	refresh(buf)
	check(position .. " outer fold always hides image and reservation", not img.is_rendered and reservation_height(buf, entry) == 0)
end

-- A real nowrap native anchor can lose its source column to horizontal
-- scrolling while part of the image remains visible. Resolve the vertical
-- position from visible text, but crop from the original scrolled origin.
term.cell_width, term.cell_height = 20, 40
vim.wo.wrap = false
for _, position in ipairs({ "below", "above" }) do
	local adjacent = "    " .. string.rep("TEXT", 40)
	buf, win, entry, img = seed({ adjacent, "    @math", "    x^2", "    @end", adjacent, "NEXT" }, 1, 3, 4, position, false)
	close_fold(buf, entry)
	local anchor_row = position == "below" and 5 or 1
	local full_y = img.last_paint.y
	local reservation_id = entry.reservation_id
	local horizontal_transforms = transforms
	check(position .. " horizontal regression starts with native anchor", img.is_rendered
		and not img.math_renderer_absolute and img.rendered_geometry.width == 24 and img.rendered_geometry.height == 4)
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 20, leftcol = 10 })
	refresh(buf)
	local info = vim.fn.getwininfo(win)[1]
	check(position .. " horizontal scroll naturally hides native anchor column", vim.fn.winsaveview().leftcol == 10
		and vim.fn.screenpos(win, anchor_row, 5).row == 0)
	check(position .. " horizontal partial crop retains true source origin", img.is_rendered and img.math_renderer_absolute
		and img.last_display.x == info.wincol - 1 + (info.textoff or 0)
		and img.last_display.y == full_y and img.last_display.payload.display_x == 120
		and img.last_display.payload.display_width == 360 and img.last_display.payload.display_height == 160)
	check(position .. " horizontal crop preserves dimensions and reservation", img.rendered_geometry.width == 24
		and img.rendered_geometry.height == 4 and entry.reservation_id == reservation_id
		and reservation_height(buf, entry) == 4 and entry.png == png)
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 30, leftcol = 16 })
	img:render()
	settle()
	check(position .. " horizontal callback refreshes crop", img.is_rendered
		and img.last_display.payload.display_x == 240 and img.last_display.payload.display_width == 240
		and img.last_display.y == full_y)
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 40, leftcol = 30 })
	img:render()
	settle()
	check(position .. " horizontal fully offscreen callback clears image", not img.is_rendered and entry.images[win] == img)
	refresh(buf)
	check(position .. " horizontal fully offscreen sweep stays cleared", not img.is_rendered)
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 20, leftcol = 10 })
	img:render()
	settle()
	check(position .. " horizontal callback return restores partial source", img.is_rendered
		and entry.images[win] == img and img.last_display.payload.display_x == 120
		and img.last_display.payload.display_width == 360)
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = 0 })
	refresh(buf)
	check(position .. " horizontal scroll return restores native binding and full source", img.is_rendered
		and entry.images[win] == img and img.window == win and img.buffer == buf and img.inline
		and not img.math_renderer_absolute and img.geometry.width == 24 and img.geometry.height == 4
		and img.last_display.x == info.wincol - 1 + (info.textoff or 0) + 4 and img.last_display.y == full_y
		and img.last_display.payload.display_x == 0 and img.last_display.payload.display_width == 480
		and img.last_display.payload.display_height == 160 and transforms == horizontal_transforms)
end
-- Legal short anchors have no visible character at leftcol=10. Keep a long
-- cursor line elsewhere so Neovim naturally retains horizontal scrolling.
-- A winbar and an unrelated virtual reservation exercise real vertical layout.
for _, position in ipairs({ "below", "above" }) do
	local short, long = "    A", "    " .. string.rep("TEXT", 40)
	buf, win, entry, img = seed({ "PRECEDING", short, "    @math", "    x^2", "    @end", short, long },
		2, 4, 4, position, false)
	vim.wo.winbar = "Layout regression"
	local extra_ns = vim.api.nvim_create_namespace("short-anchor-layout")
	vim.api.nvim_buf_set_extmark(buf, extra_ns, 0, 0, {
		virt_lines = { { { "", "" } }, { { "", "" } }, { { "", "" } } },
	})
	close_fold(buf, entry)
	local anchor_row = position == "below" and 6 or 2
	local full_y, reservation_id = img.last_paint.y, entry.reservation_id
	local horizontal_transforms = transforms
	check(position .. " short anchor starts native with full sizing", img.is_rendered
		and not img.math_renderer_absolute and img.rendered_geometry.width == 24
		and img.rendered_geometry.height == 4 and reservation_height(buf, entry) == 4)
	vim.api.nvim_win_set_cursor(win, { 7, 20 })
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 20, leftcol = 10 })
	refresh(buf)
	local info = vim.fn.getwininfo(win)[1]
	local view = vim.fn.winsaveview()
	check(position .. " short anchor naturally has no visible character", view.leftcol == 10
		and vim.fn.virtcol2col(win, anchor_row, 11) == 5 and vim.fn.screenpos(win, anchor_row, 5).row == 0)
	check(position .. " short anchor partial crop keeps vertical layout and source", img.is_rendered
		and img.math_renderer_absolute and img.last_paint.x == info.wincol - 1 + (info.textoff or 0) - 6
		and img.last_display.y == full_y and img.last_display.payload.display_x == 120
		and img.last_display.payload.display_width == 360 and img.last_display.payload.display_height == 160)
	img:render()
	settle()
	check(position .. " short anchor callback has no viewport side effects", img.is_rendered
		and img.last_display.y == full_y and vim.deep_equal(vim.fn.winsaveview(), view))
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 30, leftcol = 16 })
	img:render()
	settle()
	check(position .. " short anchor callback refreshes partial crop", img.is_rendered
		and img.last_display.y == full_y and img.last_display.payload.display_x == 240
		and img.last_display.payload.display_width == 240)
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 40, leftcol = 30 })
	img:render()
	settle()
	check(position .. " short anchor fully offscreen callback clears", not img.is_rendered and entry.images[win] == img)
	refresh(buf)
	check(position .. " short anchor fully offscreen sweep stays cleared", not img.is_rendered)
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 20, leftcol = 10 })
	img:render()
	settle()
	check(position .. " short anchor callback return reuses partial source", img.is_rendered
		and entry.images[win] == img and img.last_display.y == full_y
		and img.last_display.payload.display_x == 120 and img.last_display.payload.display_width == 360)
	check(position .. " short anchor clipping preserves sizing and reservation", img.rendered_geometry.width == 24
		and img.rendered_geometry.height == 4 and entry.reservation_id == reservation_id
		and reservation_height(buf, entry) == 4 and entry.png == png and transforms == horizontal_transforms)
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 0, leftcol = 0 })
	refresh(buf)
	check(position .. " short anchor return restores native full source", img.is_rendered and entry.images[win] == img
		and img.window == win and img.buffer == buf and img.inline and not img.math_renderer_absolute
		and img.geometry.width == 24 and img.geometry.height == 4 and img.last_display.y == full_y
		and img.last_display.payload.display_x == 0 and img.last_display.payload.display_width == 480
		and img.last_display.payload.display_height == 160 and entry.reservation_id == reservation_id
		and transforms == horizontal_transforms)
	vim.fn.winrestview({ topline = position == "below" and 6 or 3, topfill = 2,
		lnum = 7, col = 20, leftcol = 10 })
	refresh(buf)
	info = vim.fn.getwininfo(win)[1]
	local content_top = info.winrow - 1 + (info.winbar or 0)
	check(position .. " short anchor top crop excludes winbar", img.is_rendered
		and info.winbar == 1 and img.last_display.y == content_top
		and img.last_display.payload.display_y == 80 and img.last_display.payload.display_height == 80
		and img.last_display.payload.display_x == 120 and img.last_display.payload.display_width == 360)
	vim.wo.winbar = ""
	vim.fn.winrestview({ topline = position == "below" and 6 or 3, topfill = 2,
		lnum = 7, col = 20, leftcol = 10 })
	refresh(buf)
	check(position .. " short anchor combines horizontal crop with visible topfill", img.is_rendered
		and vim.fn.winsaveview().topfill == 2 and img.last_paint.y == -2
		and img.last_display.payload.display_x == 120 and img.last_display.payload.display_width == 360
		and img.last_display.payload.display_y == 80 and img.last_display.payload.display_height == 80
		and img.rendered_geometry.height == 4 and entry.reservation_id == reservation_id)
	vim.fn.winrestview({ topline = 1, lnum = 7, col = 0, leftcol = 0 })
	refresh(buf)
	check(position .. " short anchor vertical return restores full native source", img.is_rendered
		and not img.math_renderer_absolute and entry.images[win] == img
		and img.last_display.payload.display_x == 0 and img.last_display.payload.display_y == 0
		and img.last_display.payload.display_width == 480 and img.last_display.payload.display_height == 160
		and transforms == horizontal_transforms and entry.reservation_id == reservation_id)
end
vim.wo.wrap = true
term.cell_width, term.cell_height = 10, 20

buf, win, entry, img = seed({ "    " .. string.rep("BEFORE ", 30), "    @math", "    x^2", "    @end", "NEXT" }, 1, 3, 4, "above")
close_fold(buf, entry)
check("wrapped previous row cannot shift above-fold formula onto text", img.math_renderer_absolute
	and img.last_paint.y == vim.fn.screenpos(win, 2, 1).row - entry.reservation_rows - 1
	and img.last_paint.y > vim.fn.screenpos(win, 1, 5).row)

-- A native callback must retain the window that last drove the shared
-- reservation, even when the current split has a different fold state.
do
	buf, win, entry, img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "    AFTER", "NEXT" }, 1, 3, 4)
	local unfolded_win = win
	vim.cmd("vsplit")
	local folded_win = vim.api.nvim_get_current_win()
	close_fold(buf, entry)
	vim.api.nvim_set_current_win(unfolded_win)
	vim.cmd("normal! zR")
	refresh(buf)
	local folded_img = assert(entry.images[folded_win])
	check("split fold states diverge for reservation regression", vim.fn.foldclosed(2) == -1
		and vim.api.nvim_win_call(folded_win, function() return vim.fn.foldclosed(2) end) == 2)

	local function upvalue(fn, name)
		for i = 1, 100 do
			local key, value = debug.getupvalue(fn, i)
			if not key then break end
			if key == name then return value end
		end
	end
	local render = assert(upvalue(folded_img.render, "render_entry_image"))
	local update = assert(upvalue(render, "update_reservation"))
	update(buf, entry, folded_win)
	check("explicit folded split is persisted as reservation driver", entry.reservation_win == folded_win
		and entry.reservation_row == 4 and entry.reservation_above)
	folded_img:render()
	img:render()
	settle()
	local mark = vim.api.nvim_buf_get_extmark_by_id(buf, module.private.ns, entry.reservation_id, {})
	check("native callbacks preserve divergent-fold reservation driver", entry.reservation_win == folded_win
		and entry.reservation_row == 4 and entry.reservation_above and mark[1] == 4
		and folded_img.is_rendered and reservation_height(buf, entry) > 0)
	check("divergent-fold formula retains summary-relative placement", folded_img.last_paint.y == vim.fn.screenpos(folded_win, 2, 1).row
		and folded_img.last_paint.x == vim.fn.getwininfo(folded_win)[1].wincol - 1 + 4)

	local other_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(folded_win, other_buf)
	img:render()
	settle()
	check("buffer-mismatched reservation driver falls back to current split", entry.reservation_win == unfolded_win
		and entry.reservation_row == 3 and not entry.reservation_above)

	vim.api.nvim_win_set_buf(folded_win, buf)
	refresh(buf)
	update(buf, entry, folded_win)
	check("restored split can drive reservation again", entry.reservation_win == folded_win)
	vim.api.nvim_win_close(folded_win, true)
	img:render()
	settle()
	check("closed reservation driver falls back to a valid split", entry.reservation_win == unfolded_win
		and entry.reservation_row == 3 and not entry.reservation_above)

	img:clear()
	entry.images[unfolded_win] = nil
	update(buf, entry, folded_win)
	check("no eligible window clears reservation driver and extmark", entry.reservation_win == nil
		and entry.reservation_id == nil and entry.reservation_row == nil and entry.reservation_rows == 0)
	vim.api.nvim_buf_delete(other_buf, { force = true })
end

-- The following clipping checks exercise larger graphics payloads using an
-- explicit user scale; normalization must not impose a default size cap.
state.options.scale_factor = 2
-- Global image.nvim caps are part of native size parity too.
state.options.max_width = 20
buf, win, entry, img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4)
native_width, native_height = img.last_paint.width, img.last_paint.height
close_fold(buf, entry)
check("folded fallback respects native global caps", img.last_paint.width == 20
	and img.last_paint.width == native_width and img.last_paint.height == native_height
	and reservation_height(buf, entry) == native_height)
state.options.max_width = nil

buf, win, entry, img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4, "below", false)
vim.cmd("vsplit")
vim.api.nvim_win_set_width(win, 30)
vim.api.nvim_set_current_win(win)
refresh(buf)
native_width, native_height = img.last_paint.width, img.last_paint.height
close_fold(buf, entry)
check("fit_window false retains native folded/unfolded size", img.rendered_geometry.width == native_width
	and img.rendered_geometry.height == native_height and native_width == 48 and native_height == 8)
vim.cmd("only")
settle()

local scrolling_lines = {}
for i = 1, 80 do scrolling_lines[i] = "LINE " .. i end
scrolling_lines[9], scrolling_lines[10], scrolling_lines[11], scrolling_lines[12] = "    @math", "    x^2", "    @end", ""
buf, win, entry, img = seed(scrolling_lines, 8, 10, 4)
close_fold(buf, entry)
vim.api.nvim_win_set_cursor(win, { 70, 0 })
vim.cmd("normal! zt")
refresh(buf)
check("offscreen folded fallback clears old placement", not img.is_rendered and entry.images[win] == img)
vim.api.nvim_win_set_cursor(win, { 9, 0 })
vim.cmd("normal! zt")
refresh(buf)
check("scrolling back restores existing folded placement", img.is_rendered and entry.images[win] == img
	and img.last_paint.x == 4 and img.last_paint.y == vim.fn.screenpos(win, 9, 1).row)
vim.fn.winrestview({ topline = 12, topfill = 4, lnum = 12 })
refresh(buf)
check("partially scrolled reservation keeps fallback visible", img.is_rendered
	and img.last_display.payload.display_y > 0
	and img.last_display.payload.display_height < img.rendered_geometry.height * term.cell_height)
vim.api.nvim_win_set_cursor(win, { 9, 0 })
vim.cmd("normal! zt")
refresh(buf)
check("partial reservation scroll returns to full source", img.is_rendered
	and img.last_display.payload.display_y == 0
	and img.last_display.payload.display_height == img.rendered_geometry.height * term.cell_height)
vim.cmd("normal! zb")
refresh(buf)
local win_info = vim.fn.getwininfo(win)[1]
check("folded fallback stays above the statusline", img.is_rendered
	and img.last_paint.y + img.last_paint.height <= win_info.winrow + win_info.height - 1)
vim.cmd("split")
module.config.public.fit_window = false
img.max_width_window_percentage = 100000
img.max_height_window_percentage = 100000
vim.api.nvim_win_set_height(win, 5)
vim.api.nvim_set_current_win(win)
refresh(buf)
check("folded fallback crops instead of hiding at statusline", img.is_rendered
	and img.last_display.y + img.last_display.payload.display_height / term.cell_height
		<= vim.fn.getwininfo(win)[1].winrow + vim.fn.getwininfo(win)[1].height - 1)
check("bottom cropping retains full reservation and native dimensions", entry.reservation_rows >= img.rendered_geometry.height
	and img.rendered_geometry.height > img.last_display.payload.display_height / term.cell_height and entry.png == png)
local cropped_img = img
vim.api.nvim_win_set_height(win, 12)
vim.api.nvim_win_set_cursor(win, { 9, 0 })
vim.cmd("normal! zt")
refresh(buf)
check("resize restores full fallback image without recreation", entry.images[win] == cropped_img
	and img.last_display.payload.display_height == img.rendered_geometry.height * term.cell_height)
vim.cmd("only")
settle()

buf, win, entry, img = seed({ "    @math", "    x^2", "    @end" }, 0, 2, 4)
close_fold(buf, entry)
check("entire-buffer fold preserves cached formula", img.is_rendered and img.math_renderer_absolute
	and img.last_paint.x == 4 and img.last_paint.width == 48 and img.last_paint.height == 8)
check("entire-buffer fold has no invalid reservation anchor", entry.reservation_id == nil and img.buffer == buf)

-- Force source rectangles across every edge, including both vertical edges
-- at once. Use the guarded native callback with controlled screenpos only;
-- the real Kitty backend still constructs the final graphics payload.
local original_screenpos = vim.fn.screenpos
local forced_row = 1
vim.fn.screenpos = function(target, row, col)
	if target == win then return { row = forced_row, col = 5, endcol = 5, curscol = 5 } end
	return original_screenpos(target, row, col)
end
local function assert_display_inside(name)
	local info = vim.fn.getwininfo(win)[1]
	local display = img.last_display
	check(name, img.is_rendered and display.x >= info.wincol - 1
		and display.y >= info.winrow - 1
		and display.x + display.payload.display_width / term.cell_width <= info.wincol - 1 + info.width
		and display.y + display.payload.display_height / term.cell_height <= info.winrow + info.height - 1)
end
forced_row = -2
img:render()
settle()
assert_display_inside("entire-buffer fallback clips top via native callback")
check("top clipping selects original lower source pixels", img.last_display.payload.display_y == 2 * term.cell_height
	and img.last_display.payload.display_height == 6 * term.cell_height
	and img.rendered_geometry.height == 8)
forced_row = 1
img:render()
settle()
check("native callback restores uncropped source", img.last_display.payload.display_y == 0
	and img.last_display.payload.display_height == 8 * term.cell_height)
vim.cmd("vsplit")
vim.api.nvim_win_set_width(win, 20)
module.config.public.fit_window = false
img.max_width_window_percentage = 100000
img.max_height_window_percentage = 100000
img:render()
settle()
assert_display_inside("entire-buffer fallback clips right split edge")
check("horizontal crop retains original width and reservation", img.rendered_geometry.width == 48
	and entry.reservation_rows == 8 and img.last_display.payload.display_width == 16 * term.cell_width)
vim.api.nvim_win_call(win, function()
	local view = vim.fn.winsaveview()
	view.leftcol = 10
	vim.wo.wrap = false
	vim.fn.winrestview(view)
end)
img:render()
settle()
assert_display_inside("fallback clips simultaneous left and right edges")
check("left crop selects original source pixels without rescaling", img.last_display.payload.display_x == 6 * term.cell_width
	and img.last_display.payload.display_width == 20 * term.cell_width
	and img.rendered_geometry.width == 48)
vim.api.nvim_set_current_win(win)
vim.cmd("only")
vim.api.nvim_win_call(win, function()
	local view = vim.fn.winsaveview()
	view.leftcol = 0
	vim.fn.winrestview(view)
end)
vim.cmd("split")
vim.api.nvim_win_set_height(win, 3)
forced_row = vim.fn.getwininfo(win)[1].winrow - 3
img:render()
settle()
assert_display_inside("fallback clips simultaneous top and bottom edges")
check("two-edge crop preserves source offset and visible intersection", img.last_display.payload.display_y == 2 * term.cell_height
	and img.last_display.payload.display_height == 3 * term.cell_height)
forced_row = -20
img:render()
settle()
check("fully offscreen callback clears existing image", not img.is_rendered)
vim.api.nvim_set_current_win(win)
vim.cmd("only")
forced_row = vim.fn.getwininfo(win)[1].winrow
-- WinClosed intentionally triggers a delayed deep redraw. Finish it before
-- checking that an offscreen/return callback itself does not recreate images.
vim.wait(150, function() return false end)
img = assert(entry.images[win])
forced_row = -20
img:render()
settle()
forced_row = vim.fn.getwininfo(win)[1].winrow
img:render()
settle()
check("return restores original full image object and source", img.is_rendered and entry.images[win] == img
	and img.last_display.payload.display_width == 48 * term.cell_width
	and img.last_display.payload.display_height == 8 * term.cell_height and entry.png == png)
vim.fn.screenpos = original_screenpos

-- Equivalent native outside-fold anchors pass through the same Kitty crop
-- boundary, with no change to their buffer binding or render offset.
for _, position in ipairs({ "below", "above" }) do
	buf, win, entry, img = seed({ "    BEFORE", "    @math", "    x^2", "    @end", "    AFTER" }, 1, 3, 4, position, false)
	close_fold(buf, entry)
	check(position .. " clipping regression uses native anchor", not img.math_renderer_absolute)
	forced_row = position == "above" and 6 or -2
	vim.fn.screenpos = function(target, row, col)
		if target == win then return { row = forced_row, col = 5, endcol = 5, curscol = 5 } end
		return original_screenpos(target, row, col)
	end
	img:render()
	settle()
	assert_display_inside(position .. " native anchor clips top edge")
	check(position .. " native top clip keeps full geometry", img.rendered_geometry.height == 8
		and img.last_display.payload.display_y > 0)
	forced_row = position == "above" and 29 or 20
	img:render()
	settle()
	assert_display_inside(position .. " native anchor clips bottom edge")
	check(position .. " native bottom clip keeps reservation", entry.reservation_rows == 8
		and img.last_display.payload.display_height < 8 * term.cell_height)
	vim.fn.screenpos = original_screenpos
	img:render()
	settle()
	check(position .. " native callback restores source and binding", img.is_rendered and img.window == win
		and img.buffer == buf and img.last_display.payload.display_height == 8 * term.cell_height)
end

-- A bordered float's getwininfo rectangle describes content, not its border.
-- Entire-buffer folds must remain bounded even though the native image is
-- detached from the window for absolute placement.
buf, win, entry, img = seed({ "    @math", "    x^2", "    @end" }, 0, 2, 4, "below", false)
local float_win = vim.api.nvim_open_win(buf, true, {
	relative = "editor", row = 3, col = 10, width = 20, height = 3,
	border = "single", style = "minimal",
})
win = float_win
vim.wo.foldmethod = "manual"
close_fold(buf, entry)
img = assert(entry.images[win])
assert_display_inside("entire-buffer fallback excludes floating borders")
check("bordered float retains full source size", img.rendered_geometry.width == 48
	and img.rendered_geometry.height == 8)
vim.api.nvim_win_close(float_win, true)
settle()

-- Non-Kitty and unicode-placeholder backends are intentionally unchanged.
for _, unsupported in ipairs({ "sixel", "unicode-placeholders" }) do
	state.options.backend = unsupported == "sixel" and "sixel" or "kitty"
	state.options.kitty_method = unsupported == "unicode-placeholders" and unsupported or "normal"
	buf, win, entry, img = seed({ "    @math", "    x^2", "    @end" }, 0, 2, 4, "below", false)
	close_fold(buf, entry)
	vim.cmd("split")
	vim.api.nvim_win_set_height(win, 3)
	vim.api.nvim_set_current_win(win)
	refresh(buf)
	check(unsupported .. " retains fallback overflow guard", not img.is_rendered
		and not img.math_renderer_clip_backend)
	vim.cmd("only")
end
state.options.backend = "kitty"
state.options.kitty_method = "normal"
state.options.scale_factor = 1
-- TabEnter must clear folded graphics even when a fallback has no native
-- window binding. A delayed transform callback must not repaint a hidden tab.
for _, lines in ipairs({
	{ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" },
	{ "    @math", "    x^2", "    @end" },
}) do
	local whole_buffer = #lines == 3
	buf, win, entry, img = seed(lines, whole_buffer and 0 or 1, whole_buffer and 2 or 3, 4)
	close_fold(buf, entry)
	check("tab regression starts with visible folded fallback", img.is_rendered and img.math_renderer_absolute)
	local cached_png = entry.png
	if whole_buffer then
		state.options.scale_factor = 0.37
		img:clear(true)
		defer_transforms = true
		img:render()
		check("tab switch has a deferred native transform", #pending_transforms > 0)
	end
	vim.cmd("tabnew")
	settle()
	check("switching tabs clears folded fallback", not img.is_rendered and entry.images[win] == img)
	local hidden_paints = paints
	img:render()
	for _, complete in ipairs(pending_transforms) do complete() end
	pending_transforms = {}
	settle()
	check("native callback cannot repaint hidden-tab folded image", paints == hidden_paints and not img.is_rendered)
	defer_transforms = false
	vim.cmd("tabprevious")
	vim.wait(150, function() return false end)
	img = assert(entry.images[win])
	check("returning to tab restores folded image without conversion", img.is_rendered
		and entry.png == cached_png and conversions == 0)
	state.options.scale_factor = 1
	vim.cmd("tabonly")
end
buf, win, entry, img = seed({ "    @math", "    x^2", "    @end" }, 0, 2, 4)
close_fold(buf, entry)
local old_img = img
vim.cmd("bwipeout!")
check("unload clears folded fallback and per-buffer state", not old_img.is_rendered and module.private.blocks[buf] == nil)
local unloaded_paints = paints
old_img:render()
check("late native callback cannot revive unloaded block", paints == unloaded_paints)
check("all fold/resize/focus paths reuse the cached PNG", conversions == 0)
check("native processor and graphics paths were exercised", transforms > 0 and paints > 0 and clears > 0)

vim.fn.delete(png)
vim.fn.delete(state.tmp_dir, "rf")
if failed then vim.cmd("cquit 1") end
vim.cmd("qall!")
