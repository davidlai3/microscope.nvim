--- microscope.nvim — one picker with two query fields.
---
---     files blank, grep blank  ->  every file
---     files set,   grep blank  ->  the narrowed file list
---     files blank, grep set    ->  grep across everything
---     files set,   grep set    ->  grep inside the narrowed file list
---
--- Because the blank cases degrade to plain file-finding and plain grepping,
--- this one picker replaces both.

local config = require("microscope.config")
local highlight = require("microscope.ui.highlight")
local picker = require("microscope.picker")

local M = {}

---@param opts table|nil see `microscope.config.defaults`
function M.setup(opts)
    local options = config.setup(opts)
    highlight.setup()

    if options.default_binds then
        vim.keymap.set("n", "<leader>ff", M.find_files, { desc = "microscope: find files" })
        vim.keymap.set("n", "<leader>fg", M.live_grep, { desc = "microscope: live grep" })
    end
end

--- Open the picker.
---@param opts { cwd?: string, focus?: "files"|"grep", files_query?: string, grep_query?: string }|nil
function M.open(opts)
    return picker.open(opts)
end

--- Open with the files field focused. Identical window to `live_grep`.
---@param opts table|nil
function M.find_files(opts)
    return M.open(vim.tbl_extend("force", { focus = "files" }, opts or {}))
end

--- Open with the grep field focused. Identical window to `find_files`.
---@param opts table|nil
function M.live_grep(opts)
    return M.open(vim.tbl_extend("force", { focus = "grep" }, opts or {}))
end

--- Forget the cached file list so the next open re-walks the directory.
---@param cwd string|nil
function M.refresh(cwd)
    require("microscope.source.files").invalidate(cwd)
end

return M
