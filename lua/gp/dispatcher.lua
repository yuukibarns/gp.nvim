--------------------------------------------------------------------------------
-- Dispatcher handles the communication between the plugin and LLM providers.
--------------------------------------------------------------------------------

local logger = require("gp.logger")
local tasker = require("gp.tasker")
local vault = require("gp.vault")
local render = require("gp.render")
local helpers = require("gp.helper")

local default_config = require("gp.config")

local D = {
	config = {},
	providers = {},
	query_dir = vim.fn.stdpath("cache") .. "/gp/query",
}

---@param opts table #	user config
D.setup = function(opts)
	logger.debug("dispatcher setup started\n" .. vim.inspect(opts))

	D.config.curl_params = opts.curl_params or default_config.curl_params

	D.providers = vim.deepcopy(default_config.providers)
	opts.providers = opts.providers or {}
	for k, v in pairs(opts.providers) do
		D.providers[k] = D.providers[k] or {}
		D.providers[k].disable = false
		for pk, pv in pairs(v) do
			D.providers[k][pk] = pv
		end
		if next(v) == nil then
			D.providers[k].disable = true
		end
	end

	-- remove invalid providers
	for name, provider in pairs(D.providers) do
		if type(provider) ~= "table" or provider.disable then
			D.providers[name] = nil
		elseif not provider.endpoint then
			D.logger.warning("Provider " .. name .. " is missing endpoint")
			D.providers[name] = nil
		end
	end

	for name, provider in pairs(D.providers) do
		vault.add_secret(name, provider.secret)
		provider.secret = nil
	end

	D.query_dir = helpers.prepare_dir(D.query_dir, "query store")

	local files = vim.fn.glob(D.query_dir .. "/*.json", false, true)
	if #files > 200 then
		logger.debug("too many query files, truncating cache")
		table.sort(files, function(a, b)
			return a > b
		end)
		for i = 100, #files do
			helpers.delete_file(files[i])
		end
	end

	logger.debug("dispatcher setup finished\n" .. vim.inspect(D))
end

---@param messages table
---@param model string | table
---@param provider string | nil
D.prepare_payload = function(messages, model, provider)
	local payload = {
		stream = true,
		stream_options = { include_usage = true },
		messages = messages,
	}

	if type(model) == "string" then
		payload.model = model
	else
		payload.model = model.model
		payload.max_tokens = model.max_tokens
		payload.temperature = model.temperature
		payload.top_p = model.top_p
	end

	return payload
end

