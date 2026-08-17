--- The picker: wires the state machine to the windows, the sources and the keys.
---
--- The pipeline it drives:
---
---     files query edited ─> filter over the cached path list (no process spawn)
---                             ├─ grep blank ─> results are those paths
---                             └─ grep set   ─> re-filter buffered grep output
---     grep query edited  ─> debounce ─> kill in-flight rg ─> spawn ─> stream

local actions = require("microscope.actions")
local config_mod = require("microscope.config")
local filter = require("microscope.filter")
local files_source = require("microscope.source.files")
local grep_source = require("microscope.source.grep")
local preview = require("microscope.preview")
local render = require("microscope.ui.render")
local rg = require("microscope.rg")
local state_mod = require("microscope.state")
local util = require("microscope.util")
local window = require("microscope.ui.window")

local Picker = {}
Picker.__index = Picker

local M = {}

--- The picker that is currently open, if any. Only one exists at a time.
---@type table|nil
M.current = nil

local next_id = 0

--- Open the picker.
---@param opts { cwd?: string, focus?: "files"|"grep", files_query?: string, grep_query?: string }
---@return table|nil
function M.open(opts)
    opts = opts or {}

    if not rg.executable() then
        vim.notify("microscope: ripgrep (rg) is not on PATH", vim.log.levels.ERROR)
        return nil
    end

    if M.current then
        M.current:close()
    end

    next_id = next_id + 1

    local picker = setmetatable({
        id = next_id,
        -- A per-picker copy, so toggling hidden files does not leak into the
        -- next picker or into another user's configuration.
        config = vim.deepcopy(config_mod.options),
        handles = {},
    }, Picker)

    picker.state = state_mod.new(opts.cwd or vim.fn.getcwd())
    picker.state.queries.files = opts.files_query or ""
    picker.state.queries.grep = opts.grep_query or ""
    picker.state.focus = opts.focus or "files"

    picker.windows = window.open(picker.config)
    picker.state.height = picker.windows.layout.results_height
    picker.state.width = picker.windows.layout.results_width

    picker.grep_debounced = util.debounce(picker.config.debounce.grep, function()
        picker:run_grep()
    end)
    picker.preview_debounced = util.debounce(picker.config.debounce.preview, function()
        picker:update_preview()
    end)
    -- Rebuilding the result list is O(filtered paths), so it must not run once
    -- per ripgrep chunk. Throttling keeps results appearing steadily instead.
    picker.stream_throttled = util.throttle(picker.config.debounce.stream, function()
        picker:recompute(true)
    end)

    vim.api.nvim_buf_set_lines(picker.windows.prompt_buf, 0, -1, false, {
        picker.state.queries.grep,
        picker.state.queries.files,
    })

    picker:setup_keymaps()
    picker:setup_autocmds()

    M.current = picker
    picker:apply_focus()
    picker:reload()
    render.all(picker.windows, picker.state)

    return picker
end

-- lifecycle ------------------------------------------------------------------

function Picker:close()
    if self.closed then
        return
    end
    self.closed = true

    if M.current == self then
        M.current = nil
    end

    for _, handle in pairs(self.handles) do
        handle:kill()
    end
    self.handles = {}

    self.grep_debounced.close()
    self.preview_debounced.close()
    self.stream_throttled.close()

    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    vim.cmd("stopinsert")
    window.close(self.windows)
end

--- Re-run the file source, discarding the cached list for this directory.
---
--- Also re-runs any active grep: `reload` is how the hidden-files toggle takes
--- effect, and that flag changes what ripgrep searches as well as what it lists.
function Picker:reload()
    files_source.invalidate(self.state.cwd)
    self.state.loading = true
    self.state.filter_cache = {}

    if self.handles.files then
        self.handles.files:kill()
    end
    if state_mod.mode(self.state) == "grep" then
        self.grep_debounced()
    end

    self.handles.files = files_source.load(self.state.cwd, self.config.rg, function(paths)
        if self.closed then
            return
        end
        self.state.all_paths = paths
        self:refilter()
    end, function(paths)
        if self.closed then
            return
        end
        self.state.all_paths = paths
        self.state.loading = false
        self:refilter()
    end)
