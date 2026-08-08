--- The candidate file list for a directory, via `rg --files`.
---
--- Results are cached per (cwd, ripgrep flags) so reopening the picker is
--- instant. The cache is only ever invalidated explicitly — a stale entry costs
--- you a file that was created since the last open, which `:MicroscopeRefresh`
--- fixes, and that is a better trade than re-walking a large repo on every open.

local rg = require("microscope.rg")

local M = {}

---@type table<string, string[]>
local cache = {}

---@param cwd string
---@param rg_opts table
---@return string
local function cache_key(cwd, rg_opts)
    return table.concat({
        cwd,
        tostring(rg_opts.hidden),
        tostring(rg_opts.no_ignore),
        table.concat(rg_opts.extra_args or {}, " "),
    }, "\0")
end

--- Drop cached file lists. With no argument, drops every directory's.
---@param cwd string|nil
function M.invalidate(cwd)
    if not cwd then
        cache = {}
        return
    end
    for key in pairs(cache) do
        if key:sub(1, #cwd + 1) == cwd .. "\0" then
            cache[key] = nil
        end
    end
end

--- Load the file list for `cwd`.
---
--- `on_update` is called with the accumulated list each time more paths arrive,
--- so the picker can paint before the walk finishes. `on_done` fires once.
---@param cwd string
---@param rg_opts table
---@param on_update fun(paths: string[])
---@param on_done fun(paths: string[])
---@return microscope.RgHandle|nil handle nil when the answer came from cache
function M.load(cwd, rg_opts, on_update, on_done)
    local key = cache_key(cwd, rg_opts)
    local cached = cache[key]
    if cached then
        vim.schedule(function()
            on_update(cached)
            on_done(cached)
        end)
        return nil
    end

    local paths = {}
    local args = { "--files" }
    vim.list_extend(args, rg.common_args(rg_opts))

    return rg.spawn(args, {
        cwd = cwd,
        on_lines = function(lines)
            vim.list_extend(paths, lines)
            on_update(paths)
        end,
        on_exit = function(reason)
            if reason == "done" then
                cache[key] = paths
            end
            on_done(paths)
        end,
    })
end

return M