-- gpt query
---@param buf number | nil # buffer number
---@param provider string # provider name
---@param payload table # payload for api
---@param handler function # response handler
---@param on_exit function | nil # optional on_exit handler
---@param callback function | nil # optional callback handler
---@param is_reasoning boolean # whether model is reasoning model
local query = function(buf, provider, payload, handler, on_exit, callback, is_reasoning)
	-- make sure handler is a function
	if type(handler) ~= "function" then
		logger.error(
			string.format("query() expects a handler function, but got %s:\n%s", type(handler), vim.inspect(handler))
		)
		return
	end

	local qid = helpers.uuid()
	tasker.set_query(qid, {
		timestamp = os.time(),
		buf = buf,
		provider = provider,
		payload = payload,
		handler = handler,
		on_exit = on_exit,
		raw_response = "",
		response = "",
		first_line = -1,
		last_line = -1,
		ns_id = nil,
		ex_id = nil,
	})

	local out_reader = function()
		local buffer = ""

		---@param lines_chunk string
		local function process_lines(lines_chunk)
			local qt = tasker.get_query(qid)
			if not qt then
				return
			end

			local lines = vim.split(lines_chunk, "\n")
			local content = ""
			local reasoning_content = ""
			for _, line in ipairs(lines) do
				-- if line ~= "" and line ~= nil then
				-- 	qt.raw_response = qt.raw_response .. line .. "\n"
				-- end
				line = line:gsub("^data: ", "")

				if line:match("choices") and line:match("delta") and line:match("content") then
					line = vim.json.decode(line)
					-- if line.choices[1] and line.choices[1].delta and line.choices[1].delta.reasoning_content then
					-- 	reasoning_content = reasoning_content .. line.choices[1].delta.reasoning_content
					-- end
					if line.choices[1] and line.choices[1].delta and line.choices[1].delta.content then
						content = content .. line.choices[1].delta.content
					end
				else
					-- attempt to parse lines possibly containing usage or done
					local ok, decoded = pcall(vim.json.decode, line)
					if ok and decoded and decoded.usage then
						local usage = decoded.usage

						local PROMPT_COST_PER_1K = 0.01225
						local COMPLETION_COST_PER_1K = 0.098

						local prompt_tokens = usage.prompt_tokens or 0
						local completion_tokens = usage.completion_tokens or 0

						local prompt_cost = prompt_tokens * PROMPT_COST_PER_1K / 1000
						local completion_cost = completion_tokens * COMPLETION_COST_PER_1K / 1000
						local total_cost = prompt_cost + completion_cost

						local message = string.format(
							"Tokens usage: prompt=%d, completion=%d, total=%d, cost≈¥%.4f",
							prompt_tokens,
							completion_tokens,
							usage.total_tokens or (prompt_tokens + completion_tokens),
							total_cost
						)
						vim.schedule(function()
							vim.api.nvim_echo({ { message, "MoreMsg" } }, true, {})
						end)
					end
				end
			end

			if reasoning_content ~= "" and type(reasoning_content) == "string" then
				handler(qid, reasoning_content, true, false)
			end
			if content ~= "" and type(content) == "string" then
				if is_reasoning then
					handler(qid, "", true, true)
					handler(qid, "\n</details>\n</think>\n\n", false, true)
					is_reasoning = false
				end
				qt.response = qt.response .. content
				handler(qid, content, false, false)
			end
		end

		-- closure for uv.read_start(stdout, fn)
		return function(err, chunk)
			local qt = tasker.get_query(qid)
			if not qt then
				return
			end

			if err then
				logger.error(qt.provider .. " query stdout error: " .. vim.inspect(err))
			elseif chunk then
				-- add the incoming chunk to the buffer
				buffer = buffer .. chunk
				local last_newline_pos = buffer:find("\n[^\n]*$")
				if last_newline_pos then
					local complete_lines = buffer:sub(1, last_newline_pos - 1)
					-- save the rest of the buffer for the next chunk
					buffer = buffer:sub(last_newline_pos + 1)

					process_lines(complete_lines)
				end
				-- chunk is nil when EOF is reached
			else
				-- if there's remaining data in the buffer, process it
				if #buffer > 0 then
					process_lines(buffer)
				end

				if is_reasoning then
					handler(qid, "", true, true)
					handler(qid, "\n", false, true)
					handler(qid, "\n</details>\n</think>\n", false, true)
					is_reasoning = false
				else
					handler(qid, "", false, true)
				end

				if qt.response == "" then
					logger.error(qt.provider .. " response is empty: \n" .. vim.inspect(qt.raw_response))
				end

				-- optional on_exit handler
				if type(on_exit) == "function" then
					on_exit(qid)
					if qt.ns_id and qt.buf then
						vim.schedule(function()
							vim.api.nvim_buf_clear_namespace(qt.buf, qt.ns_id, 0, -1)
						end)
					end
				end

				-- optional callback handler
				if type(callback) == "function" then
					vim.schedule(function()
						callback(qt.response)
					end)
				end
			end
		end
	end

	---TODO: this could be moved to a separate function returning endpoint and headers
	local endpoint = D.providers[provider].endpoint
	local headers = {}

	local secret = provider
	if provider == "copilot" then
		secret = "copilot_bearer"
	end
	local bearer = vault.get_secret(secret)
	if not bearer then
		logger.warning(provider .. " bearer token is missing")
		return
	end

	if provider == "copilot" then
		headers = {
			"-H",
			"editor-version: vscode/1.85.1",
			"-H",
			"Authorization: Bearer " .. bearer,
		}
	elseif provider == "openai" then
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
			-- backwards compatibility
			"-H",
			"api-key: " .. bearer,
		}
	elseif provider == "googleai" then
		headers = {}
		endpoint = render.template_replace(endpoint, "{{secret}}", bearer)
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
		payload.model = nil
	elseif provider == "anthropic" then
		headers = {
			"-H",
			"x-api-key: " .. bearer,
			"-H",
			"anthropic-version: 2023-06-01",
			"-H",
			"anthropic-beta: messages-2023-12-15",
		}
	elseif provider == "azure" then
		headers = {
			"-H",
			"api-key: " .. bearer,
		}
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
	else -- default to openai compatible headers
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
		}
	end

	local temp_file = D.query_dir ..
					"/" .. logger.now() .. "." .. string.format("%x", math.random(0, 0xFFFFFF)) .. ".json"
	helpers.table_to_file(payload, temp_file)

	local curl_params = vim.deepcopy(D.config.curl_params or {})
	local args = {
		"--no-buffer",
		"-s",
		endpoint,
		"-H",
		"Content-Type: application/json",
		"-d",
		"@" .. temp_file,
	}

	for _, arg in ipairs(args) do
		table.insert(curl_params, arg)
	end

	for _, header in ipairs(headers) do
		table.insert(curl_params, header)
	end

	tasker.run(buf, "curl", curl_params, nil, out_reader(), nil)