end

-- pipeline -------------------------------------------------------------------

--- Apply the files query. Never spawns a process: it filters the cached list.
function Picker:refilter()
    local result = filter.filter(self.state.all_paths, self.state.queries.files, self.state.filter_cache)
    self.state.paths = result.paths
    self.state.positions = result.positions

    -- A scoped grep was told which files to look at, so a change to the file set
    -- invalidates its results and it has to run again. An unscoped grep searched
    -- everything, so its output is still a superset and only needs re-bucketing.
    if state_mod.mode(self.state) == "grep" and self:grep_needs_rerun() then
        self.grep_debounced()
    end

    self:recompute()
end

--- Would the current file set be searched differently from the last grep run?
---@return boolean
function Picker:grep_needs_rerun()
    local scoped = #self.state.paths <= self.config.limits.explicit_path_threshold
    return scoped or not self.grep_run or self.grep_run.scoped
end

--- Rebuild the result list from the current paths and grep output.
---@param preserve boolean|nil keep the selection index; used while streaming
function Picker:recompute(preserve)
    if state_mod.mode(self.state) == "files" then
        local entries = {}
        for index, path in ipairs(self.state.paths) do
            entries[index] = { path = path, positions = self.state.positions[index] }
        end
        state_mod.set_entries(self.state, entries, preserve)
    else
        self:apply_grep_filter(preserve)
    end
    self:redraw()
end

function Picker:redraw()
    if self.closed or not window.valid(self.windows) then
        return
    end
    render.all(self.windows, self.state)
    self.preview_debounced()
end

--- Intersect the buffered grep output with the current file set.
---
--- Results are bucketed by path when they arrive, so this walks the (usually
--- small) filtered path list rather than the (possibly huge) match list, and
--- inherits the fuzzy ranking of the paths.
---@param preserve boolean|nil
function Picker:apply_grep_filter(preserve)
    local run = self.grep_run
    if not run then
        state_mod.set_entries(self.state, {}, preserve)
        return
    end

    local entries = {}
    for _, path in ipairs(self.state.paths) do
        for _, entry in ipairs(run.by_path[path] or {}) do
            table.insert(entries, entry)
        end
    end
    state_mod.set_entries(self.state, entries, preserve)
end

--- Start a grep for the current pattern, cancelling any run still in flight.
function Picker:run_grep()
    if self.closed then
        return
    end

    if self.handles.grep then
        self.handles.grep:kill()
        self.handles.grep = nil
    end

    local pattern = self.state.queries.grep
    if pattern == "" then
        self.grep_run = nil
        self.state.truncated = false
        self.state.error = nil
        self.state.loading = false
        self:recompute()
        return
    end

    local scoped = #self.state.paths <= self.config.limits.explicit_path_threshold
    local run = { scoped = scoped, by_path = {}, count = 0 }
    self.grep_run = run

    self.state.truncated = false
    self.state.error = nil
    self.state.loading = true
    render.titles(self.windows, self.state)

    self.handles.grep = grep_source.search({
        cwd = self.state.cwd,
        pattern = pattern,
        rg_opts = self.config.rg,
        paths = scoped and self.state.paths or nil,
        max_results = self.config.limits.max_results,
        argv_chunk_bytes = self.config.limits.argv_chunk_bytes,
        on_batch = function(entries)
            -- A stale run's callbacks must not touch the current results.
            if self.closed or self.grep_run ~= run then
                return
            end
            for _, entry in ipairs(entries) do
                local bucket = run.by_path[entry.path]
                if not bucket then
                    bucket = {}
                    run.by_path[entry.path] = bucket
                end
                table.insert(bucket, entry)
            end
            run.count = run.count + #entries
            self.stream_throttled()
        end,
        on_done = function(reason, exit_code)
            if self.closed or self.grep_run ~= run then
                return
            end
            self.state.loading = false
            self.state.truncated = reason == "limit"
            -- ripgrep exits 2 on a malformed regex. Saying so beats "no matches",
            -- which is what a half-typed `foo(` would otherwise look like.
            self.state.error = (exit_code == 2 and run.count == 0) and "invalid search pattern" or nil
            self.stream_throttled.cancel()
            self:recompute(true)
        end,
    })
