--- Thin async wrapper around ripgrep.
---
--- Owns the two things every caller would otherwise get wrong: reassembling
--- lines that ripgrep split across stdout chunks, and stopping cleanly once a
--- caller has seen as many lines as it cares about.

local M = {}

local checked_executable = nil

--- Is `rg` on PATH? Cached, since this is hit on every picker open.
---@return boolean
function M.executable()
    if checked_executable == nil then
        checked_executable = vim.fn.executable("rg") == 1
    end
    return checked_executable
end

--- A stateful splitter that turns arbitrary stdout chunks into whole lines.
---
--- ripgrep's output is cut at buffer boundaries with no regard for newlines, so
--- a match routinely arrives as the tail of one chunk and the head of the next.
--- `feed` returns only complete lines and holds the remainder; `flush` returns a
--- trailing line that arrived without a newline.
---@return { feed: fun(chunk: string): string[], flush: fun(): string[] }
function M.line_splitter()
    local pending = ""

    local function strip_cr(line)
        -- Tolerate CRLF so files from a Windows checkout render cleanly.
        return line:sub(-1) == "\r" and line:sub(1, -2) or line
    end

    return {
        feed = function(chunk)
            pending = pending .. chunk
            local lines, start = {}, 1
            while true do
                local newline = pending:find("\n", start, true)
                if not newline then
                    break
                end
                table.insert(lines, strip_cr(pending:sub(start, newline - 1)))
                start = newline + 1
            end
            pending = pending:sub(start)
            return lines
        end,

        flush = function()
            if pending == "" then
                return {}
            end
            local last = strip_cr(pending)
            pending = ""
            return { last }
        end,
    }
end

---@class microscope.RgHandle
---@field kill fun(self: microscope.RgHandle)
---@field killed boolean

---@class microscope.RgOpts
---@field cwd string
---@field on_lines fun(lines: string[]) called on the main loop as output arrives
---@field on_exit fun(reason: "done"|"limit"|"killed", code: integer|nil)
---@field max_lines integer|nil stop and report "limit" once this many lines are emitted

--- Run ripgrep, streaming complete lines to `opts.on_lines`.
---
--- Callbacks are always delivered via `vim.schedule`, so they may touch buffers
--- and windows freely. A handle that has been killed never fires again.
---@param args string[]
---@param opts microscope.RgOpts
---@return microscope.RgHandle
function M.spawn(args, opts)
    -- `killed` means the *caller* abandoned this run, so its remaining output is
    -- worthless and must be dropped. Stopping at the result cap is different: the
    -- process ends but everything already read is still wanted.
    local handle = { killed = false }
    local splitter = M.line_splitter()
    local emitted = 0
    local finished = false
    local process

    local function stop_process()
        if process then
            pcall(function()
                process:kill("sigterm")
            end)
        end
    end

    --- Report completion exactly once, whatever ended the run.
    ---
    --- This always fires, including for a killed run: callers track outstanding
    --- processes and would otherwise wait forever for one that never reports.
    local function finish(reason, code)
        if finished then
            return
        end
        finished = true
        vim.schedule(function()
            opts.on_exit(reason, code)
        end)
    end

    local function emit(lines)
        vim.schedule(function()
            if not handle.killed then
                opts.on_lines(lines)
            end
        end)
    end

    function handle:kill()
        if self.killed then
            return
        end
        self.killed = true
        stop_process()
    end

    local function consume(chunk)
        if handle.killed or finished then
            return
        end

        local lines = splitter.feed(chunk)
        if #lines == 0 then
            return
        end

        if opts.max_lines and emitted + #lines > opts.max_lines then
            -- Keep only what fits under the cap, then stop reading.
            for _ = opts.max_lines - emitted + 1, #lines do
                table.remove(lines)
            end
            emitted = emitted + #lines
            if #lines > 0 then
                emit(lines)
            end
            stop_process()
            finish("limit")
            return
        end

        emitted = emitted + #lines
        emit(lines)
    end

    local ok, err = pcall(function()
        process = vim.system({ "rg", unpack(args) }, {
            cwd = opts.cwd,
            text = true,
            stdout = function(_, data)
                if data then
                    consume(data)
                end
            end,
            -- ripgrep writes permission errors and the like to stderr; they are
            -- noise for an interactive picker.
            stderr = false,
        }, function(result)
            -- Flush a final line that arrived without a trailing newline.
            if not handle.killed and not finished then
                local last = splitter.flush()
                if #last > 0 then
                    emit(last)
                end
            end
            finish(handle.killed and "killed" or "done", result.code)
        end)
    end)

    if not ok then
        vim.schedule(function()
            opts.on_exit("done", -1)
        end)
        vim.notify("microscope: failed to run rg: " .. tostring(err), vim.log.levels.ERROR)
    end

    return handle
end

--- Flags shared by `--files` and grep invocations.
---@param rg_opts table `config.options.rg`
---@return string[]
function M.common_args(rg_opts)
    local args = {}
    if rg_opts.hidden then
        table.insert(args, "--hidden")
        -- `.git` is never interesting and dwarfs most repos.
        vim.list_extend(args, { "--glob", "!.git/*" })
    end
    if rg_opts.no_ignore then
        table.insert(args, "--no-ignore")
    end
    vim.list_extend(args, rg_opts.extra_args or {})
    return args
end

return M
