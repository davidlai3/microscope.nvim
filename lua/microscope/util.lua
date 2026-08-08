local M = {}

--- Wrap `fn` so rapid calls collapse into one, `ms` after the last of them.
---
--- The returned table is callable and also exposes `cancel` and `flush`, which
--- the picker needs when it closes or when the user hits Enter mid-debounce.
---@param ms integer
---@param fn fun()
---@return table
function M.debounce(ms, fn)
    local timer = vim.uv.new_timer()
    local pending = false

    local wrapper = {}

    function wrapper.cancel()
        pending = false
        if timer and not timer:is_closing() then
            timer:stop()
        end
    end

    function wrapper.flush()
        local was_pending = pending
        wrapper.cancel()
        if was_pending then
            fn()
        end
    end

    function wrapper.close()
        wrapper.cancel()
        if timer and not timer:is_closing() then
            timer:close()
        end
        timer = nil
    end

    return setmetatable(wrapper, {
        __call = function()
            if not timer then
                return
            end
            pending = true
            timer:stop()
            timer:start(
                ms,
                0,
                vim.schedule_wrap(function()
                    if pending then
                        pending = false
                        fn()
                    end
                end)
            )
        end,
    })
end

--- Wrap `fn` so it runs at most once per `ms`, however often it is called.
---
--- Unlike `debounce`, a continuous stream of calls still produces steady
--- output — which is what streaming search results need, since a debounce would
--- show nothing at all until ripgrep paused.
---@param ms integer
---@param fn fun()
---@return table
function M.throttle(ms, fn)
    local timer = vim.uv.new_timer()
    local scheduled = false

    local wrapper = {}

    function wrapper.cancel()
        scheduled = false
        if timer and not timer:is_closing() then
            timer:stop()
        end
    end

    function wrapper.close()
        wrapper.cancel()
        if timer and not timer:is_closing() then
            timer:close()
        end
        timer = nil
    end

    return setmetatable(wrapper, {
        __call = function()
            if scheduled or not timer then
                return
            end
            scheduled = true
            timer:start(
                ms,
                0,
                vim.schedule_wrap(function()
                    scheduled = false
                    fn()
                end)
            )
        end,
    })
end

--- Split a list of paths into groups small enough to pass as one argv.
---@param paths string[]
---@param budget integer bytes of argv to allow per group
---@return string[][]
function M.chunk_by_bytes(paths, budget)
    local chunks, current, size = {}, {}, 0
    for _, path in ipairs(paths) do
        -- +1 for the NUL separating arguments in the real argv.
        local cost = #path + 1
        if #current > 0 and size + cost > budget then
            table.insert(chunks, current)
            current, size = {}, 0
        end
        table.insert(current, path)
        size = size + cost
    end
    if #current > 0 then
        table.insert(chunks, current)
    end
    return chunks
end

return M