end

function Picker:update_preview()
    if not self.closed and window.valid(self.windows) then
        preview.show(self)
    end
end

---@param direction 1|-1
function Picker:scroll_preview(direction)
    preview.scroll(self, direction)
end

--- A short description of the active query, used for the quickfix title.
---@return string
function Picker:describe_query()
    local parts = {}
    if self.state.queries.files ~= "" then
        table.insert(parts, "files=" .. self.state.queries.files)
    end
    if self.state.queries.grep ~= "" then
        table.insert(parts, "grep=" .. self.state.queries.grep)
    end
    return #parts > 0 and table.concat(parts, " ") or "all files"
end

-- input ----------------------------------------------------------------------

--- Read both queries back out of the prompt buffer and react to what changed.
function Picker:on_prompt_changed()
    if self.closed then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(self.windows.prompt_buf, 0, -1, false)
    -- A pasted newline would otherwise leave the buffer with the wrong shape.
    if #lines ~= 2 then
        local grep = lines[1] or ""
        local files = table.concat(vim.list_slice(lines, 2), "")
        self.updating_prompt = true
        vim.api.nvim_buf_set_lines(self.windows.prompt_buf, 0, -1, false, { grep, files })
        self.updating_prompt = false
        lines = { grep, files }
    end

    local grep, files = lines[1], lines[2]
    local grep_changed = grep ~= self.state.queries.grep
    local files_changed = files ~= self.state.queries.files

    self.state.queries.grep = grep
    self.state.queries.files = files

    if grep_changed then
        self.grep_debounced()
        -- Repaint the counter immediately so the mode switch is visible even
        -- before ripgrep has produced anything.
        render.titles(self.windows, self.state)
    end
    if files_changed then
        self:refilter()
    end
end

