--- Backend detection and LaTeX-to-PNG conversion for neorg-math-renderer.
---
--- This file is intentionally free of any Neorg dependency so it can be
--- loaded and tested standalone (see test/smoke.lua). It only uses the
--- standard Neovim (0.10+) Lua API: vim.system, vim.uv, vim.fn.
---
--- Supported backends, in the preference order configured by the user:
---   ratex   -- erweixin/RaTeX `ratex-render` CLI (Rust, KaTeX-compatible).
---              Reads one formula per line from --input and writes
---              OUTDIR/0001.png (4-digit, 1-based). Display style by default;
---              inline requests use RaTeX's --inline mode.
---   tex2svg -- MathJax `tex2svg` CLI (e.g. mathjax-node-cli): formula passed
---              as an argument, SVG written to stdout. The SVG is then
---              rasterized with rsvg-convert, magick or convert.
---   latex   -- Traditional pipeline: `latex` + `dvipng`, mirroring neorg's
---              core.latex.renderer.

local M = {}

local uv = vim.uv or vim.loop

---@class neorg-math-renderer.BackendOpts
---@field cache_dir string persistent cache directory for PNG files
---@field ratex string|function executable name, or a full custom invocation
---@field tex2svg string|function executable name, or a full custom invocation
---@field latex string|function executable name, or a full custom invocation
---@field dpi number dvipng density for the latex backend
---@field foreground_hex string|nil foreground color as "#rrggbb" (nil = black)
---@field background_color string "transparent" or "#rrggbb"
---@field on_error fun(backend: string, msg: string)|nil error reporter hook

--- Default executable names for the built-in backend pipelines.
local DEFAULT_CMDS = {
	ratex = "ratex-render",
	tex2svg = "tex2svg",
	latex = "latex",
}

---@type neorg-math-renderer.BackendOpts
local opts = {
	cache_dir = vim.fn.stdpath("cache") .. "/nvim/neorg-math-renderer",
	ratex = DEFAULT_CMDS.ratex,
	tex2svg = DEFAULT_CMDS.tex2svg,
	latex = DEFAULT_CMDS.latex,
	dpi = 350,
	foreground_hex = nil,
	background_color = "transparent",
	on_error = nil,
}

--- Backends we know how to drive, in default preference order.
M.backends = { "ratex", "tex2svg", "latex" }

--- Cache-key fragments of a snippet currently being converted, so concurrent
--- requests for the same formula share one conversion job.
---@type table<string, function[]>
local inflight = {}

--- Apply user/backend configuration. Safe to call again (e.g. on colorscheme
--- change) -- the foreground color is part of the cache key, so cached images
--- are invalidated automatically.
---@param o neorg-math-renderer.BackendOpts
function M.setup(o)
	opts = vim.tbl_deep_extend("force", opts, o or {})
	vim.fn.mkdir(opts.cache_dir, "p")
end

---@return string hex color like "#rrggbb" (never nil)
function M.foreground_hex()
	return opts.foreground_hex or "#000000"
end

---@return string background color: "transparent" or a hex color
function M.background()
	return opts.background_color or "transparent"
end

---@return string tmp directory rooted inside the cache dir
function M.tmp_root()
	local dir = opts.cache_dir .. "/tmp"
	vim.fn.mkdir(dir, "p")
	return dir
end

--- Drop all temporary conversion artifacts. Persistent cached PNGs are kept.
function M.clear_tmp()
	vim.fn.delete(opts.cache_dir .. "/tmp", "rf")
end

