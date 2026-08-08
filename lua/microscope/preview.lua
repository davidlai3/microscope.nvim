--- The preview pane.
---
--- Loads the selected file, centres the matched line and highlights it. Calls
--- are debounced by the picker, so this runs at most once per selection settle
--- rather than once per keystroke.

local state_mod = require("microscope.state")
local window = require("microscope.ui.window")

local M = {}

local ns = vim.api.nvim_create_namespace("microscope-preview")

---@param buf integer
---@param lines string[]
local function replace(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

--- Apply syntax highlighting for `path`.
---
--- With treesitter off this sets `syntax` rather than `filetype` on purpose:
--- `filetype` fires FileType autocommands, which is how treesitter and every
--- other language plugin attach themselves to a throwaway preview buffer.
---@param buf integer
---@param path string
---@param config table
local function apply_syntax(buf, path, config)
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].syntax = ""

    local filetype = vim.filetype.match({ filename = path })
    if not filetype then
        return
    end

    if config.preview.treesitter then
        local lang = vim.treesitter.language.get_lang(filetype)
        if lang and pcall(vim.treesitter.start, buf, lang) then
            return
        end
    end
    pcall(function()
        vim.bo[buf].syntax = filetype
    end)
end

--- Is this file binary?
---
--- The test has to run on raw bytes: `readfile` replaces NUL with a newline, so
--- by the time you have lines there is no NUL left to find.
---@param path string
---@return boolean
local function is_binary(path)
    local fd = vim.uv.fs_open(path, "r", 438)
    if not fd then
        return false
    end
    local head = vim.uv.fs_read(fd, 4096, 0)
    vim.uv.fs_close(fd)
    return head ~= nil and head:find("\0", 1, true) ~= nil
end

--- Read a file for display, refusing anything too large or not text.
---@param path string
---@param config table
---@return string[]|nil lines, string|nil reason
local function read(path, config)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil, "cannot read " .. vim.fn.fnamemodify(path, ":t")
    end
    if stat.type == "directory" then
        return nil, "directory"
    end
    if stat.size > config.preview.max_filesize then
        return nil, ("file is %.1f MB, too large to preview"):format(stat.size / 1024 / 1024)
    end
    if is_binary(path) then
        return nil, "binary file"
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil, "cannot read " .. vim.fn.fnamemodify(path, ":t")
    end
    return lines
end

--- Redraw the preview for the current selection.
---@param picker table
function M.show(picker)
    local windows, state, config = picker.windows, picker.state, picker.config
    if not windows.preview_win or not vim.api.nvim_win_is_valid(windows.preview_win) then
        return
    end

    local buf = windows.preview_buf
    local entry = state_mod.current(state)
    if not entry then
        windows.preview_path = nil
        replace(buf, {})
        window.set_title(windows.preview_win, "preview")
        return
    end

    local path = state.cwd .. "/" .. entry.path
    window.set_title(windows.preview_win, entry.path)

    if windows.preview_path ~= path then
        local lines, reason = read(path, config)
        if not lines then
            windows.preview_path = nil
            vim.wo[windows.preview_win].number = false
            replace(buf, { reason })
            return
        end
        windows.preview_path = path
        vim.wo[windows.preview_win].number = true
        replace(buf, lines)
        apply_syntax(buf, path, config)
    end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local line_count = vim.api.nvim_buf_line_count(buf)
    local lnum = math.max(1, math.min(entry.lnum or 1, line_count))
    pcall(vim.api.nvim_win_set_cursor, windows.preview_win, { lnum, 0 })
    -- Centre the match rather than leaving it wherever the last file left the view.
    pcall(vim.api.nvim_win_call, windows.preview_win, function()
        vim.cmd("normal! zz")
    end)

    if entry.lnum then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
            line_hl_group = "MicroscopePreviewLine",
            priority = 100,
        })
    end
end

--- Scroll the preview by half a screen. `direction` is 1 for down, -1 for up.
---@param picker table
---@param direction 1|-1
function M.scroll(picker, direction)
    local win = picker.windows.preview_win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    pcall(vim.api.nvim_win_call, win, function()
        local key = direction > 0 and "\4" or "\21" -- <C-d> / <C-u>
        vim.cmd("normal! " .. key)
    end)
end

return M
