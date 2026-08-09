local h = require("tests.harness")
local grep = require("microscope.source.grep")
local rg = require("microscope.rg")
local util = require("microscope.util")

local test, eq, ok = h.test, h.eq, h.ok

-- parsing --------------------------------------------------------------------

test("an output line parses into an entry", function()
    eq({
        path = "lua/microscope/init.lua",
        lnum = 12,
        col = 5,
        text = "local M = {}",
    }, grep.parse("lua/microscope/init.lua:12:5:local M = {}"))
end)

test("colons in the matched text are left alone", function()
    local entry = grep.parse("a.lua:3:1:vim.keymap.set('n', 'x', function() end)")
    eq("a.lua", entry.path)
    eq("vim.keymap.set('n', 'x', function() end)", entry.text)
end)

test("a path containing a colon still parses", function()
    local entry = grep.parse("weird:name.lua:7:2:hello")
    eq("weird:name.lua", entry.path)
    eq(7, entry.lnum)
    eq("hello", entry.text)
end)

test("an empty matched line parses", function()
    local entry = grep.parse("a.lua:1:1:")
    eq("", entry.text)
end)

test("non-match output is rejected", function()
    eq(nil, grep.parse(""))
    eq(nil, grep.parse("some warning text"))
    eq(nil, grep.parse(":1:1:no path"))
end)

-- arguments ------------------------------------------------------------------

test("the column cap is always present", function()
    local args = grep.build_args("foo", { extra_args = {} })
    ok(vim.tbl_contains(args, "--max-columns=" .. grep.MAX_COLUMNS))
    ok(vim.tbl_contains(args, "--smart-case"))
end)

test("the position flags are set without --vimgrep, so a line is reported once", function()
    local args = grep.build_args("foo", { extra_args = {} })
    ok(vim.tbl_contains(args, "--line-number"))
    ok(vim.tbl_contains(args, "--column"))
    h.falsy(
        vim.tbl_contains(args, "--vimgrep"),
        "--vimgrep repeats the line once per match on it, which is what we are avoiding"
    )
end)

test("the filename is forced on, since one path would otherwise omit it", function()
    ok(vim.tbl_contains(grep.build_args("foo", { extra_args = {} }), "--with-filename"))
end)

test("the pattern is passed as data, not as a flag", function()
    local args = grep.build_args("-v", { extra_args = {} })
    eq("--regexp", args[#args - 1])
    eq("-v", args[#args])
end)

test("hidden and no-ignore reach the argument list", function()
    local args = grep.build_args("foo", { hidden = true, no_ignore = true, extra_args = {} })
    ok(vim.tbl_contains(args, "--hidden"))
    ok(vim.tbl_contains(args, "--no-ignore"))
    ok(vim.tbl_contains(args, "!.git/*"), "hidden should still skip .git")
end)

test("extra_args are appended", function()
    ok(vim.tbl_contains(rg.common_args({ extra_args = { "--follow" } }), "--follow"))
end)

-- against real ripgrep --------------------------------------------------------

--- Write `files` into a fresh directory and return its path.
---@param files table<string, string>
---@return string
local function fixture(files)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for name, contents in pairs(files) do
        vim.fn.writefile(vim.split(contents, "\n"), dir .. "/" .. name)
    end
    return dir
end

--- Run a full search to completion and return everything it produced.
---@return microscope.Entry[]
local function search(dir, pattern)
    local entries, done = {}, false
    grep.search({
        cwd = dir,
        pattern = pattern,
        rg_opts = { extra_args = {} },
        max_results = 1000,
        argv_chunk_bytes = 100 * 1024,
        on_batch = function(batch)
            vim.list_extend(entries, batch)
        end,
        on_done = function()
            done = true
        end,
    })
    vim.wait(5000, function()
        return done
    end, 10)
    ok(done, "the search never finished")
    return entries
end

test("a line matching several times is reported once", function()
    local dir = fixture({
        ["a.lua"] = "local x = foo(foo, foo)\nnothing here\nfoo again\n",
    })
    local entries = search(dir, "foo")

    eq(2, #entries, "three matches on line 1 and one on line 3 should give two entries")
    eq({ 1, 3 }, { entries[1].lnum, entries[2].lnum })
    -- The surviving entry points at the first match on its line.
    eq(11, entries[1].col)
    eq("local x = foo(foo, foo)", entries[1].text)
end)

test("distinct lines and files are all kept", function()
    local dir = fixture({
        ["a.lua"] = "foo foo\nfoo\n",
        ["b.lua"] = "foo foo foo\n",
    })
    local entries = search(dir, "foo")

    local seen = {}
    for _, entry in ipairs(entries) do
        local key = entry.path .. ":" .. entry.lnum
        h.falsy(seen[key], "duplicate entry for " .. key)
        seen[key] = true
    end
    eq(3, #entries)
end)

-- argv chunking --------------------------------------------------------------

test("paths that fit stay in one chunk", function()
    local chunks = util.chunk_by_bytes({ "a.lua", "b.lua", "c.lua" }, 1000)
    eq(1, #chunks)
    eq(3, #chunks[1])
end)

test("paths are split once they exceed the budget", function()
    local paths = {}
    for i = 1, 100 do
        paths[i] = ("dir/file%03d.lua"):format(i)
    end
    local chunks = util.chunk_by_bytes(paths, 200)
    ok(#chunks > 1, "expected more than one chunk")

    local total, seen = 0, {}
    for _, chunk in ipairs(chunks) do
        local size = 0
        for _, path in ipairs(chunk) do
            size = size + #path + 1
            total = total + 1
            seen[path] = true
        end
        ok(size <= 200 or #chunk == 1, "chunk exceeded the byte budget")
    end
    eq(100, total)
    eq(100, vim.tbl_count(seen))
end)

test("a path longer than the budget still gets its own chunk", function()
    local chunks = util.chunk_by_bytes({ string.rep("x", 500) }, 100)
    eq(1, #chunks)
end)

test("an empty path list yields no chunks", function()
    eq({}, util.chunk_by_bytes({}, 100))
end)