--- Probe whether a backend is usable on this machine. Cheap (executable
--- checks only, no process spawns), so results are not memoized.
--- A function override is always considered usable: the user takes full
--- responsibility for that backend's invocation.
---@param name string "ratex" | "tex2svg" | "latex"
---@return boolean
function M.probe(name)
	local override = opts[name]
	if type(override) == "function" then
		return true
	end

	local cmd = type(override) == "string" and override or DEFAULT_CMDS[name]
	if name == "ratex" then
		return vim.fn.executable(cmd) == 1
	elseif name == "tex2svg" then
		if vim.fn.executable(cmd) ~= 1 then
			return false
		end
		-- tex2svg output needs an SVG rasterizer.
		return vim.fn.executable("rsvg-convert") == 1
			or vim.fn.executable("magick") == 1
			or vim.fn.executable("convert") == 1
	elseif name == "latex" then
		return vim.fn.executable(cmd) == 1 and vim.fn.executable("dvipng") == 1
	end
	return false
end

--- Resolve the first usable backend from a preference-ordered list.
---@param list string[] backend names in preference order (nil = default)
---@return string|nil
function M.resolve(list)
	for _, name in ipairs(list or M.backends) do
		if M.probe(name) then
			return name
		end
	end
	return nil
end

--- Report an error through the configured hook (if any).
local function report(backend, msg)
	if opts.on_error then
		opts.on_error(backend, msg)
	end
end

--- Run a command asynchronously and invoke `cb(exit_code, stdout, stderr)` on
--- the main loop. `vim.system` requires nvim 0.10+.
---@param cmd string[]
---@param o table|nil vim.system options (cwd, ...)
---@param cb fun(code: integer, stdout: string, stderr: string)
local function run(cmd, o, cb)
	vim.system(cmd, vim.tbl_extend("force", { text = true }, o or {}), function(res)
		vim.schedule(function()
			cb(res.code, res.stdout or "", res.stderr or "")
		end)
	end)
end

--- Write `lines` to a file inside a fresh per-job temp directory.
---@param key string unique-ish job key (used as the directory name)
---@return string dir
local function job_dir(key)
	local dir = M.tmp_root() .. "/" .. key
	vim.fn.mkdir(dir, "p")
	return dir
end

--------------------------------------------------------------------------------
-- ratex backend
--------------------------------------------------------------------------------

--- Split "#rrggbb" into 0-255 components.
---@param hex string
---@return integer r, integer g, integer b
local function hex_to_rgb(hex)
	hex = hex:gsub("^#", "")
	return tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
end

--- Convert a hex color to dvipng's normalized RGB syntax. Unlike ratex,
--- dvipng expects each RGB component in the 0..1 range, not 0..255.
local function dvipng_rgb_arg(hex)
	local r, g, b = hex_to_rgb(hex)
	return ("rgb %.6f %.6f %.6f"):format(r / 255, g / 255, b / 255)
end

--- Background argument for dvipng: keyword or normalized RGB.
local function dvipng_bg_arg()
	local bg = M.background()
	if bg == "transparent" then
		return "Transparent"
	end
	return dvipng_rgb_arg(bg)
end

--- Convert one snippet with the ratex-render CLI.
---@param snippet string
---@param key string unique cache key for this snippet (temp dir name)
---@param done fun(path: string|nil, err: string|nil)
--- Custom invocation for `backend`, or nil when configured with a plain
--- executable name (built-in pipeline).
---@param backend string
---@return fun(snippet: string, o: table, callback: fun(path: string|nil, err: string|nil))|nil
local function override_fn(backend)
	local v = opts[backend]
	if type(v) == "function" then
		return v
	end
	return nil
end

--- Executable name for a backend's built-in pipeline: the configured string
--- override, or the default command.
---@param backend string
---@return string
local function backend_cmd(backend)
	local v = opts[backend]
	return type(v) == "string" and v or DEFAULT_CMDS[backend]
end

local function strip_inline_delimiters(snippet)
	if snippet:sub(1, 1) == "$" and snippet:sub(-1) == "$" then
		return snippet:sub(2, -2)
	end
	return snippet
end

