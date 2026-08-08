local h = require("tests.harness")
local rg = require("microscope.rg")

local test, eq = h.test, h.eq

test("whole lines in one chunk come straight back", function()
    local splitter = rg.line_splitter()
    eq({ "a.lua:1:1:x", "b.lua:2:1:y" }, splitter.feed("a.lua:1:1:x\nb.lua:2:1:y\n"))
    eq({}, splitter.flush())
end)

test("a line split across two chunks is reassembled", function()
    local splitter = rg.line_splitter()
    eq({}, splitter.feed("lua/init.lua:12:5:local M"))
    eq({ "lua/init.lua:12:5:local M = {}" }, splitter.feed(" = {}\n"))
end)

test("a line split across many chunks is reassembled", function()
    local splitter = rg.line_splitter()
    for _, chunk in ipairs({ "a", "b", "c", "d" }) do
        eq({}, splitter.feed(chunk))
    end
    eq({ "abcde" }, splitter.feed("e\n"))
end)

test("a chunk boundary landing exactly on the newline is handled", function()
    local splitter = rg.line_splitter()
    eq({}, splitter.feed("first"))
    eq({ "first" }, splitter.feed("\n"))
    eq({ "second" }, splitter.feed("second\n"))
end)

test("a chunk holding several lines plus a partial keeps the remainder", function()
    local splitter = rg.line_splitter()
    eq({ "one", "two" }, splitter.feed("one\ntwo\nthr"))
    eq({ "three" }, splitter.feed("ee\n"))
end)

test("output with no trailing newline is recovered by flush", function()
    local splitter = rg.line_splitter()
    eq({ "a" }, splitter.feed("a\nb"))
    eq({ "b" }, splitter.flush())
    eq({}, splitter.flush(), "flush must not repeat itself")
end)

test("carriage returns are stripped", function()
    local splitter = rg.line_splitter()
    eq({ "a.lua:1:1:x" }, splitter.feed("a.lua:1:1:x\r\n"))
end)

test("empty lines are preserved", function()
    local splitter = rg.line_splitter()
    eq({ "a", "", "b" }, splitter.feed("a\n\nb\n"))
end)

test("an empty chunk yields nothing and loses nothing", function()
    local splitter = rg.line_splitter()
    eq({}, splitter.feed("par"))
    eq({}, splitter.feed(""))
    eq({ "partial" }, splitter.feed("tial\n"))
end)

test("common_args stays empty by default", function()
    eq({}, rg.common_args({ extra_args = {} }))
end)
