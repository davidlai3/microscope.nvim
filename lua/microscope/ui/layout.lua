--- Floating window geometry.
---
--- Pure arithmetic, so it can be unit-tested without opening anything. All rects
--- are *outer* rectangles: they include the border cells. `ui/window.lua`
--- converts them to the content-relative coordinates `nvim_open_win` wants.
---
--- The box is laid out from the bottom up, matching how the picker reads:
---
---     ┌──────────┬──────────┐
---     │ results  │ preview  │   <- fills the remaining height
---     ├──────────┴──────────┤
---     │ grep  ❯             │   <- prompt, always 2 text rows
---     │ files ❯             │
---     └─────────────────────┘

local M = {}

M.MIN_WIDTH = 40
M.MIN_HEIGHT = 10
--- Below this total width a side-by-side preview leaves the results unreadable.
M.MIN_PREVIEW_WIDTH = 80

M.PROMPT_ROWS = 2
--- Prompt text rows plus its top and bottom border.
M.PROMPT_OUTER_HEIGHT = M.PROMPT_ROWS + 2

---@class microscope.Rect
---@field row integer 0-based screen row of the top border
---@field col integer 0-based screen column of the left border
---@field width integer including both border columns
---@field height integer including both border rows

---@class microscope.Layout
---@field results microscope.Rect
---@field preview microscope.Rect|nil
---@field prompt microscope.Rect
---@field results_height integer usable text rows in the results window

---@param value number a fraction of `total`, or an absolute cell count if >= 1
---@param total integer
---@return integer
local function resolve(value, total)
    if value <= 1 then
        return math.floor(total * value + 0.5)
    end
    return math.floor(value)
end

--- Compute the geometry for one picker.
---@param opts { columns: integer, lines: integer, config: table }
---@return microscope.Layout
function M.compute(opts)
    local config = opts.config
    local columns, lines = opts.columns, opts.lines

    local width = math.max(M.MIN_WIDTH, math.min(columns, resolve(config.layout.width, columns)))
    local height = math.max(M.MIN_HEIGHT, math.min(lines, resolve(config.layout.height, lines)))

    local row = math.max(0, math.floor((lines - height) / 2))
    local col = math.max(0, math.floor((columns - width) / 2))

    local top_height = height - M.PROMPT_OUTER_HEIGHT
    local results_height = top_height - 2

    if config.layout.max_results_height then
        local capped = math.min(results_height, config.layout.max_results_height)
        -- Shrinking the list moves the whole box down so the prompt stays put.
        row = row + (results_height - capped)
        results_height = capped
        top_height = results_height + 2
        height = top_height + M.PROMPT_OUTER_HEIGHT
    end

    local show_preview = config.preview.enabled and width >= M.MIN_PREVIEW_WIDTH
    local results_width = width
    local preview = nil

    if show_preview then
        local preview_width = resolve(config.layout.preview_width, width)
        preview_width = math.max(20, math.min(width - 20, preview_width))
        results_width = width - preview_width
        preview = { row = row, col = col + results_width, width = preview_width, height = top_height }
    end

    return {
        results = { row = row, col = col, width = results_width, height = top_height },
        preview = preview,
        prompt = {
            row = row + top_height,
            col = col,
            width = width,
            height = M.PROMPT_OUTER_HEIGHT,
        },
        results_height = results_height,
    }
end

--- Current usable editor dimensions, excluding the command line and ruler.
---@return integer columns, integer lines
function M.editor_size()
    local reserved = vim.o.cmdheight + (vim.o.laststatus > 0 and 1 or 0)
    return vim.o.columns, math.max(M.MIN_HEIGHT, vim.o.lines - reserved - 1)
end

--- Convert an outer rect into `nvim_open_win` config for a bordered window.
---@param rect microscope.Rect
---@return table
function M.to_win_config(rect)
    return {
        relative = "editor",
        row = rect.row + 1,
        col = rect.col + 1,
        width = math.max(1, rect.width - 2),
        height = math.max(1, rect.height - 2),
    }
end

return M
