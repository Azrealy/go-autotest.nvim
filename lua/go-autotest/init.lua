local M = {}
local api = vim.api
-- find line number of the first occurrence of a string in the buffer
local find_test_line = function(buf, str)
	local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if line:find(str) then
			return i
		end
	end
	return -1
end
local make_key = function(entry)
	assert(entry.Package, "Must have a Package:" .. vim.inspect(entry))
	assert(entry.Test, "Must have Test:" .. vim.inspect(entry))
	return string.format("%s/%s", entry.Package, entry.Test)
end

local add_golang_output = function(state, entry)
	assert(state.tests, vim.inspect(state))
	table.insert(state.tests[make_key(entry)].output, vim.trim(entry.Output))
end

local add_golang_test = function(state, entry)
	local line
	if not string.find(entry.Test, "/") then
		line = find_test_line(state.bufnr, "func " .. entry.Test)
	else
		local index = {}
		for i in string.gmatch(entry.Test, "[^/]+") do
			table.insert(index, i)
		end
		line = find_test_line(state.bufnr, '"' .. index[2])
	end
	state.tests[make_key(entry)] = { name = entry.Test, line = line, output = {} }
end

local mark_success = function(state, entry)
	state.tests[make_key(entry)].success = entry.Action == "pass"
end

local ns = api.nvim_create_namespace("live-tests")
local group = api.nvim_create_augroup("auto-test", { clear = true })

local function center(str)
	local width = api.nvim_win_get_width(0)
	local shift = math.floor(width / 2) - math.floor(string.len(str) / 2)
	return string.rep(" ", shift) .. str
end

local function open_window(output)
	local buf = api.nvim_create_buf(false, true)
	local border_buf = api.nvim_create_buf(false, true)

	api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(buf, "filetype", "whid")

	local width = api.nvim_get_option("columns")
	local height = api.nvim_get_option("lines")

	local win_height = math.ceil(height * 0.8 - 4)
	local win_width = math.ceil(width * 0.8)
	local row = math.ceil((height - win_height) / 2 - 1)
	local col = math.ceil((width - win_width) / 2)

	local border_opts = {
		style = "minimal",
		relative = "editor",
		width = win_width + 2,
		height = win_height + 2,
		row = row - 1,
		col = col - 1,
	}

	local opts = {
		style = "minimal",
		relative = "editor",
		width = win_width,
		height = win_height,
		row = row,
		col = col,
	}

	local border_lines = { "╔" .. string.rep("═", win_width) .. "╗" }
	local middle_line = "║" .. string.rep(" ", win_width) .. "║"
	for i = 1, win_height do
		table.insert(border_lines, middle_line)
	end
	table.insert(border_lines, "╚" .. string.rep("═", win_width) .. "╝")
	api.nvim_buf_set_lines(border_buf, 0, -1, false, border_lines)

	api.nvim_open_win(border_buf, true, border_opts)
	local win = api.nvim_open_win(buf, true, opts)
	api.nvim_command('au BufWipeout <buffer> exe "silent bwipeout! "' .. border_buf)

	api.nvim_win_set_option(win, "cursorline", true) -- it highlight line with the cursor on it

	-- we can add title already here, because first line will never change
	api.nvim_buf_set_lines(buf, 0, -1, false, { center("GO TEST OUTPUT"), "", "" })
	api.nvim_buf_add_highlight(buf, -1, "WhidHeader", 0, 0, -1)
	api.nvim_buf_set_lines(buf, 1, -1, false, output)
end
local function test_folder_path()
	local file = vim.api.nvim_buf_get_name(0)
	local path = ""
	for w in file:gmatch("(.-)/") do
		if vim.endswith(w, ".go") ~= true then
			path = path .. w .. "/"
		end
	end
	return path
end
local function go_test_job(command, state, bufnr)
	vim.fn.jobstart(command, {
		stdout_buffered = true,
		cwd = test_folder_path(),
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line == "" then
					break
				end
				local decoded = vim.json.decode(line)
				if decoded.Action == "run" then
					add_golang_test(state, decoded)
				elseif decoded.Action == "output" then
					if not decoded.Test then
						break
					end
					add_golang_output(state, decoded)
				elseif decoded.Action == "pass" or decoded.Action == "fail" then
					P(state)
					mark_success(state, decoded)
					local test = state.tests[make_key(decoded)]
					if test.success then
						local text = { "🎉🆗" }
						api.nvim_buf_set_extmark(bufnr, ns, test.line - 1, 0, { virt_text = { text } })
					end
				else
					-- Do nothing
				end
			end
		end,
		on_stderr = function(_, data)
			print(vim.inspect(data))
		end,
		on_exit = function()
			local failed = {}
			for _, test in pairs(state.tests) do
				if test.line then
					if not test.success then
						table.insert(failed, {
							bufnr = bufnr,
							lnum = test.line - 1,
							col = 0,
							severity = vim.diagnostic.severity.ERROR,
							source = "go-test",
							message = "Test Failed",
							user_data = {},
						})
					end
				end
			end
			vim.diagnostic.set(ns, bufnr, failed, {})
		end,
	})
end
-- local function folder_name()
-- 	local file = vim.api.nvim_buf_get_name(0)
-- 	local path = {}
-- 	for w in file:gmatch("(.-)/") do
-- 		table.insert(path, w)
-- 	end
-- 	return path[#path]
-- end
M.attach_to_buffer = function(bufnr)
	local command = { "go", "test", "./...", "-v", "--json" }
	local state = { bufnr = bufnr, tests = {} }
	api.nvim_buf_create_user_command(bufnr, "GoTestLineDiag", function()
		local line = vim.fn.line(".") - 1
		for _, test in pairs(state.tests) do
			if test.line - 1 == line then
				open_window(test.output)
			end
		end
	end, {})
	go_test_job(command, state, bufnr)
	api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*.go",
		callback = function()
			api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			state = { bufnr = bufnr, tests = {} }
			go_test_job(command, state, bufnr)
		end,
	})
end

return M
