--- Minimal test harness so the suite runs on a bare `nvim -l` with no plugins.

local M = {}

M.cases = {}
M.failures = {}

---@param name string
---@param fn fun()
function M.test(name, fn)
    table.insert(M.cases, { name = name, fn = fn })
end

local function describe(value)
    return vim.inspect(value, { newline = " ", indent = "" })
end

function M.eq(expected, actual, context)
    if not vim.deep_equal(expected, actual) then
        error(
            string.format(
                "%sexpected %s, got %s",
                context and (context .. ": ") or "",
                describe(expected),
                describe(actual)
            ),
            2
        )
    end
end

function M.ok(value, context)
    if not value then
        error((context or "expected a truthy value") .. ", got " .. describe(value), 2)
    end
end

function M.falsy(value, context)
    if value then
        error((context or "expected a falsy value") .. ", got " .. describe(value), 2)
    end
end

--- Run every registered case. Returns the number of failures.
---@return integer
function M.run()
    local passed = 0
    for _, case in ipairs(M.cases) do
        local ok, err = pcall(case.fn)
        if ok then
            passed = passed + 1
        else
            table.insert(M.failures, { name = case.name, err = err })
            io.write("FAIL  " .. case.name .. "\n      " .. tostring(err) .. "\n")
        end
    end
    io.write(string.format("\n%d passed, %d failed\n", passed, #M.failures))
    return #M.failures
end

return M