end

-- gpt query
---@param buf number | nil # buffer number
---@param provider string # provider name
---@param payload table # payload for api
---@param handler function # response handler
---@param on_exit function | nil # optional on_exit handler
---@param callback function | nil # optional callback handler
---@param is_reasoning boolean # whether the model is reasoning model
D.query = function(buf, provider, payload, handler, on_exit, callback, is_reasoning)
	if provider == "copilot" then
		return vault.run_with_secret(provider, function()
			vault.refresh_copilot_bearer(function()
				query(buf, provider, payload, handler, on_exit, callback, is_reasoning)
			end)
		end)
	end
	vault.run_with_secret(provider, function()
		query(buf, provider, payload, handler, on_exit, callback, is_reasoning)
	end)
end

-- response handler
---@param buf number | nil # buffer to insert response into
---@param win number | nil # window to insert response into
---@param line number | nil # line to insert response into
---@param first_undojoin boolean | nil # whether to skip first undojoin
---@param prefix string | nil # prefix to insert before each response line
---@param cursor boolean # whether to move cursor to the end of the response
D.create_handler = function(buf, win, line, first_undojoin, prefix, cursor)
	buf = buf or vim.api.nvim_get_current_buf()
	prefix = prefix or ""
	local first_line = line or vim.api.nvim_win_get_cursor(win or 0)[1] - 1
	local finished_lines = 0
	local skip_first_undojoin = not first_undojoin

	local hl_handler_group = "GpHandlerStandout"
	vim.cmd("highlight default link " .. hl_handler_group .. " CursorLine")

	local ns_id = vim.api.nvim_create_namespace("GpHandler_" .. helpers.uuid())

	local ex_id = vim.api.nvim_buf_set_extmark(buf, ns_id, first_line, 0, {
		strict = false,
		right_gravity = false,
	})

	local response = {}
	return vim.schedule_wrap(function(qid, chunk, is_reasoning, stop)
		-- append new response
		table.insert(response, chunk)

		-- input control
		if #response < 100 and not stop then
			return
		end

		local qt = tasker.get_query(qid)
		if not qt then
			return
		end
		-- if buf is not valid, stop
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		-- undojoin takes previous change into account, so skip it for the first chunk
		if skip_first_undojoin then
			skip_first_undojoin = false
		else
			-- helpers.undojoin(buf)
		end

		if not qt.ns_id then
			qt.ns_id = ns_id
		end

		if not qt.ex_id then
			qt.ex_id = ex_id
		end

		first_line = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, ex_id, {})[1]

		-- clean previous response
		vim.api.nvim_buf_set_lines(buf, first_line + finished_lines, first_line + finished_lines + 1, false, {})

		-- helpers.undojoin(buf)

		-- prepend prefix to each line
		local lines = vim.split(table.concat(response), "\n")
		for i, l in ipairs(lines) do
			lines[i] = prefix .. l
		end

		-- prepend prefix > to each line inside CoT
		if is_reasoning then
			local new_lines = {}
			for _, l in ipairs(lines) do
				table.insert(new_lines, "> " .. l)
			end
			vim.api.nvim_buf_set_lines(buf, first_line + finished_lines, first_line + finished_lines, false, new_lines)
		else
			vim.api.nvim_buf_set_lines(buf, first_line + finished_lines, first_line + finished_lines, false, lines)
		end

		finished_lines = math.max(0, finished_lines + #lines - 1)
		response = { lines[#lines] }

		local end_line = first_line + finished_lines + 1
		qt.first_line = first_line
		qt.last_line = end_line - 1

		-- move cursor to the end of the response
		if cursor then
			helpers.cursor_to_line(end_line, buf, win)
		end
	end)
end

return D
