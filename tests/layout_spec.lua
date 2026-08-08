local h = require("tests.harness")
local layout = require("microscope.ui.layout")
local config = require("microscope.config")

local test, eq, ok = h.test, h.eq, h.ok

local function compute(columns, lines, overrides)
    local merged = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), overrides or {})
    return layout.compute({ columns = columns, lines = lines, config = merged })
end

test("the box is centred in the editor", function()
    local l = compute(200, 60)
    local width = l.prompt.width
    eq(math.floor((200 - width) / 2), l.prompt.col)
    eq(l.prompt.col, l.results.col)
end)

test("results and preview together span the full width", function()
    local l = compute(200, 60)
    ok(l.preview, "expected a preview at this width")
    eq(l.prompt.width, l.results.width + l.preview.width)
    eq(l.results.col + l.results.width, l.preview.col)
end)

test("the prompt sits directly below the results row", function()
    local l = compute(200, 60)
    eq(l.results.row + l.results.height, l.prompt.row)
    eq(layout.PROMPT_OUTER_HEIGHT, l.prompt.height)
end)

test("results and preview share the top row's height", function()
    local l = compute(200, 60)
    eq(l.results.height, l.preview.height)
    eq(l.results.row, l.preview.row)
end)

test("usable result rows exclude the border", function()
    local l = compute(200, 60)
    eq(l.results.height - 2, l.results_height)
end)

test("the preview is dropped on a narrow editor", function()
    local l = compute(70, 40)
    eq(nil, l.preview)
    eq(l.prompt.width, l.results.width)
end)

test("the preview is dropped when disabled", function()
    local l = compute(200, 60, { preview = { enabled = false } })
    eq(nil, l.preview)
end)

test("a tiny editor still yields a usable box", function()
    local l = compute(30, 12)
    ok(l.results_height >= 1, "results height was " .. l.results_height)
    ok(l.prompt.width >= 1)
    ok(l.results.row >= 0 and l.prompt.col >= 0)
end)

test("fractional and absolute sizes both resolve", function()
    eq(100, compute(200, 60, { layout = { width = 0.5 } }).prompt.width)
    eq(120, compute(200, 60, { layout = { width = 120 } }).prompt.width)
end)

test("capping the result height keeps the prompt in place", function()
    local uncapped = compute(200, 60)
    local capped = compute(200, 60, { layout = { max_results_height = 8 } })
    eq(8, capped.results_height)
    eq(uncapped.prompt.row, capped.prompt.row)
end)

test("the box never overflows the editor", function()
    for _, size in ipairs({ { 200, 60 }, { 80, 24 }, { 40, 12 }, { 300, 100 } }) do
        local l = compute(size[1], size[2], {})
        ok(l.prompt.col + l.prompt.width <= size[1], "width overflow at " .. vim.inspect(size))
        ok(l.prompt.row + l.prompt.height <= size[2], "height overflow at " .. vim.inspect(size))
    end
end)

test("to_win_config insets by the border", function()
    local win = layout.to_win_config({ row = 5, col = 10, width = 40, height = 20 })
    eq(6, win.row)
    eq(11, win.col)
    eq(38, win.width)
    eq(18, win.height)
end)