local function render_ratex(snippet, key, done, render_opts)
	-- ratex-render reads one formula per line; flatten the block source.
	local line = (snippet:gsub("%s*\n%s*", " "))
	if render_opts and render_opts.inline == true then
		line = strip_inline_delimiters(line)
	end
	local dir = job_dir(key .. "-ratex")
	local input = dir .. "/input.txt"
	vim.fn.writefile({ line }, input)

	local cmd = {
		backend_cmd("ratex"),
		"--input",
		input,
		"--output-dir",
		dir,
		"--color",
		M.foreground_hex(),
		"--background-color",
		M.background(),
	}
	if render_opts and render_opts.inline == true then
		table.insert(cmd, "--inline")
	end

	run(cmd, nil, function(code, _, stderr)
		if code ~= 0 then
			done(nil, ("ratex-render exited with %d: %s"):format(code, vim.trim(stderr or "")))
			return
		end
		local png = dir .. "/0001.png"
		if not uv.fs_stat(png) then
			done(nil, "ratex-render produced no PNG")
			return
		end
		done(png)
	end)
end

--------------------------------------------------------------------------------
-- tex2svg (MathJax) backend
--------------------------------------------------------------------------------

--- Pick an available SVG-to-PNG rasterizer, honoring the configured
--- background color ("transparent" keeps the alpha channel).
---@return fun(svg: string, png: string): string[]|nil builder of the command
local function svg_rasterizer()
	local bg = M.background()
	if vim.fn.executable("rsvg-convert") == 1 then
		return function(svg, png)
			if bg == "transparent" then
				return { "rsvg-convert", "-o", png, svg }
			end
			return { "rsvg-convert", "-b", bg, "-o", png, svg }
		end
	elseif vim.fn.executable("magick") == 1 then
		return function(svg, png)
			if bg == "transparent" then
				return { "magick", svg, png }
			end
			return { "magick", svg, "-background", bg, "-flatten", png }
		end
	elseif vim.fn.executable("convert") == 1 then
		return function(svg, png)
			if bg == "transparent" then
				return { "convert", svg, png }
			end
			return { "convert", svg, "-background", bg, "-flatten", png }
		end
	end
	return nil
end

--- Convert one snippet with the MathJax tex2svg CLI + a local rasterizer.
---@param snippet string
---@param key string unique cache key for this snippet (temp dir name)
---@param done fun(path: string|nil, err: string|nil)
local function render_tex2svg(snippet, key, done, render_opts)
	local rasterize = svg_rasterizer()
	if not rasterize then
		done(nil, "no SVG rasterizer found (need rsvg-convert, magick or convert)")
		return
	end

	local cmd = { backend_cmd("tex2svg") }
	local input = render_opts and render_opts.inline == true and strip_inline_delimiters(snippet) or snippet
	table.insert(cmd, input)

	run(cmd, nil, function(code, stdout, stderr)
		local svg = vim.trim(stdout or "")
		if code ~= 0 or svg == "" then
			done(nil, ("tex2svg failed (exit %d): %s"):format(code, vim.trim(stderr or "")))
			return
		end

		-- MathJax SVG output colors glyphs with `currentColor`; bake in the
		-- configured foreground color so rasterization picks it up.
		svg = svg:gsub("currentColor", M.foreground_hex())

		local dir = job_dir(key .. "-tex2svg")
		local svg_path = dir .. "/formula.svg"
		local png_path = dir .. "/formula.png"
		-- Same NUL-byte caveat: SVG text from process stdout contains newlines
		-- and must be split into a line list before writefile.
		vim.fn.writefile(vim.split(svg, "\n", { plain = true }), svg_path)

		run(rasterize(svg_path, png_path), nil, function(rc, _, rerr)
			if rc ~= 0 or not uv.fs_stat(png_path) then
				done(nil, ("SVG rasterization failed (exit %d): %s"):format(rc, vim.trim(rerr or "")))
				return
			end
			done(png_path)
		end)
	end)
end

--------------------------------------------------------------------------------
-- latex backend (traditional)
--------------------------------------------------------------------------------

