--- Streaming text search via `rg --vimgrep`.
---
--- `--max-columns` is not optional. Without it a single minified file turns a
--- common query into gigabytes of output, because `--vimgrep` repeats the whole
--- matched line once per match on it. Capping columns took one real query on a
--- 5,761-file tree from 2.5 GB to 7 MB.
---
--- The caller chooses between two modes:
---
---   * `paths` given — search exactly those files. Exact, and immune to the
---     result cap, but it has to be re-run when the file set changes.
---   * `paths` omitted — search the whole directory. The caller buckets results
---     by path and filters in Lua, so narrowing the file set costs nothing.

local rg = require("microscope.rg")
local util = require("microscope.util")

local M = {}

--- Lines longer than this are reported by ripgrep as omitted rather than sent.
M.MAX_COLUMNS = 500

--- Parse one `--vimgrep` line: `path:lnum:col:text`.
---
--- The path is matched non-greedily so a filename containing a colon still
--- parses, as long as it is not followed by `digits:digits:`.
---@param line string
---@return microscope.Entry|nil
function M.parse(line)
    local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if not path or path == "" then
        return nil
    end
    return {
        path = path,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text,
    }
end

---@param pattern string
---@param rg_opts table
---@return string[]
function M.build_args(pattern, rg_opts)
    local args = {
        "--vimgrep",
        "--no-heading",
        "--with-filename", -- rg omits it when given exactly one path
        "--color=never",
        "--smart-case",
        "--max-columns=" .. M.MAX_COLUMNS,
    }
    vim.list_extend(args, rg.common_args(rg_opts))
    vim.list_extend(args, { "--regexp", pattern })
    return args
end

---@class microscope.GrepOpts
---@field cwd string
---@field pattern string
---@field rg_opts table
---@field paths string[]|nil restrict the search to these files
---@field max_results integer
---@field argv_chunk_bytes integer
---@field on_batch fun(entries: microscope.Entry[])
---@field on_done fun(reason: "done"|"limit"|"killed", exit_code: integer|nil)

--- Run a search. The returned handle kills every process it started.
---@param opts microscope.GrepOpts
---@return microscope.RgHandle
function M.search(opts)
    local base = M.build_args(opts.pattern, opts.rg_opts)

    -- With no paths, one process covers the whole directory. With paths, they
    -- are split into as many processes as argv limits require - almost always one.
    local batches = { {} }
    if opts.paths then
        batches = util.chunk_by_bytes(opts.paths, opts.argv_chunk_bytes)
        if #batches == 0 then
            vim.schedule(function()
                opts.on_done("done", 0)
            end)
            return { killed = false, kill = function() end }
        end
    end

    local handles = {}
    local outstanding = #batches
    local emitted = 0
    local finished = false
    local worst_code = 0

    local group = { killed = false }
    function group:kill()
        if self.killed then
            return
        end
        self.killed = true
        for _, handle in ipairs(handles) do
            handle:kill()
        end
    end

    local function batch_done(reason, code)
        if code and code > worst_code then
            worst_code = code
        end
        outstanding = outstanding - 1
        if outstanding > 0 or finished then
            return
        end
        finished = true
        if reason == "limit" or emitted >= opts.max_results then
            opts.on_done("limit", worst_code)
        else
            opts.on_done(group.killed and "killed" or "done", worst_code)
        end
    end

    for _, batch in ipairs(batches) do
        local args = vim.list_extend(vim.deepcopy(base), batch)
        table.insert(
            handles,
            rg.spawn(args, {
                cwd = opts.cwd,
                -- Each process gets the full budget; the group total is trimmed
                -- below, which is close enough and keeps them independent.
                max_lines = opts.max_results,
                on_lines = function(lines)
                    if group.killed or finished then
                        return
                    end
                    local entries = {}
                    for _, line in ipairs(lines) do
                        if emitted >= opts.max_results then
                            break
                        end
                        local entry = M.parse(line)
                        if entry then
                            table.insert(entries, entry)
                            emitted = emitted + 1
                        end
                    end
                    if #entries > 0 then
                        opts.on_batch(entries)
                    end
                    if emitted >= opts.max_results then
                        group:kill()
                    end
                end,
                on_exit = batch_done,
            })
        )
    end

    return group
end

return M
