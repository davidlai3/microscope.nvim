--- Drawing the prompt and the results list.
---
--- This is the only module that knows the results list is drawn upside-down:
--- everywhere else index 1 means "best match", and here it becomes the *bottom*
--- row, closest to the prompt. When there are fewer results than rows, the list
--- is padded at the top so it stays anchored to the prompt.

local state_mod = require("microscope.state")
local window = require("microscope.ui.window")

local M = {}

--- Padded to a common width so the two prompt lines align. The leading space
--- keeps text off the window border, which `style = "minimal"` does not do.
M.LABELS = { grep = " grep  ❯ ", files = " files ❯ " }
M.CARET = " ❯ "
M.NO_CARET = "   "

--- Stands in for the middle of a path too long for its row. One display cell,
--- three bytes - both matter, since spans are measured in bytes and budgets in
--- cells.
M.ELLIPSIS = "…"
M.ELLIPSIS_WIDTH = 1

--- The caret is inline virtual text, so it occupies real columns on every
--- populated row and has to come out of the width available to the text.
M.CARET_WIDTH = vim.fn.strdisplaywidth(M.CARET)

local ns = window.ns

--- Buffer row (0-based) that a given entry index is drawn on.
---@param state microscope.State
---@param index integer 1-based index into `state.entries`
---@return integer|nil row nil when the entry is scrolled out of view
function M.row_for(state, index)
    local visible_position = index - state.scroll + 1
    if visible_position < 1 or visible_position > state.height then
        return nil
    end
    return state.height - visible_position
end

--- Inverse of `row_for`: which entry a buffer row shows.
---@param state microscope.State
---@param row integer 0-based
---@return integer|nil index nil for a padding row above the list
function M.index_for(state, row)
    local index = state.scroll + state.height - row - 1
    if index < 1 or index > #state.entries then
        return nil
    end
    return index
end