--- Top-level math environments: must NOT be wrapped in display math
--- delimiters ("starred" variants included). Second-level environments
--- (matrices, cases, ...) live INSIDE math mode, so they must still be
--- wrapped. Lua patterns have no alternation, so classify by capturing the
--- environment name and looking it up in sets.
local TOPLEVEL_ENVS = {
	align = true, ["align*"] = true,
	alignat = true, ["alignat*"] = true,
	flalign = true, ["flalign*"] = true,
	gather = true, ["gather*"] = true,
	multline = true, ["multline*"] = true,
	eqnarray = true, ["eqnarray*"] = true,
}

local INNER_ENVS = {
	aligned = true,
	gathered = true,
	split = true,
	cases = true,
	dcases = true,
	matrix = true,
	bmatrix = true,
	Bmatrix = true,
	pmatrix = true,
	vmatrix = true,
	Vmatrix = true,
	array = true,
}

local function latex_lines(snippet)
	return vim.split(snippet, "\n", { plain = true })
end

---@param inline boolean|nil whether snippet already carries inline math delimiters
local function latex_body(snippet, inline)
	local lines = latex_lines(snippet)
	if inline then
		-- Inline snippets are normalized like core.latex.renderer and already
		-- contain their surrounding `$` delimiters. Wrapping them in `\\[` and
		-- `\\]` would nest math mode and make LaTeX reject the document.
		return lines
	end
	local env = snippet:match("\\begin{([%a%*]+)}")
	-- Top-level environments go straight into the document body.
	if env and TOPLEVEL_ENVS[env] then
		return lines
	end
	-- Second-level environments (matrices, cases, ...) still need math mode.
	if env and INNER_ENVS[env] then
		return vim.list_extend({ "\\[" }, vim.list_extend(lines, { "\\]" }))
	end
	-- Alignment-style content (a &= b \\ c &= d) is invalid inside plain
	-- display math; run it through unnumbered `align*` instead.
	if snippet:find("&", 1, true) or snippet:find("\\\\", 1, true) then
		return vim.list_extend({ "\\begin{align*}" }, vim.list_extend(lines, { "\\end{align*}" }))
	end
	-- Plain formula: wrap in display math. neorg's `@math` tag implies
	-- display style.
	return vim.list_extend({ "\\[" }, vim.list_extend(lines, { "\\]" }))
end

--- Convert one snippet with `latex` + `dvipng`, mirroring neorg's
--- core.latex.renderer pipeline.
---@param snippet string
---@param key string unique cache key for this snippet (temp dir name)
---@param done fun(path: string|nil, err: string|nil)
---@param render_opts table|nil conversion mode options
local function render_latex(snippet, key, done, render_opts)
	local dir = job_dir(key .. "-latex")
	local tex = dir .. "/math.tex"
	-- NOTE: the `standalone` class (v1.5a) is incompatible with the new
	-- display-math handling in the LaTeX 2025+ kernel (all display math
	-- fails with "Missing $ inserted"), so use article + pagestyle=empty;
	-- `dvipng -T tight` crops the page border away just as well.
	local document = {
		"\\documentclass{article}",
		"\\pagestyle{empty}",
		"\\usepackage{amsmath}",
		"\\usepackage{amssymb}",
		"\\usepackage{graphicx}",
		"\\begin{document}",
	}
	vim.list_extend(document, latex_body(snippet, render_opts and render_opts.inline == true))
	table.insert(document, "\\end{document}")
	vim.fn.writefile(document, tex)

		run({
			backend_cmd("latex"),
			"--interaction=nonstopmode",
			"--output-format=dvi",
			"math.tex",
		}, { cwd = dir }, function(code, _, stderr)
		local dvi = dir .. "/math.dvi"
		if code ~= 0 or not uv.fs_stat(dvi) then
			done(nil, ("latex exited with %d: %s"):format(code, vim.trim(stderr or "")))
			return
		end

		local png = dir .. "/math.png"
		run({
			"dvipng",
			"-D",
			tostring(opts.dpi),
			"-T",
			"tight",
			"-bg",
			dvipng_bg_arg(),
			"-fg",
			dvipng_rgb_arg(M.foreground_hex()),
			"-o",
			png,
			"math.dvi",
		}, { cwd = dir }, function(rc, _, rerr)
			if rc ~= 0 or not uv.fs_stat(png) then
				done(nil, ("dvipng exited with %d: %s"):format(rc, vim.trim(rerr or "")))
				return
			end
			done(png)
		end)
	end)
