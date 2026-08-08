local h = require("tests.harness")
local render = require("microscope.ui.render")
local state_mod = require("microscope.state")

local test, eq = h.test, h.eq

local function with_entries(count, height)
    local s = state_mod.new("/tmp")
    s.height = height or 5
    local entries = {}
    for i = 1, count do
        entries[i] = { path = ("file%d.lua"):format(i) }
    end
    state_mod.set_entries(s, entries)
    return s
end

-- the inverted list -----------------------------------------------------------

test("the best match is drawn on the bottom row", function()
    local s = with_entries(5, 5)
    eq(4, render.row_for(s, 1), "0-based bottom row of a 5-row window")
    eq(0, render.row_for(s, 5), "the fifth match is the top row")
end)

test("entries scrolled out of view have no row", function()
    local s = with_entries(50, 5)
    eq(nil, render.row_for(s, 6))
    eq(nil, render.row_for(s, 99))
end)

test("row_for follows the scroll offset", function()
    local s = with_entries(50, 5)
    state_mod.move_selection(s, 9) -- selection 10, scroll 6
    eq(4, render.row_for(s, 6), "the lowest visible entry is the bottom row")
    eq(0, render.row_for(s, 10))
    eq(nil, render.row_for(s, 5))
end)

test("index_for inverts row_for", function()
    local s = with_entries(50, 5)
    state_mod.move_selection(s, 9)
    for index = s.scroll, s.scroll + s.height - 1 do
        eq(index, render.index_for(s, render.row_for(s, index)))
    end
end)

test("padding rows above a short list map to no entry", function()
    local s = with_entries(2, 5)
    -- Two entries in a five-row window occupy the bottom two rows only.
    eq(4, render.row_for(s, 1))
    eq(3, render.row_for(s, 2))
    eq(nil, render.index_for(s, 0))
    eq(nil, render.index_for(s, 2))
    eq(2, render.index_for(s, 3))
end)

-- entry formatting -------------------------------------------------------------

test("a file entry is drawn as its bare path", function()
    local text = render.format({ path = "lua/init.lua" }, "")
    eq("lua/init.lua", text)
end)

test("the directory and filename are coloured separately", function()
    local _, spans = render.format({ path = "lua/micro/init.lua" }, "")
    eq({ from = 0, to = 10, group = "MicroscopeDir" }, spans[1])
    eq({ from = 10, to = 18, group = "MicroscopeFile" }, spans[2])
end)

test("a path with no directory gets no dir span", function()
    local _, spans = render.format({ path = "init.lua" }, "")
    eq(1, #spans)
    eq("MicroscopeFile", spans[1].group)
end)

test("a grep entry shows path, line number and text", function()
    local text = render.format({
        path = "a.lua",
        lnum = 12,
        col = 7,
        text = "local x = 1",
    }, "")
    eq("a.lua:12 local x = 1", text)
end)

test("the grep match is highlighted at the reported column", function()
    local text, spans = render.format({
        path = "a.lua",
        lnum = 12,
        col = 7,
        text = "local x = 1",
    }, "x")

    local match
    for _, span in ipairs(spans) do
        if span.group == "MicroscopeMatch" then
            match = span
        end
    end
    eq("x", text:sub(match.from + 1, match.to))
end)

test("a case-insensitive match still highlights", function()
    local text, spans = render.format({
        path = "a.lua",
        lnum = 1,
        col = 1,
        text = "Setup()",
    }, "setup")

    local match
    for _, span in ipairs(spans) do
        if span.group == "MicroscopeMatch" then
            match = span
        end
    end
    eq("Setup", text:sub(match.from + 1, match.to))
end)

test("a regex query that is not literal is simply left unhighlighted", function()
    local _, spans = render.format({
        path = "a.lua",
        lnum = 1,
        col = 7,
        text = "local x = 1",
    }, "x.*=")

    for _, span in ipairs(spans) do
        eq(true, span.group ~= "MicroscopeMatch", "no match span was expected")
    end
end)

test("fuzzy path positions become match spans", function()
    local _, spans = render.format({ path = "init.lua", positions = { 0, 1 } }, "")
    local matches = {}
    for _, span in ipairs(spans) do
        if span.group == "MicroscopeMatch" then
            table.insert(matches, { span.from, span.to })
        end
    end
    eq({ { 0, 1 }, { 1, 2 } }, matches)
end)

test("an entry with no text does not error", function()
    eq("a.lua:3 ", render.format({ path = "a.lua", lnum = 3, col = 1 }, "q"))
end)
