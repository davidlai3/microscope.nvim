local h = require("tests.harness")
local state = require("microscope.state")

local test, eq = h.test, h.eq

local function with_entries(count, height)
    local s = state.new("/tmp")
    s.height = height or 5
    local entries = {}
    for i = 1, count do
        entries[i] = { path = ("file%d.lua"):format(i) }
    end
    state.set_entries(s, entries)
    return s
end

-- cursor ---------------------------------------------------------------------

--- Where the cursor is, as one comparable value per stop.
local function position(s)
    return s.focus == "list" and ("list:" .. s.selection) or s.focus
end

--- Walk `count` stops in `direction`, collecting every position along the way.
local function walk(s, direction, count)
    local seen = { position(s) }
    for _ = 1, count do
        state.move_cursor(s, direction)
        table.insert(seen, position(s))
    end
    return seen
end

test("focus starts on the files prompt", function()
    eq("files", state.new("/tmp").focus)
end)

test("moving up walks the prompt rows then every entry, then wraps", function()
    local s = with_entries(3)
    s.focus = "files"
    eq({
        "files",
        "grep",
        "list:1",
        "list:2",
        "list:3",
        "files",
    }, walk(s, 1, 5))
end)

test("moving down reverses that walk", function()
    local s = with_entries(3)
    s.focus = "files"
    eq({
        "files",
        "list:3",
        "list:2",
        "list:1",
        "grep",
        "files",
    }, walk(s, -1, 5))
end)

test("entering the list from the grep row lands on the best match", function()
    local s = with_entries(10)
    s.focus = "grep"
    state.move_cursor(s, 1)
    eq("list", s.focus)
    eq(1, s.selection)
end)

test("moving down off the best match returns to the grep row", function()
    local s = with_entries(10)
    s.focus, s.selection = "list", 1
    state.move_cursor(s, -1)
    eq("grep", s.focus)
end)

test("the selection carried into the list stays visible", function()
    local s = with_entries(20, 5)
    s.focus = "files"
    -- Down from the files row wraps to the far end: entry 20, off screen.
    state.move_cursor(s, -1)
    eq(20, s.selection)
    eq(16, s.scroll)
end)

test("with no entries the ring is just the two prompt rows", function()
    local s = state.new("/tmp")
    eq({ "files", "grep", "files", "grep" }, walk(s, 1, 3))
end)

test("a stale list focus escapes on the first move", function()
    local s = state.new("/tmp")
    s.focus = "list"
    state.move_cursor(s, 1)
    h.ok(s.focus ~= "list")
end)

-- mode -----------------------------------------------------------------------

test("mode follows the grep query, not the files query", function()
    local s = state.new("/tmp")
    eq("files", state.mode(s))
    s.queries.files = "*.lua"
    eq("files", state.mode(s))
    s.queries.grep = "setup"
    eq("grep", state.mode(s))
end)

-- selection ------------------------------------------------------------------

test("selection clamps at both ends instead of wrapping", function()
    local s = with_entries(3)
    state.move_selection(s, -1)
    eq(1, s.selection)
    state.move_selection(s, 10)
    eq(3, s.selection)
end)

test("selection is safe with no entries", function()
    local s = with_entries(0)
    state.move_selection(s, 1)
    eq(1, s.selection)
    eq(nil, state.current(s))
end)

test("new entries reset the view to the best match", function()
    local s = with_entries(50)
    state.move_selection(s, 20)
    state.set_entries(s, { { path = "a.lua" } })
    eq(1, s.selection)
    eq(1, s.scroll)
end)

-- scrolling ------------------------------------------------------------------

test("scrolling follows the selection past the top of the window", function()
    local s = with_entries(50, 5)
    eq(1, s.scroll)
    state.move_selection(s, 4)
    eq(1, s.scroll, "selection 5 is the last visible row")
    state.move_selection(s, 1)
    eq(2, s.scroll, "selection 6 should push the window up by one")
end)

test("scrolling back down follows the selection", function()
    local s = with_entries(50, 5)
    state.move_selection(s, 20)
    state.move_selection(s, -20)
    eq(1, s.selection)
    eq(1, s.scroll)
end)

test("the visible slice is bounded by the window height", function()
    local s = with_entries(50, 5)
    eq(5, #state.visible(s))
    eq("file1.lua", state.visible(s)[1].path, "the best match is the lowest visible row")

    state.move_selection(s, 9)
    local visible = state.visible(s)
    eq(5, #visible)
    eq("file6.lua", visible[1].path)
    eq("file10.lua", visible[#visible].path)
end)

test("the visible slice shrinks when entries do not fill the window", function()
    local s = with_entries(2, 5)
    eq(2, #state.visible(s))
end)

test("scroll never runs past the end of a short list", function()
    local s = with_entries(3, 5)
    state.move_selection(s, 2)
    eq(1, s.scroll)
end)

test("current returns the selected entry", function()
    local s = with_entries(5)
    state.move_selection(s, 2)
    eq("file3.lua", state.current(s).path)
end)
