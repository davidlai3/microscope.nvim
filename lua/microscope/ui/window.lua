--- Creation, teardown and focus of the picker's floating windows.
---
--- Knows nothing about queries or results — it owns window handles and the
--- options set on them, and nothing else.

local layout = require("microscope.ui.layout")

local M = {}

M.ns = vim.api.nvim_create_namespace("microscope")

local WINHIGHLIGHT = table.concat({
    "Normal:MicroscopeNormal",
    "NormalNC:MicroscopeNormal",
    "FloatBorder:MicroscopeBorder",
    "FloatTitle:MicroscopeTitle",
    "CursorLine:MicroscopeSelection",
    "Search:None",
    "EndOfBuffer:MicroscopeNormal",
}, ",")

---@param filetype string
---@return integer
local function scratch_buffer(filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = filetype
    return buf
end

---@param buf integer
---@param rect microscope.Rect
---@param opts table extra `nvim_open_win` config
---@return integer
local function open(buf, rect, opts)
    local win_config = vim.tbl_extend("force", layout.to_win_config(rect), {
        style = "minimal",
        border = "rounded",
        noautocmd = true,
        zindex = 60,
    }, opts or {})
    local win = vim.api.nvim_open_win(buf, false, win_config)
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].wrap = false
    vim.wo[win].scrolloff = 0
    vim.wo[win].sidescrolloff = 0
    return win
end

---@class microscope.Windows
---@field prompt_buf integer
---@field results_buf integer
---@field preview_buf integer|nil
---@field prompt_win integer
---@field results_win integer
---@field preview_win integer|nil
---@field layout microscope.Layout
---@field prev_win integer the window to return to on close

--- Open the picker's windows. The prompt is left unfocused; the caller decides.
---@param config table
---@return microscope.Windows
function M.open(config)
    local columns, lines = layout.editor_size()
    local computed = layout.compute({ columns = columns, lines = lines, config = config })

    local windows = {
        prev_win = vim.api.nvim_get_current_win(),
        layout = computed,
        prompt_buf = scratch_buffer("microscope-prompt"),
        results_buf = scratch_buffer("microscope-results"),
    }

    windows.results_win = open(windows.results_buf, computed.results, {
        title = " results ",
        title_pos = "left",
    })
    vim.wo[windows.results_win].cursorline = false

    if computed.preview then
        windows.preview_buf = scratch_buffer("")
        windows.preview_win = open(windows.preview_buf, computed.preview, {
            title = " preview ",
            title_pos = "left",
        })
        vim.wo[windows.preview_win].number = true
        vim.wo[windows.preview_win].signcolumn = "no"
    end

    windows.prompt_win = open(windows.prompt_buf, computed.prompt, {
        title = " microscope ",
        title_pos = "left",
        zindex = 61,
    })
    vim.bo[windows.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.prompt_buf, 0, -1, false, { "", "" })

    vim.bo[windows.results_buf].modifiable = false

    return windows
end

---@param windows microscope.Windows
---@return boolean
function M.valid(windows)
    return windows ~= nil
        and vim.api.nvim_win_is_valid(windows.prompt_win)
        and vim.api.nvim_win_is_valid(windows.results_win)
end

--- Set a window's border title, e.g. the result counter.
---@param win integer|nil
---@param title string
function M.set_title(win, title)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_config, win, { title = " " .. title .. " ", title_pos = "left" })
    end
end

--- Re-place every window after the editor is resized.
---@param windows microscope.Windows
---@param config table
---@return microscope.Layout
function M.relayout(windows, config)
    local columns, lines = layout.editor_size()
    local computed = layout.compute({ columns = columns, lines = lines, config = config })
    windows.layout = computed

    local function place(win, rect)
        if win and vim.api.nvim_win_is_valid(win) and rect then
            pcall(vim.api.nvim_win_set_config, win, layout.to_win_config(rect))
        end
    end

    place(windows.results_win, computed.results)
    place(windows.prompt_win, computed.prompt)

    -- The preview can appear or vanish across a resize; only reposition it while
    -- the new layout still has room for it.
    if windows.preview_win and vim.api.nvim_win_is_valid(windows.preview_win) then
        if computed.preview then
            place(windows.preview_win, computed.preview)
        else
            pcall(vim.api.nvim_win_close, windows.preview_win, true)
            windows.preview_win, windows.preview_buf = nil, nil
        end
    end

    return computed
end

--- Close every window and return to wherever the user was.
---@param windows microscope.Windows
function M.close(windows)
    if not windows then
        return
    end
    for _, win in ipairs({ windows.prompt_win, windows.results_win, windows.preview_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    for _, buf in ipairs({ windows.prompt_buf, windows.results_buf, windows.preview_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    if windows.prev_win and vim.api.nvim_win_is_valid(windows.prev_win) then
        pcall(vim.api.nvim_set_current_win, windows.prev_win)
    end
end

return M
