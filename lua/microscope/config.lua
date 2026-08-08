--- Configuration defaults and user-option merging.
---
--- Everything in `defaults` is overridable through `require("microscope").setup()`.
--- Values are merged deeply, so a user table only needs the keys it wants to change.

local M = {}

M.defaults = {
    -- Floating window geometry. Fractions are relative to the editor; integers
    -- are taken as absolute cell counts.
    layout = {
        width = 0.85,
        height = 0.85,
        preview_width = 0.55,
        -- Rows of the results list to render. `nil` fills whatever height is left.
        max_results_height = nil,
    },

    preview = {
        enabled = true,
        max_filesize = 1024 * 1024,
        -- Treesitter is off by default: regex syntax is enough for a scrolling
        -- preview and is markedly cheaper on large files.
        treesitter = false,
    },

    rg = {
        hidden = false,
        no_ignore = false,
        -- Appended to every invocation, both `--files` and grep.
        extra_args = {},
    },

    debounce = {
        grep = 80,
        preview = 60,
        -- Ceiling on how often streaming results are rebuilt and redrawn.
        stream = 60,
    },

    limits = {
        -- Stop consuming ripgrep output past this many raw matches.
        max_results = 20000,
        -- When the file filter narrows to at most this many paths, hand them to
        -- ripgrep as explicit arguments instead of searching all of cwd. That is
        -- exact and never hits `max_results`, at the cost of re-running when the
        -- file set changes — which at this size takes tens of milliseconds.
        explicit_path_threshold = 2000,
        -- Bytes of argv to use per ripgrep invocation when passing explicit paths.
        argv_chunk_bytes = 100 * 1024,
    },

    keymaps = {
        close = { "<Esc>", "<C-c>" },
        -- One continuous motion over the prompt rows and the result list; see
        -- `move_cursor` in state.lua.
        cursor_up = { "<Tab>", "<Up>" },
        cursor_down = { "<S-Tab>", "<Down>" },
        -- Move the selection without the cursor leaving the prompt.
        next_item = "<C-n>",
        prev_item = "<C-p>",
        open = "<CR>",
        split = "<C-x>",
        vsplit = "<C-v>",
        tabedit = "<C-t>",
        quickfix = "<C-q>",
        toggle_hidden = "<C-h>",
        scroll_preview_down = "<C-d>",
        scroll_preview_up = "<C-u>",
    },

    -- Register <leader>ff and <leader>fg on setup().
    default_binds = true,
}

--- The active configuration. Replaced wholesale by `setup()`.
M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults.
---
--- Keymap lists are replaced rather than merged: `close = { "<Esc>" }` should
--- mean exactly one binding, not "<Esc>" plus whatever the defaults had.
---@param opts table|nil
---@return table
function M.setup(opts)
    opts = opts or {}
    vim.validate("opts", opts, "table")

    local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
    for key, value in pairs(opts.keymaps or {}) do
        merged.keymaps[key] = value
    end

    M.options = merged
    return merged
end

return M
