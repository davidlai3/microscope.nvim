--- Highlight groups, all linked to standard groups so any colorscheme works.
---
--- Definitions use `default = true`, so a user's own `:highlight Microscope*`
--- always wins and the links are re-applied after a `:colorscheme` change.

local M = {}

M.links = {
    MicroscopeNormal = "NormalFloat",
    MicroscopeBorder = "FloatBorder",
    MicroscopeTitle = "Title",
    -- Characters a fuzzy query matched.
    MicroscopeMatch = "Special",
    -- The highlighted row in the results list.
    MicroscopeSelection = "CursorLine",
    -- The `>` beside the selected row.
    MicroscopeSelectionCaret = "Statement",
    -- The `files ❯` / `grep ❯` labels.
    MicroscopePromptLabel = "Comment",
    MicroscopePromptLabelActive = "Statement",
    -- Directory part of a result path.
    MicroscopeDir = "Comment",
    MicroscopeFile = "Normal",
    MicroscopeLnum = "LineNr",
    MicroscopeEmpty = "Comment",
    -- The matched line inside the preview.
    MicroscopePreviewLine = "Visual",
}

function M.setup()
    for group, target in pairs(M.links) do
        vim.api.nvim_set_hl(0, group, { link = target, default = true })
    end

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("MicroscopeHighlight", { clear = true }),
        callback = function()
            for group, target in pairs(M.links) do
                vim.api.nvim_set_hl(0, group, { link = target, default = true })
            end
        end,
    })
end

return M
