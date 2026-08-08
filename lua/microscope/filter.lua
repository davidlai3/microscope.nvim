--- Pure path filtering: fuzzy matching and gitignore-style globs.
---
--- This module never touches the editor or spawns a process. Given a list of
--- paths and a query it returns the matching subset plus the byte positions that
--- matched, which the renderer turns into highlights.
---
--- A query is treated as a glob when it contains one of `* ? [ {` or starts with
--- `!`; otherwise it is fuzzy-matched. Filtering is always done here rather than
--- by ripgrep, so the file set is identical whichever way the grep stage later
--- decides to invoke ripgrep.

local M = {}

local GLOB_CHARS = "[%*%?%[{]"

--- Does this query use glob syntax rather than fuzzy matching?
---@param query string
---@return boolean
function M.is_glob(query)
    if query == "" then
        return false
    end
    return query:sub(1, 1) == "!" or query:find(GLOB_CHARS) ~= nil
end

--- Escape a literal character for use in a Vim regex.
local function escape_literal(char)
    if char:match("[%^%$%.%~%[%]%\\/]") then
        return "\\" .. char
    end
    return char
end

--- Translate one gitignore-style glob into a Vim regex.
---
--- Semantics follow ripgrep: `*` and `?` do not cross `/`, `**` does, `{a,b}`
--- alternates, a pattern containing no `/` matches against any path component,
--- and a trailing `/` means "everything under this directory".
---@param glob string
---@return string
function M.glob_to_regex(glob)
    local anchored = glob:sub(1, 1) == "/"
    if anchored then
        glob = glob:sub(2)
    end
    -- `src/` is shorthand for `src/**`.
    if glob:sub(-1) == "/" then
        glob = glob .. "**"
    end

    local has_slash = glob:find("/") ~= nil
    local out = {}
    local i = 1
    local len = #glob

    while i <= len do
        local char = glob:sub(i, i)
        if char == "*" then
            if glob:sub(i + 1, i + 1) == "*" then
                -- `**/` should also match zero directories, so `**/foo` matches `foo`.
                if glob:sub(i + 2, i + 2) == "/" then
                    table.insert(out, "\\(.*/\\)\\?")
                    i = i + 3
                else
                    table.insert(out, ".*")
                    i = i + 2
                end
            else
                table.insert(out, "[^/]*")
                i = i + 1
            end
        elseif char == "?" then
            table.insert(out, "[^/]")
            i = i + 1
        elseif char == "{" then
            local close = glob:find("}", i, true)
            if close then
                local alternatives = vim.split(glob:sub(i + 1, close - 1), ",", { plain = true })
                local escaped = {}
                for _, alternative in ipairs(alternatives) do
                    -- Strip the anchors the recursive call adds; the branch is
                    -- only ever a fragment of the surrounding pattern.
                    local branch = M.glob_to_regex(alternative)
                    branch = branch:gsub("^\\%(%^\\|/\\%)", ""):gsub("^%^", ""):gsub("%$$", "")
                    table.insert(escaped, branch)
                end
                table.insert(out, "\\(" .. table.concat(escaped, "\\|") .. "\\)")
                i = close + 1
            else
                table.insert(out, "{")
                i = i + 1
            end
        elseif char == "[" then
            local close = glob:find("]", i + 1, true)
            if close then
                local class = glob:sub(i + 1, close - 1)
                -- gitignore uses `!` for class negation, Vim regex uses `^`.
                if class:sub(1, 1) == "!" then
                    class = "^" .. class:sub(2)
                end
                table.insert(out, "[" .. class .. "]")
                i = close + 1
            else
                table.insert(out, "\\[")
                i = i + 1
            end
        else
            table.insert(out, escape_literal(char))
            i = i + 1
        end
    end

    local body = table.concat(out)
    local prefix = (anchored or has_slash) and "^" or "\\(^\\|/\\)"
    return prefix .. body .. "$"
end

--- Compile a whitespace-separated glob query into a match predicate.
---
--- A path matches when it matches at least one positive glob (or there are none)
--- and matches no negated `!glob`.
---@param query string
---@return fun(path: string): boolean
function M.compile_glob(query)
    local positives, negatives = {}, {}

    for _, token in ipairs(vim.split(query, "%s+", { trimempty = true })) do
        local negated = token:sub(1, 1) == "!"
        if negated then
            token = token:sub(2)
        end
        if token ~= "" then
            local ok, regex = pcall(vim.regex, M.glob_to_regex(token))
            if ok then
                table.insert(negated and negatives or positives, regex)
            end
        end
    end

    return function(path)
        for _, regex in ipairs(negatives) do
            if regex:match_str(path) then
                return false
            end
        end
        if #positives == 0 then
            return true
        end
        for _, regex in ipairs(positives) do
            if regex:match_str(path) then
                return true
            end
        end
        return false
    end
end

--- Convert character indices from `matchfuzzypos` into byte offsets.
---
--- The fast path covers ASCII paths, which is nearly all of them.
---@param str string
---@param char_positions integer[]
---@return integer[]
local function char_to_byte_positions(str, char_positions)
    if #str == vim.fn.strchars(str) then
        return char_positions
    end
    local bytes = {}
    for _, char_index in ipairs(char_positions) do
        table.insert(bytes, vim.fn.byteidx(str, char_index))
    end
    return bytes
end

---@class microscope.FilterResult
---@field paths string[] matched paths, best match first
---@field positions integer[][] 0-based byte offsets that matched, parallel to `paths`
---@field kind "all"|"fuzzy"|"glob"

--- Filter `paths` by `query`.
---
--- `cache` is an optional table owned by the caller and reused across keystrokes.
--- When the new query extends the one it holds, the previous (smaller) result set
--- is filtered instead of the full list. That is sound because both fuzzy
--- subsequence matching and globs can only ever shrink as a query grows.
---@param paths string[]
---@param query string
---@param cache table|nil
---@return microscope.FilterResult
function M.filter(paths, query, cache)
    if query == "" then
        if cache then
            cache.query, cache.paths = "", paths
        end
        return { paths = paths, positions = {}, kind = "all" }
    end

    local candidates = paths
    if
        cache
        and cache.query
        and cache.query ~= ""
        and cache.paths
        and #cache.query < #query
        and query:sub(1, #cache.query) == cache.query
        -- Only narrow within one mode: a query can cross from fuzzy to glob as
        -- soon as a `*` is typed, and the two match different path sets.
        and M.is_glob(cache.query) == M.is_glob(query)
    then
        candidates = cache.paths
    end

    local result
    if M.is_glob(query) then
        local matches = M.compile_glob(query)
        local matched = {}
        for _, path in ipairs(candidates) do
            if matches(path) then
                table.insert(matched, path)
            end
        end
        result = { paths = matched, positions = {}, kind = "glob" }
    else
        local matched, char_positions = unpack(vim.fn.matchfuzzypos(candidates, query))
        local positions = {}
        for index, path in ipairs(matched) do
            positions[index] = char_to_byte_positions(path, char_positions[index] or {})
        end
        result = { paths = matched, positions = positions, kind = "fuzzy" }
    end

    if cache then
        cache.query, cache.paths = query, result.paths
    end
    return result
end

--- Build a set for O(1) membership tests when filtering grep output by path.
---@param paths string[]
---@return table<string, boolean>
function M.to_set(paths)
    local set = {}
    for _, path in ipairs(paths) do
        set[path] = true
    end
    return set
end

return M