end

local converters = {
	ratex = render_ratex,
	tex2svg = render_tex2svg,
	latex = render_latex,
}

-- Bump when generated PNG semantics change. This invalidates old files
-- generated with the pre-normalized dvipng RGB arguments.
local CACHE_VERSION = "v3-inline-math"

--------------------------------------------------------------------------------
-- public conversion API with disk cache
--------------------------------------------------------------------------------

---@param snippet string
---@param backend string
---@param render_opts table|nil conversion mode options
---@return string cache key
local function cache_key(snippet, backend, render_opts)
	local mode = render_opts and render_opts.inline == true and "inline" or "block"
	return vim.fn.sha256(CACHE_VERSION .. "\0" .. backend .. "\0" .. mode .. "\0" .. M.foreground_hex() .. "\0" .. snippet)
end

---@param key string
---@return string
local function cache_path(key)
	return opts.cache_dir .. "/" .. key .. ".png"
end

--- Persistently cached PNG path for a snippet+backend, if already converted.
---@param snippet string
---@param backend string
---@param render_opts table|nil conversion mode options
---@return string|nil
function M.cached_path(snippet, backend, render_opts)
	local path = cache_path(cache_key(snippet, backend, render_opts))
	return uv.fs_stat(path) and path or nil
end

--- Convert `snippet` to PNG asynchronously with `backend`, serving hits from
--- the disk cache and coalescing concurrent requests for the same formula.
---
--- When the backend is configured as a function, the user takes over the
--- whole invocation: `fn(snippet, o, callback)` where `o` carries
--- `{ foreground_color, background_color, cache_dir, inline }`. The function must
--- eventually call `callback(png_path, nil)` -- or simply return a path
--- string synchronously. The produced PNG is moved into the cache either way.
---@param snippet string
---@param backend string
---@param callback fun(path: string|nil, err: string|nil)
---@param render_opts table|nil conversion mode options
function M.render(snippet, backend, callback, render_opts)
	local key = cache_key(snippet, backend, render_opts)
	local target = cache_path(key)

	if uv.fs_stat(target) then
		vim.schedule(function()
			callback(target)
		end)
		return
	end

	local pending = inflight[key]
	if pending then
		table.insert(pending, callback)
		return
	end
	inflight[key] = { callback }

	-- Idempotent completion: guards against a user function both returning a
	-- path and calling the callback.
	local finished = false
	local function handle(path, err)
		if finished then
			return
		end
		finished = true

		local callbacks = inflight[key] or {}
		inflight[key] = nil

		if not path then
			report(backend, err or "conversion failed")
			for _, cb in ipairs(callbacks) do
				cb(nil, err)
			end
			return
		end

		-- Move the fresh PNG into the persistent cache. Temp files live in a
		-- subdirectory of the cache dir, so the rename stays on one device.
		-- If the rename somehow fails, still deliver the temp path instead of
		-- failing the whole conversion.
		if not uv.fs_rename(path, target) then
			target = path
		end
		for _, cb in ipairs(callbacks) do
			cb(target)
		end
	end

	-- User-provided invocation takes precedence over the built-in pipeline.
	local override = override_fn(backend)
	if override then
		local ok, ret = pcall(override, snippet, {
			foreground_color = M.foreground_hex(),
			background_color = M.background(),
			cache_dir = opts.cache_dir,
			inline = render_opts and render_opts.inline == true or false,
		}, handle)
		if not ok then
			handle(nil, tostring(ret))
		elseif type(ret) == "string" then
			handle(ret)
		end
		return
	end

	local convert = converters[backend]
	if not convert then
		handle(nil, ("unknown backend: %s"):format(tostring(backend)))
		return
	end

	convert(snippet, key, handle, render_opts)
end

return M
