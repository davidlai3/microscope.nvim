if vim.g.loaded_microscope then
    return
end
vim.g.loaded_microscope = true

if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("microscope.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
    return
end

vim.api.nvim_create_user_command("Microscope", function(opts)
    require("microscope").open({
        focus = opts.args ~= "" and opts.args or "files",
    })
end, {
    nargs = "?",
    complete = function()
        return { "files", "grep" }
    end,
    desc = "Open microscope, focusing the given field",
})

vim.api.nvim_create_user_command("MicroscopeRefresh", function()
    require("microscope").refresh()
    vim.notify("microscope: file list cache cleared")
end, { desc = "Drop microscope's cached file lists" })
