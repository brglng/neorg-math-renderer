--- Regression test for images left on screen after the buffer is unloaded
--- or deleted (`:bd`, `:bunload`, `:bwipeout`).
---
--- Folded math images are rendered detached (`image.window = nil`), so
--- image.nvim's own BufLeave/WinClosed cleanup never sees them, and no
--- BufLeave fires at all when the buffer is only displayed in a non-current
--- window. The module must clear every image and drop its per-buffer state on
--- BufUnload/BufWipeout.
---
---   nvim --headless -u NONE -l test/buffer_unload.lua
---
--- Loads the module with stubbed neorg.core / image.nvim / backends and
--- drives it through real `:bd` / `:bunload` / `:bwipeout` while a fake
--- image records clear() calls.

package.path = "lua/?.lua;" .. package.path

local check_failed = false
local function check(name, cond)
	if cond then
		print(("PASS %s"):format(name))
	else
		print(("FAIL %s"):format(name))
		check_failed = true
	end
end

-- --- stubs ---------------------------------------------------------------

package.loaded["neorg.core"] = {
	modules = {
		create = function(name)
			return {
				name = name,
				private = {},
				config = { public = {} },
				required = {},
				events = { subscribed = {} },
				public = {},
				setup = function()
					return { success = true, requires = {} }
				end,
				load = function() end,
			}
		end,
		await = function(_, callback)
			callback({ add_commands_from_table = function() end })
		end,
	},
}

package.loaded["neorg.modules.external.math-renderer.backends"] = {
	setup = function() end,
	resolve = function()
		return nil
	end,
	render = function() end,
}

package.loaded["image"] = { from_file = function() end }

local module = require("neorg.modules.external.math-renderer.module")
module.required["core.autocommands"] = { enable_autocommand = function() end }
module.load()

-- --- helpers ---------------------------------------------------------------

local function fake_image(tag)
	return {
		tag = tag,
		clear_count = 0,
		clear = function(self)
			self.clear_count = self.clear_count + 1
		end,
	}
end

--- Seed module state for the current buffer: one detached folded block image
--- (no window handle: the shape image.nvim's own cleanup cannot reach) plus
--- one inline image and a pending debounce timer.
local function seed_current_buffer()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local block_img = fake_image("block")
	local inline_img = fake_image("inline")

	module.private.blocks[buf] = {
		[0] = {
			math_row = 0,
			erow = 2,
			indent = 0,
			snippet = "x^2",
			has_content = true,
			png = "/tmp/fake-block.png",
			images = { [win] = block_img },
			shown = true,
			pending = false,
			reservation_id = nil,
		},
	}
	module.private.inlines[buf] = {
		["0:0:0:1"] = {
			range = { 0, 0, 0, 1 },
			key = "0:0:0:1",
			snippet = "$x$",
			png = "/tmp/fake-inline.png",
			box_png = "/tmp/fake-inline.png",
			box_geometry = { width_cells = 1, height_rows = 1 },
			extmark_ids = {},
			images = { [win] = inline_img },
			shown = true,
			pending = false,
		},
	}
	local timer_stopped = false
	module.private.timers[buf] = {
		stop = function()
			timer_stopped = true
		end,
		close = function() end,
	}

	return buf, block_img, inline_img, function()
		return timer_stopped
	end
end

local function assert_cleared(tag, buf, block_img, inline_img, timer_stopped)
	check(tag .. " clears detached folded block image", block_img.clear_count > 0)
	check(tag .. " clears inline image", inline_img.clear_count > 0)
	check(tag .. " drops block state", module.private.blocks[buf] == nil)
	check(tag .. " drops inline state", module.private.inlines[buf] == nil)
	check(tag .. " cancels the debounce timer", timer_stopped())
end

-- --- scenario 1: :bd of a buffer shown only in a NON-current window --------
-- No BufLeave fires for the deleted buffer, so only the BufUnload hook can
-- run; this is the exact failure mode where folded images stayed painted.

vim.cmd("enew")
vim.opt_local.ft = "norg"
local bd_buf = vim.api.nvim_get_current_buf()

vim.cmd("vsplit") -- split: current window keeps bd_buf
local bd_seed_buf, bd_block, bd_inline, bd_timer_stopped = seed_current_buffer()
assert(bd_seed_buf == bd_buf)
vim.cmd("wincmd l")
vim.cmd("enew") -- non-current window now shows another buffer
vim.opt_local.ft = "txt"

vim.cmd("bdelete " .. bd_buf)
assert_cleared(":bd non-current window", bd_buf, bd_block, bd_inline, bd_timer_stopped)

-- --- scenario 2: :bunload of a buffer needing cleanup ---------------------
-- Keep another loaded buffer alive so :bunload is allowed, then unload the
-- norg buffer from its own window.

vim.cmd("enew")
vim.opt_local.ft = "norg"
local bunload_buf, bunload_block, bunload_inline, bunload_timer_stopped =
	seed_current_buffer()

vim.cmd("vsplit")
vim.cmd("enew")
vim.opt_local.ft = "txt"
vim.cmd("wincmd h")

vim.cmd("bunload " .. bunload_buf)
assert_cleared(":bunload", bunload_buf, bunload_block, bunload_inline, bunload_timer_stopped)

-- --- scenario 3: :bwipeout of the current buffer ----------------------------
vim.cmd("enew")
vim.opt_local.ft = "norg"
local bwipe_buf, bwipe_block, bwipe_inline, bwipe_timer_stopped =
	seed_current_buffer()

vim.cmd("vsplit")
vim.cmd("enew")
vim.opt_local.ft = "txt"
vim.cmd("wincmd h")

vim.cmd("bwipeout " .. bwipe_buf)
assert_cleared(":bwipeout", bwipe_buf, bwipe_block, bwipe_inline, bwipe_timer_stopped)

if check_failed then
	vim.cmd("cquit 1")
end
vim.cmd("qall!")