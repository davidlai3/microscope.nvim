local h = require("tests.harness")
local filter = require("microscope.filter")

local test, eq, ok, falsy = h.test, h.eq, h.ok, h.falsy

local PATHS = {
    "init.lua",
    "lua/microscope/init.lua",
    "lua/microscope/filter.lua",
    "lua/microscope/ui/render.lua",
    "lua/microscope/source/files.lua",
    "tests/filter_spec.lua",
    "README.md",
    "doc/microscope.txt",
    "src/deep/nested/thing.ts",
}

-- is_glob --------------------------------------------------------------------

test("is_glob detects glob syntax", function()
    ok(filter.is_glob("*.lua"))
    ok(filter.is_glob("!tests/*"))
    ok(filter.is_glob("src/**/*.ts"))
    ok(filter.is_glob("file?.lua"))
    ok(filter.is_glob("{a,b}.lua"))
    ok(filter.is_glob("[abc].lua"))
end)

test("is_glob treats plain text as fuzzy", function()
    falsy(filter.is_glob("filter"))
    falsy(filter.is_glob("lua/micro"))
    falsy(filter.is_glob(""))
end)

-- globs ----------------------------------------------------------------------

local function glob_matches(query, paths)
    local matches = filter.compile_glob(query)
    local out = {}
    for _, path in ipairs(paths or PATHS) do
        if matches(path) then
            table.insert(out, path)
        end
    end
    return out
end

test("a glob without a slash matches at any depth", function()
    eq({
        "init.lua",
        "lua/microscope/init.lua",
        "lua/microscope/filter.lua",
        "lua/microscope/ui/render.lua",
        "lua/microscope/source/files.lua",
        "tests/filter_spec.lua",
    }, glob_matches("*.lua"))
end)

test("star does not cross a slash", function()
    eq({ "init.lua" }, glob_matches("/*.lua"))
    eq({ "doc/microscope.txt" }, glob_matches("doc/*.txt"))
end)

test("double star crosses slashes", function()
    eq({ "src/deep/nested/thing.ts" }, glob_matches("src/**/*.ts"))
end)

test("double star also matches zero directories", function()
    eq({ "lua/microscope/init.lua" }, glob_matches("lua/**/init.lua", {
        "lua/microscope/init.lua",
        "lua/other.lua",
    }))
    eq({ "lua/init.lua" }, glob_matches("lua/**/init.lua", { "lua/init.lua", "other/init.lua" }))
end)

test("a trailing slash matches everything under a directory", function()
    eq({
        "lua/microscope/init.lua",
        "lua/microscope/filter.lua",
        "lua/microscope/ui/render.lua",
        "lua/microscope/source/files.lua",
    }, glob_matches("lua/"))
end)

test("negated globs subtract from the match set", function()
    eq({
        "init.lua",
        "lua/microscope/init.lua",
        "lua/microscope/filter.lua",
        "lua/microscope/ui/render.lua",
        "lua/microscope/source/files.lua",
    }, glob_matches("*.lua !tests/*"))
end)

test("a lone negated glob keeps everything else", function()
    eq({ "README.md" }, glob_matches("!*.lua !*.ts !*.txt"))
end)

test("brace alternation matches either branch", function()
    eq({ "README.md", "doc/microscope.txt" }, glob_matches("*.{md,txt}"))
end)

test("question mark matches exactly one non-slash character", function()
    eq({ "ab.lua" }, glob_matches("a?.lua", { "ab.lua", "abc.lua", "a/b.lua" }))
end)

test("regex metacharacters in a glob are literal", function()
    eq({ "a.b.lua" }, glob_matches("a.b.*", { "a.b.lua", "axbylua" }))
end)

test("a malformed glob does not raise", function()
    local matches = filter.compile_glob("[unclosed")
    falsy(matches("unclosed"))
end)

-- fuzzy ----------------------------------------------------------------------

test("an empty query returns every path untouched", function()
    local result = filter.filter(PATHS, "")
    eq("all", result.kind)
    eq(PATHS, result.paths)
end)

test("fuzzy matching finds subsequences", function()
    local result = filter.filter(PATHS, "microfilter")
    eq("fuzzy", result.kind)
    eq("lua/microscope/filter.lua", result.paths[1])
end)

test("fuzzy positions are byte offsets into the path", function()
    local result = filter.filter({ "lua/init.lua" }, "init")
    local path, positions = result.paths[1], result.positions[1]
    eq(4, #positions)
    local matched = {}
    for _, offset in ipairs(positions) do
        table.insert(matched, path:sub(offset + 1, offset + 1))
    end
    eq({ "i", "n", "i", "t" }, matched)
end)

test("fuzzy positions survive multibyte paths", function()
    local result = filter.filter({ "café/init.lua" }, "init")
    local path, positions = result.paths[1], result.positions[1]
    local matched = {}
    for _, offset in ipairs(positions) do
        table.insert(matched, path:sub(offset + 1, offset + 1))
    end
    eq({ "i", "n", "i", "t" }, matched)
end)

test("a query matching nothing returns an empty list", function()
    eq({}, filter.filter(PATHS, "zzzzqqqq").paths)
end)

-- incremental narrowing ------------------------------------------------------

test("an extended query narrows the previous result set", function()
    local cache = {}
    local first = filter.filter(PATHS, "lua/m", cache)
    eq(first.paths, cache.paths)

    -- Poison the cache so a wrong answer is detectable: if narrowing is used,
    -- only this one path can come back.
    cache.paths = { "lua/microscope/filter.lua" }
    local second = filter.filter(PATHS, "lua/mic", cache)
    eq({ "lua/microscope/filter.lua" }, second.paths)
end)

test("a shortened query re-searches the full list", function()
    local cache = {}
    filter.filter(PATHS, "lua/mic", cache)
    cache.paths = { "lua/microscope/filter.lua" }
    local result = filter.filter(PATHS, "lua", cache)
    ok(#result.paths > 1, "expected the full list to be searched again")
end)

test("crossing from fuzzy to glob re-searches the full list", function()
    local cache = {}
    filter.filter(PATHS, "filter", cache)
    cache.paths = { "lua/microscope/filter.lua" }
    local result = filter.filter(PATHS, "filter*", cache)
    eq({ "lua/microscope/filter.lua", "tests/filter_spec.lua" }, result.paths)
end)

test("narrowing is sound for globs too", function()
    local cache = {}
    local broad = filter.filter(PATHS, "*.lua", cache)
    local narrow = filter.filter(PATHS, "*.lua !tests/*", cache)
    ok(#narrow.paths < #broad.paths)
    for _, path in ipairs(narrow.paths) do
        falsy(path:match("^tests/"), path .. " should have been excluded")
    end
end)

-- to_set ---------------------------------------------------------------------

test("to_set builds a membership table", function()
    local set = filter.to_set({ "a.lua", "b.lua" })
    ok(set["a.lua"])
    falsy(set["c.lua"])
end)