--- How many bytes of `text` at `col` the grep query accounts for.
---
--- ripgrep reports where a match starts but not how long it is. Rather than pay
--- for `--json` on every result, this checks the far more common case at draw
--- time, over the ~30 visible rows only: if the query appears literally at the
--- reported column, that is the match. A regex query simply gets no highlight.
---@param text string
---@param col integer 1-based
---@param query string
---@return integer|nil
local function match_length(text, col, query)
    if query == "" or col < 1 then
        return nil
    end
    local candidate = text:sub(col, col + #query - 1)
    if #candidate == #query and candidate:lower() == query:lower() then
        return #query
    end
    return nil
end

--- One UTF-8 character: a lead byte followed by its continuation bytes.
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

---@param str string
---@return string[]
local function characters(str)
    local chars = {}
    for char in str:gmatch(UTF8_CHAR) do
        chars[#chars + 1] = char
    end
    return chars
end

--- Bytes of the longest prefix of `chars` fitting in `budget` display cells.
---@param chars string[]
---@param budget integer
---@return integer
local function head_bytes(chars, budget)
    local width, bytes = 0, 0
    for i = 1, #chars do
        local cells = vim.fn.strdisplaywidth(chars[i])
        if width + cells > budget then
            break
        end
        width, bytes = width + cells, bytes + #chars[i]
    end
    return bytes, width
end

--- The same for the longest suffix.
---@param chars string[]
---@param budget integer
---@return integer
local function tail_bytes(chars, budget)
    local width, bytes = 0, 0
    for i = #chars, 1, -1 do
        local cells = vim.fn.strdisplaywidth(chars[i])
        if width + cells > budget then
            break
        end
        width, bytes = width + cells, bytes + #chars[i]
    end
    return bytes, width
end

--- Shorten `path` to `budget` display cells by replacing its middle with `…`.
---
--- The tail gets the larger half of what is left over: the basename is what the
--- reader is looking for, and the leading directories are the redundant part.
--- Both ends are grown a character at a time and measured in cells, so a path
--- with double-width characters is budgeted correctly and never cut in half.
---@param path string
---@param budget integer display cells
---@return string elided, { head: integer, tail_start: integer }|nil cut
---        `cut` holds the 0-based byte offsets bounding the removed region, and
---        is nil when the path fitted and nothing was removed.
function M.elide(path, budget)
    if vim.fn.strdisplaywidth(path) <= budget then
        return path, nil
    end

    local chars = characters(path)
    local spare = math.max(0, budget - M.ELLIPSIS_WIDTH)
    local tail, tail_width = tail_bytes(chars, math.ceil(spare / 2))
    -- Cells the tail could not use - a double-width character straddling its
    -- limit - are handed back to the head rather than wasted.
    local head = head_bytes(chars, spare - tail_width)

    return path:sub(1, head) .. M.ELLIPSIS .. path:sub(#path - tail + 1),
        { head = head, tail_start = #path - tail }
end

--- Where a byte offset into the original path lands after `cut` was applied.
---@param position integer 0-based
---@param cut { head: integer, tail_start: integer }|nil
---@return integer|nil nil when the offset was inside the elided region
local function reposition(position, cut)
    if not cut or position < cut.head then
        return position
    end
    if position < cut.tail_start then
        return nil
    end
    return position - cut.tail_start + cut.head + #M.ELLIPSIS
end

--- The text drawn for one entry, plus the highlight spans over it.
---@param entry microscope.Entry
---@param query string|nil the grep query, used to size the match highlight
---@param width integer|nil display cells available for the row; nil or 0 for
---       unlimited, which is what the unit tests and any non-window caller want
---@return string text, table[] spans each { from, to, group } with 0-based byte cols
function M.format(entry, query, width)
    local spans = {}
    local path = entry.path
    local budget = (width and width > 0) and width or nil

    if budget and entry.lnum then
        -- A grep row is split down the middle: the path keeps half the width
        -- and the matched line keeps the other half. Neither side wastes what
        -- it does not need - a short line leaves the path spelled out in full,
        -- and a short path leaves the line the rest of the row. Below half the
        -- path still never shrinks past its own basename, which on a narrow
        -- window can be the wider claim.
        local rest = (":%d %s"):format(entry.lnum, entry.text or "")
        local half = math.floor(width / 2)
        local floor = vim.fn.strdisplaywidth(path:match("[^/]*$")) + M.ELLIPSIS_WIDTH
        budget = math.min(width, math.max(width - vim.fn.strdisplaywidth(rest), half, floor))
    end

    local cut
    if budget then
        path, cut = M.elide(path, budget)
    end

    -- Recomputed on the elided path rather than remapped: whichever slash
    -- survives is the one the reader sees. If none did, the row simply has no
    -- directory span, exactly as a bare filename already does.
    local slash = path:find("/[^/]*$")

    if slash then
        table.insert(spans, { from = 0, to = slash, group = "MicroscopeDir" })
    end
    table.insert(spans, { from = slash or 0, to = #path, group = "MicroscopeFile" })

    local text = path
    if entry.lnum then
        local line = entry.text or ""
        local suffix = (":%d"):format(entry.lnum)
        table.insert(spans, { from = #text, to = #text + #suffix, group = "MicroscopeLnum" })
        text = text .. suffix .. " " .. line

        local length = entry.col and match_length(line, entry.col, query or "") or nil
        if length then
            -- `col` is 1-based within the source line, which starts one space
            -- after the `path:lnum` prefix.
            local offset = #path + #suffix + 1 + (entry.col - 1)
            table.insert(spans, { from = offset, to = offset + length, group = "MicroscopeMatch" })
        end
    end

    -- Fuzzy positions index into the path, which always starts at column 0.
    -- Elision moves the ones behind it and swallows the ones inside it.
    for _, position in ipairs(entry.positions or {}) do
        local at = reposition(position, cut)
        if at then
            table.insert(spans, { from = at, to = at + 1, group = "MicroscopeMatch" })
        end
    end

    return text, spans
end

--- Redraw the results list.
---@param windows microscope.Windows
---@param state microscope.State
function M.results(windows, state)
    local buf = windows.results_buf
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local visible = state_mod.visible(state)
    local lines, all_spans = {}, {}
    local width = state.width > 0 and state.width - M.CARET_WIDTH or 0

    for _ = 1, state.height - #visible do
        table.insert(lines, "")
    end
    for i = #visible, 1, -1 do
        local text, spans = M.format(visible[i], state.queries.grep, width)
        table.insert(lines, text)
        all_spans[#lines] = spans
    end

    if #state.entries == 0 then
        local message = state.error or (state.loading and "searching…" or "no matches")
        lines[#lines] = message
        all_spans[#lines] = { { from = 0, to = #message, group = "MicroscopeEmpty" } }
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local selected_row = #state.entries > 0 and M.row_for(state, state.selection) or nil

    for line_number, spans in pairs(all_spans) do
        local row = line_number - 1
        local line_length = #lines[line_number]
        for _, span in ipairs(spans) do
            if span.from < line_length then
                pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, span.from, {
                    end_col = math.min(span.to, line_length),
                    hl_group = span.group,
                    -- Later spans (the fuzzy matches) must win over the path
                    -- colouring they sit on top of.
                    priority = span.group == "MicroscopeMatch" and 200 or 100,
                })
            end
        end
    end

    -- The caret occupies real columns on every populated row, so nothing shifts
    -- as the selection moves.
    for line_number = 1, #lines do
        if lines[line_number] ~= "" then
            local row = line_number - 1
            local selected = row == selected_row
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                virt_text = { { selected and M.CARET or M.NO_CARET, "MicroscopeSelectionCaret" } },
                virt_text_pos = "inline",
                right_gravity = false,
                line_hl_group = selected and "MicroscopeSelection" or nil,
                priority = 90,
            })
        end
    end

    if selected_row and vim.api.nvim_win_is_valid(windows.results_win) then
        pcall(vim.api.nvim_win_set_cursor, windows.results_win, { selected_row + 1, 0 })
    end
end

--- Redraw the `files ❯` / `grep ❯` labels and place the cursor.
---@param windows microscope.Windows
---@param state microscope.State
function M.prompt(windows, state)
    local buf = windows.prompt_buf
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row, field in ipairs({ "grep", "files" }) do
        local active = state.focus == field
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
            virt_text = {
                { M.LABELS[field], active and "MicroscopePromptLabelActive" or "MicroscopePromptLabel" },
            },
            virt_text_pos = "inline",
            right_gravity = false,
        })
    end
end

--- Refresh the border titles: the result counter and the active file count.
---@param windows microscope.Windows
---@param state microscope.State
function M.titles(windows, state)
    local parts = { tostring(#state.entries) }
    if state.truncated then
        table.insert(parts, "+")
    end
    table.insert(parts, state_mod.mode(state) == "grep" and " matches" or " files")
    if state.loading then
        table.insert(parts, " …")
    end
    window.set_title(windows.results_win, table.concat(parts))
end

--- Redraw everything.
---@param windows microscope.Windows
---@param state microscope.State
function M.all(windows, state)
    M.prompt(windows, state)
    M.results(windows, state)
    M.titles(windows, state)
end

return M
