--- Picker state and the pure transitions over it.
---
--- Everything here is data manipulation: no windows, no processes. The picker
--- owns an instance and calls these to answer "what should be on screen now?".
---
--- Selection indices are natural (1 = best match). The results list is *drawn*
--- bottom-up so the best match sits next to the prompt, but that inversion lives
--- entirely in `ui/render.lua`.

local M = {}

--- The picker is one continuous column of cursor stops, numbered bottom to top
--- to match the on-screen layout:
---
---     2 + #entries   entry N, the worst match, at the top of the list
---     …
---     3              entry 1, the best match, sitting against the prompt
---     2              grep  ❯
---     1              files ❯
---
--- `PROMPT_STOPS` is how many of those stops are prompt rows rather than
--- entries, i.e. the offset between a stop index and a selection index.
M.PROMPT_STOPS = 2

---@class microscope.Entry
---@field path string relative to the picker's cwd
---@field lnum integer|nil 1-based line, set for grep results
---@field col integer|nil 1-based column, set for grep results
---@field text string|nil the matched line's text, set for grep results
---@field positions integer[]|nil 0-based byte offsets to highlight in `path`

---@class microscope.State
---@field cwd string
---@field queries table<"files"|"grep", string>
---@field focus "files"|"grep"|"list"
---@field all_paths string[] every candidate file, from `rg --files`
---@field paths string[] `all_paths` narrowed by the files query
---@field positions integer[][] fuzzy match offsets parallel to `paths`
---@field entries microscope.Entry[] what is currently shown
---@field selection integer 1-based index into `entries`
---@field scroll integer 1-based index of the lowest visible entry
---@field height integer rows available in the results window
---@field width integer columns available in the results window, 0 for unlimited
---@field truncated boolean ripgrep output hit the result cap
---@field loading boolean a source is still producing results
---@field error string|nil shown in place of "no matches", e.g. a bad regex
---@field filter_cache table reused by `filter.filter` for incremental narrowing

---@param cwd string
---@return microscope.State
function M.new(cwd)
    return {
        cwd = cwd,
        queries = { files = "", grep = "" },
        focus = "files",
        all_paths = {},
        paths = {},
        positions = {},
        entries = {},
        selection = 1,
        scroll = 1,
        height = 1,
        width = 0,
        truncated = false,
        loading = true,
        error = nil,
        filter_cache = {},
    }
end

--- Which kind of result the current queries produce.
---@param state microscope.State
---@return "files"|"grep"
function M.mode(state)
    return state.queries.grep ~= "" and "grep" or "files"
end

--- Which stop the cursor is on right now.
---@param state microscope.State
---@return integer
local function stop_index(state)
    if state.focus == "list" then
        return M.PROMPT_STOPS + state.selection
    end
    return state.focus == "grep" and 2 or 1
end

--- Move the cursor one stop, treating the prompt rows and the result entries as
--- a single ring.
---
--- Wrapping is what makes the motion continuous in both directions: walking up
--- off the top of the list comes back round to the files prompt. With no entries
--- the ring is just the two prompt rows, so an empty list is never focused and a
--- stale `focus == "list"` escapes on the first press.
---@param state microscope.State
---@param direction 1|-1 positive moves up the screen
function M.move_cursor(state, direction)
    local stops = M.PROMPT_STOPS + #state.entries
    local index = ((stop_index(state) - 1 + direction) % stops) + 1

    if index == 1 then
        state.focus = "files"
    elseif index == 2 then
        state.focus = "grep"
    else
        state.focus = "list"
        state.selection = index - M.PROMPT_STOPS
        M.clamp_scroll(state)
    end
end

--- Move the selection by `delta` entries, clamped at both ends.
---
--- Clamping rather than wrapping is deliberate: with the list drawn upward,
--- wrapping teleports the cursor across the whole window and reads as a glitch.
---@param state microscope.State
---@param delta integer
function M.move_selection(state, delta)
    if #state.entries == 0 then
        state.selection, state.scroll = 1, 1
        return
    end
    state.selection = math.max(1, math.min(#state.entries, state.selection + delta))
    M.clamp_scroll(state)
end

--- Keep the selection inside the visible window.
---@param state microscope.State
function M.clamp_scroll(state)
    local height = math.max(1, state.height)
    if state.selection < state.scroll then
        state.scroll = state.selection
    elseif state.selection > state.scroll + height - 1 then
        state.scroll = state.selection - height + 1
    end
    local max_scroll = math.max(1, #state.entries - height + 1)
    state.scroll = math.max(1, math.min(state.scroll, max_scroll))
end

--- Replace the result list.
---
--- `preserve` keeps the current selection index, which is what streaming results
--- want: more matches arriving should not yank the cursor back to the top while
--- the user is already navigating.
---@param state microscope.State
---@param entries microscope.Entry[]
---@param preserve boolean|nil
function M.set_entries(state, entries, preserve)
    state.entries = entries
    if not preserve then
        state.selection = 1
        state.scroll = 1
    end
    state.selection = math.max(1, math.min(math.max(#entries, 1), state.selection))
    M.clamp_scroll(state)
end

--- The entries that should be drawn, lowest visible first.
---@param state microscope.State
---@return microscope.Entry[]
function M.visible(state)
    local last = math.min(#state.entries, state.scroll + math.max(1, state.height) - 1)
    return vim.list_slice(state.entries, state.scroll, last)
end

---@param state microscope.State
---@return microscope.Entry|nil
function M.current(state)
    return state.entries[state.selection]
end

return M
