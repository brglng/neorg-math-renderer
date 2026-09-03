--- Smoke test for the conversion backends, runnable without Neorg:
---
---   PATH="/Library/TeX/texbin:$PATH" nvim --headless -l test/smoke.lua
---
--- On this machine ratex/tex2svg are not installed and latex+dvipng are, so
--- the expected outcome is: ratex=false, tex2svg=false, latex=true and
--- successful block and inline conversions through the latex backend.

package.path = "lua/?.lua;" .. package.path

local backends = require("neorg.modules.external.math-renderer.backends")

local cache_dir = "/tmp/neorg-math-renderer-smoke"
vim.fn.delete(cache_dir, "rf")
backends.setup({ cache_dir = cache_dir, dpi = 350, foreground_hex = "#000000" })

local function check(name, cond)
	if cond then
		print(("PASS %s"):format(name))
	else
		print(("FAIL %s"):format(name))
		vim.defer_fn(function()
			vim.cmd("cquit 1")
		end, 0)
	end
end

print("--- probes ---")
print(("ratex   available: %s"):format(backends.probe("ratex")))
print(("tex2svg available: %s"):format(backends.probe("tex2svg")))
print(("latex   available: %s"):format(backends.probe("latex")))

local resolved = backends.resolve()
check("resolve picks an available backend", resolved ~= nil)
print(("resolved backend: %s"):format(tostring(resolved)))

if not resolved then
	vim.defer_fn(function()
		vim.cmd("cquit 1")
	end, 0)
	return
end

local snippet = "\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}"

print("--- rendering via backend: " .. resolved .. " ---")
local first_path, first_err = nil, nil
backends.render(snippet, resolved, function(path, err)
	first_path, first_err = path, err
end)

if not vim.wait(60000, function()
	return first_path ~= nil or first_err ~= nil
end) then
	print("FAIL render timed out")
	vim.defer_fn(function()
		vim.cmd("cquit 1")
	end, 0)
	return
end

check("render produced a PNG", first_path ~= nil)
if first_err then
	print(("backend error: %s"):format(first_err))
end

if first_path then
	local size = vim.fn.getfsize(first_path)
	check(("PNG is non-empty (%d bytes, path %s)"):format(size, first_path), type(size) == "number" and size > 0)

	-- Second call must be served from the persistent disk cache (same path,
	-- returned synchronously into a fresh callback).
	local second_path
	backends.render(snippet, resolved, function(path)
		second_path = path
	end)
	vim.wait(5000, function()
		return second_path ~= nil
	end)
	check("cache hit returns the same file", second_path == first_path)
end

-- The traditional backend needs inline `$...$` delimiters to enter math mode.
-- Keep this check conditional because alternate backends may use different
-- delimiter conventions while still supporting the module's inline path.
if resolved == "latex" then
	local inline_path, inline_err
	backends.render("$a^2 + b^2 = c^2$", resolved, function(path, err)
		inline_path, inline_err = path, err
	end, { inline = true })
	if not vim.wait(60000, function()
		return inline_path ~= nil or inline_err ~= nil
	end) then
		print("FAIL inline render timed out")
		vim.defer_fn(function()
			vim.cmd("cquit 1")
		end, 0)
		return
	end
	check("inline render produced a PNG", inline_path ~= nil)
	if inline_err then
		print(("inline backend error: %s"):format(inline_err))
	end
end

vim.fn.delete(cache_dir, "rf")
print("--- all checks done ---")
vim.defer_fn(function()
	vim.cmd("qa!")
end, 0)
