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
package.loaded["image/utils/term"] = { get_size = function() return term end }
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
state.backend = {
	features = { crop = true },
	render = function(img, x, y, width, height)
		paints = paints + 1
		state.images[img.id] = img
		img.is_rendered = true
		img.last_paint = { x = x, y = y, width = width, height = height }
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
check("changed cell geometry refreshes folded scaling", img.last_paint.width == 48 and img.last_paint.height == 8)
check("changed cell geometry refreshes reserved rows", entry.reservation_rows == 8 and reservation_height(buf, entry) == 8)
vim.cmd("normal! zR")
refresh(buf)
check("unfolding clears explicit fallback size and restores binding", img.window == win and img.buffer == buf
	and img.inline and img.geometry.width == nil and img.geometry.height == nil)
check("density-changed folded/unfolded sizes agree", img.last_paint.width == 48 and img.last_paint.height == 8)
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

-- Window caps can give the same PNG different heights in each split. The
-- shared reservation must equal their maximum, not the current image's height.
vim.cmd("vsplit")
local wider_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(win, 30)
vim.api.nvim_set_current_win(win)
refresh(buf)
vim.api.nvim_exec_autocmds("WinResized", {})
vim.cmd("redraw!")
local resize_ready = vim.wait(1000, function()
	local narrow = entry.images[win]
	local wider = entry.images[wider_win]
	return narrow and wider and narrow.is_rendered and wider.is_rendered
		and narrow.rendered_geometry.width == 30 and narrow.rendered_geometry.height == 5
		and wider.rendered_geometry.width == 48 and wider.rendered_geometry.height == 8
end)
check("window resize completes both split renders", resize_ready)
img = assert(entry.images[win])
local wider_img = assert(entry.images[wider_win])
check("folded fallback honors native fit_window caps", img.last_paint.width == 30 and img.last_paint.height == 5)
check("wider split retains its native image height", wider_img.last_paint.width == 48 and wider_img.last_paint.height == 8)
local max_height = math.max(img.last_paint.height, wider_img.last_paint.height)
check("window resize refreshes reservations", reservation_height(buf, entry) == max_height
	and entry.reservation_rows == max_height and max_height == 8)
check("window resize preserves chosen fold driver and outside anchor", entry.reservation_win == win
	and entry.reservation_row == 4 and entry.reservation_above)
local capped_width, capped_height = img.last_paint.width, img.last_paint.height
vim.cmd("normal! zR")
refresh(buf)
check("window-capped folded/unfolded sizes agree", img.last_paint.width == capped_width and img.last_paint.height == capped_height)
vim.cmd("only")
settle()

-- A pending native transform must not repaint on completion after focus loss.
local pending_buf, _, pending_entry, pending_img = seed({ "BEFORE", "    @math", "    x^2", "    @end", "", "NEXT" }, 1, 3, 4)
close_fold(pending_buf, pending_entry)
state.options.scale_factor = 0.61
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
check("native scale_factor applies to reservations and folded size", pending_img.last_paint.width == 24
	and pending_img.last_paint.height == 4 and reservation_height(pending_buf, pending_entry) == 4)
state.options.scale_factor = 1

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
check("fit_window false retains native folded/unfolded size", img.last_paint.width == native_width
	and img.last_paint.height == native_height and native_width == 48 and native_height == 8)
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
vim.cmd("normal! zb")
refresh(buf)
local win_info = vim.fn.getwininfo(win)[1]
check("folded fallback stays above the statusline", img.is_rendered
	and img.last_paint.y + img.last_paint.height <= win_info.winrow + win_info.height - 1)
vim.cmd("split")
vim.api.nvim_win_set_height(win, 5)
vim.api.nvim_set_current_win(win)
refresh(buf)
check("folded fallback hides when it cannot fit above statusline", not img.is_rendered)
vim.cmd("only")
settle()

buf, win, entry, img = seed({ "    @math", "    x^2", "    @end" }, 0, 2, 4)
close_fold(buf, entry)
check("entire-buffer fold preserves cached formula", img.is_rendered and img.math_renderer_absolute
	and img.last_paint.x == 4 and img.last_paint.width == 48 and img.last_paint.height == 8)
check("entire-buffer fold has no invalid reservation anchor", entry.reservation_id == nil and img.buffer == buf)
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
