--- Headless test entry point.
---
---     nvim -l tests/run.lua            # run everything
---     nvim -l tests/run.lua filter     # run one spec file
---
--- Run it from the repository root. Exits non-zero if anything failed.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local harness = require("tests.harness")

local only = ...
local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
    local name = vim.fn.fnamemodify(spec, ":t:r")
    if not only or name == only or name == only .. "_spec" then
        dofile(spec)
    end
end

os.exit(harness.run() == 0 and 0 or 1)