--- Put the cursor where `state.focus` says it belongs.
function Picker:apply_focus()
    if self.closed or not window.valid(self.windows) then
        return
    end

    self.applying_focus = true
    if self.state.focus == "list" then
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(self.windows.results_win)
    else
        vim.api.nvim_set_current_win(self.windows.prompt_win)
        local row = self.state.focus == "grep" and 1 or 2
        local line = vim.api.nvim_buf_get_lines(self.windows.prompt_buf, row - 1, row, false)[1] or ""
        vim.api.nvim_win_set_cursor(self.windows.prompt_win, { row, #line })
        vim.cmd("startinsert!")
    end
    self.applying_focus = false

    render.prompt(self.windows, self.state)
end

--- Move the cursor one stop through the prompt rows and the result list.
---@param direction 1|-1 positive moves up the screen
function Picker:move_cursor(direction)
    state_mod.move_cursor(self.state, direction)
    self:apply_focus()
    render.results(self.windows, self.state)
    -- Unlike a plain focus change, this can land on a different entry.
    self.preview_debounced()
end

---@param delta integer positive moves toward better matches, i.e. up the screen
function Picker:move_selection(delta)
    state_mod.move_selection(self.state, delta)
    render.results(self.windows, self.state)
    self.preview_debounced()
end

---@param index integer
function Picker:select(index)
    self.state.selection = math.max(1, math.min(math.max(#self.state.entries, 1), index))
    state_mod.clamp_scroll(self.state)
    render.results(self.windows, self.state)
    self.preview_debounced()
end

-- keys and events ------------------------------------------------------------

---@param modes string[]
---@param lhs string|string[]
---@param buf integer
---@param callback fun()
local function map(modes, lhs, buf, callback)
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
        if key and key ~= "" then
            vim.keymap.set(modes, key, callback, { buffer = buf, nowait = true, silent = true })
        end
    end
end

function Picker:setup_keymaps()
    local keys = self.config.keymaps
    local prompt, results = self.windows.prompt_buf, self.windows.results_buf

    for _, buf in ipairs({ prompt, results }) do
        local modes = buf == prompt and { "i", "n" } or { "n" }

        map(modes, keys.close, buf, function()
            self:close()
        end)
        map(modes, keys.cursor_up, buf, function()
            self:move_cursor(1)
        end)
        map(modes, keys.cursor_down, buf, function()
            self:move_cursor(-1)
        end)
        map(modes, keys.next_item, buf, function()
            self:move_selection(1)
        end)
        map(modes, keys.prev_item, buf, function()
            self:move_selection(-1)
        end)
        map(modes, keys.open, buf, function()
            actions.open(self, "edit")
        end)
        map(modes, keys.split, buf, function()
            actions.open(self, "split")
        end)
        map(modes, keys.vsplit, buf, function()
            actions.open(self, "vsplit")
        end)
        map(modes, keys.tabedit, buf, function()
            actions.open(self, "tabedit")
        end)
        map(modes, keys.quickfix, buf, function()
            actions.quickfix(self)
        end)
        map(modes, keys.toggle_hidden, buf, function()
            actions.toggle_hidden(self)
        end)
        map(modes, keys.scroll_preview_down, buf, function()
            self:scroll_preview(1)
        end)
        map(modes, keys.scroll_preview_up, buf, function()
            self:scroll_preview(-1)
        end)
    end

    -- `j`/`k` follow the screen, not the ranking: the best match is the bottom
    -- row, so `j` walks toward it. They stay inside the list where the arrow
    -- keys now step out of it, which is the point of keeping both.
    map({ "n" }, "j", results, function()
        self:move_selection(-1)
    end)
    map({ "n" }, "k", results, function()
        self:move_selection(1)
    end)
    map({ "n" }, "gg", results, function()
        self:select(#self.state.entries)
    end)
    map({ "n" }, "G", results, function()
        self:select(1)
    end)
end

function Picker:setup_autocmds()
    self.augroup = vim.api.nvim_create_augroup("MicroscopePicker" .. self.id, { clear = true })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = self.augroup,
        buffer = self.windows.prompt_buf,
        callback = function()
            if not self.updating_prompt then
                self:on_prompt_changed()
            end
        end,
    })

    -- Moving between the two prompt lines by any means switches the field.
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = self.augroup,
        buffer = self.windows.prompt_buf,
        callback = function()
            if self.applying_focus or self.closed or self.state.focus == "list" then
                return
            end
            local row = vim.api.nvim_win_get_cursor(self.windows.prompt_win)[1]
            local field = row == 1 and "grep" or "files"
            if field ~= self.state.focus then
                self.state.focus = field
                render.prompt(self.windows, self.state)
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        group = self.augroup,
        callback = function()
            if self.closed then
                return
            end
            local computed = window.relayout(self.windows, self.config)
            self.state.height = computed.results_height
            self.state.width = computed.results_width
            state_mod.clamp_scroll(self.state)
            self:redraw()
        end,
    })

    -- Any move to a window outside the picker dismisses it, which covers
    -- <C-w> motions, :qa, mouse clicks and anything else we did not map.
    vim.api.nvim_create_autocmd("WinEnter", {
        group = self.augroup,
        callback = function()
            vim.schedule(function()
                if self.closed then
                    return
                end
                local current = vim.api.nvim_get_current_win()
                local ours = {
                    self.windows.prompt_win,
                    self.windows.results_win,
                    self.windows.preview_win,
                }
                if not vim.tbl_contains(ours, current) then
                    self:close()
                end
            end)
        end,
    })
end

M.Picker = Picker

return M
