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

-- eliding long paths -----------------------------------------------------------

--- 28 bytes, 28 cells. At a budget of 20 it splits 9 / 10 around the ellipsis.
local LONG = "lua/microscope/ui/render.lua"

--- The path portion of a rendered grep row.
local function path_of(text)
    return text:match("^(.-):%d+ ")
end

local function match_span(spans)
    for _, span in ipairs(spans) do
        if span.group == "MicroscopeMatch" then
            return span
        end
    end
end

test("a path within its budget is left alone", function()
    eq("lua/init.lua", render.elide("lua/init.lua", 20))
end)

test("a long path is elided to exactly its budget", function()
    local elided = render.elide(LONG, 20)
    eq("lua/micro…render.lua", elided)
    eq(20, vim.fn.strdisplaywidth(elided))
end)

test("elision favours the tail, so the basename survives", function()
    eq("lua/mic…der.lua", render.elide(LONG, 15))
    eq("lua/m…r.lua", render.elide(LONG, 11))
end)

test("a budget with no room to spare is just the ellipsis", function()
    eq("…", render.elide(LONG, 1))
    eq("…", render.elide(LONG, 0))
end)

test("elision measures display cells and never cuts a character in half", function()
    -- The double-width chars mean 12 cells cannot all be used; the point is
    -- that the result stays within budget and stays valid UTF-8.
    eq("aaa/…bb.lua", render.elide("aaa/日本語/bb.lua", 12))
end)

test("format without a width elides nothing", function()
    eq(LONG, (render.format({ path = LONG }, "")))
    eq(LONG, (render.format({ path = LONG }, "", 0)))
end)

test("a file row is elided to the full width", function()
    eq("lua/micro…render.lua", (render.format({ path = LONG }, "", 20)))
end)

test("the dir and file spans tile the elided path", function()
    local text, spans = render.format({ path = LONG }, "", 20)
    eq({ from = 0, to = 4, group = "MicroscopeDir" }, spans[1])
    eq({ from = 4, to = #text, group = "MicroscopeFile" }, spans[2])
end)

test("fuzzy positions after the cut shift, and ones inside it are dropped", function()
    local _, spans = render.format({ path = LONG, positions = { 0, 12, 20 } }, "", 20)
    local matches = {}
    for _, span in ipairs(spans) do
        if span.group == "MicroscopeMatch" then
            table.insert(matches, { span.from, span.to })
        end
    end
    -- 0 is in the head and unmoved, 12 falls inside the ellipsis, 20 is the "n"
    -- of "render" and follows the tail to its new offset.
    eq({ { 0, 1 }, { 14, 15 } }, matches)
end)

test("a grep row shrinks the path to make room for the source text", function()
    local text = render.format({
        path = LONG,
        lnum = 120,
        col = 1,
        text = "local text, spans = M.format(...)",
    }, "", 46)
    eq("lua/microsc…/render.lua:120 local text, spans = M.format(...)", text)
end)

test("a grep row keeps half the width for the path", function()
    local text = render.format({
        path = LONG,
        lnum = 120,
        col = 1,
        text = ("x"):rep(200),
    }, "", 46)
    eq("lua/microsc…/render.lua", path_of(text))
    eq(23, vim.fn.strdisplaywidth(path_of(text)), "half of 46")
end)

test("a grep row gives the path more than half when the line is short", function()
    local text = render.format({ path = LONG, lnum = 1, col = 1, text = "x" }, "", 46)
    eq(LONG, path_of(text), "the whole path fits in what the line leaves over")
end)

test("a grep row never shrinks the path below its basename", function()
    local text = render.format({
        path = LONG,
        lnum = 120,
        col = 1,
        text = ("x"):rep(200),
    }, "", 20)
    eq("lua/m…r.lua", path_of(text), "the floor is the basename plus an ellipsis")
end)

test("the lnum and match spans follow the shortened path", function()
    local text, spans = render.format({
        path = LONG,
        lnum = 12,
        col = 7,
        text = "local x = 1",
    }, "x", 30)

    eq("lua/mic…der.lua", path_of(text))
    eq({ from = 17, to = 20, group = "MicroscopeLnum" }, spans[3])
    local match = match_span(spans)
    eq("x", text:sub(match.from + 1, match.to))
end)
