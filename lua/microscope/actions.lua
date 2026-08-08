--- What Enter and friends do with the current selection.
---
--- Every action closes the picker first, so the file opens in the window the
--- user came from rather than inside a floating scratch window.

local state_mod = require("microscope.state")

local M = {}

---@param picker table
---@param entry microscope.Entry
---@return string absolute path
local function absolute(picker, entry)
    return picker.state.cwd .. "/" .. entry.path
end

--- Close the picker, then run `fn` once Neovim has really left insert mode.
---
--- `stopinsert` does not take effect until control returns to the main loop, and
--- leaving insert mode nudges the cursor one column left. Without the schedule
--- that nudge lands on the file we just opened and every grep hit is off by one.
---@param picker table
---@param fn fun()
local function after_close(picker, fn)
    picker:close()
    vim.schedule(fn)
end

--- Open the selection with `command` ("edit", "split", "vsplit", "tabedit").
---@param picker table
---@param command string
function M.open(picker, command)
    local entry = state_mod.current(picker.state)
    if not entry then
        return
    end
    local path = absolute(picker, entry)

    after_close(picker, function()
        vim.cmd(("%s %s"):format(command, vim.fn.fnameescape(path)))

        if entry.lnum then
            local lnum = math.min(entry.lnum, vim.api.nvim_buf_line_count(0))
            pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(0, (entry.col or 1) - 1) })
            -- Put the match mid-window and open any fold hiding it.
            vim.cmd("normal! zvzz")
        end
    end)
end

--- Send every current result to the quickfix list and open it.
---@param picker table
function M.quickfix(picker)
    local entries = picker.state.entries
    if #entries == 0 then
        return
    end

    local items = {}
    for _, entry in ipairs(entries) do
        table.insert(items, {
            filename = absolute(picker, entry),
            lnum = entry.lnum or 1,
            col = entry.col or 1,
            text = entry.text or "",
        })
    end

    local title = ("microscope: %s"):format(picker:describe_query())
    after_close(picker, function()
        vim.fn.setqflist({}, " ", { title = title, items = items })
        vim.cmd("copen")
    end)
end

--- Toggle hidden and ignored files, then reload the file list.
---@param picker table
function M.toggle_hidden(picker)
    picker.config.rg.hidden = not picker.config.rg.hidden
    picker.config.rg.no_ignore = picker.config.rg.hidden
    picker:reload()
end

return M
