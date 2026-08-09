# microscope.nvim

One picker with two query fields: narrow the files, then search inside them.

```
╭─ 47 matches ───────────╮╭─ src/core.lua ───────────────╮
│  src/ui.lua:104   :set ││  10 local M = {}             │
│  src/ui.lua:31    setu ││  11                          │
│  src/core.lua:88  .set ││  12 function M.setup(opts)   │
│❯ src/core.lua:12  M.se ││  13   opts = opts or {}      │
╰────────────────────────╯╰──────────────────────────────╯
╭─ microscope ─────────────────────────────────────────╮
│ grep  ❯ setup                                        │
│ files ❯ src/*.lua                                    │
╰──────────────────────────────────────────────────────╯
```

Because a blank field means "no restriction", one picker covers three jobs:

| files | grep | what you get |
| ----- | ---- | ------------ |
| blank | blank | every file — a plain file finder |
| set | blank | the narrowed file list |
| blank | set | grep across everything — a plain live grep |
| set | set | grep inside the narrowed file list |

The results list grows **upward** from the prompt, so the best match always sits
on the row nearest where you are typing.

## Requirements

- Neovim 0.10+
- [ripgrep](https://github.com/BurntSushi/ripgrep) on `PATH`

No Lua dependencies — not even plenary.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "davidlai3/microscope.nvim",
    config = function()
        require("microscope").setup({})
    end,
}
```

Don't lazy-load it on `cmd` or `keys` unless you also move the bindings out of
`config`: `setup()` is what registers them, so deferring it leaves `<leader>ff`
unbound until something else pulls the plugin in.

To work on a local checkout instead, point lazy at the directory — the name still
has to match so `require("microscope")` resolves:

```lua
{
    "davidlai3/microscope.nvim",
    dir = "~/Coding/microscope.nvim",
    config = function()
        require("microscope").setup({})
    end,
}
```

`setup()` binds `<leader>ff` (files field focused) and `<leader>fg` (grep field
focused). Both open the same window, so muscle memory carries over from either.
Pass `default_binds = false` to wire your own.

## Keys

| Key | Action |
| --- | ------ |
| `<Tab>` `<Up>` / `<S-Tab>` `<Down>` | move the cursor up / down one row, through the prompt and every result: files → grep → best match → … → worst match → round to files |
| `<C-n>` / `<C-p>` | next / previous match, without leaving the prompt |
| `j` / `k` | in the result list, move down / up the screen without leaving it |
| `<CR>` | open |
| `<C-x>` / `<C-v>` / `<C-t>` | open in a split / vertical split / tab |
| `<C-q>` | send all current results to the quickfix list |
| `<C-h>` | toggle hidden and `.gitignore`d files |
| `<C-d>` / `<C-u>` | scroll the preview |
| `<Esc>` / `<C-c>` | close |

## Query syntax

**files** is fuzzy by default, so `lumicini` finds `lua/microscope/init.lua`. It
switches to gitignore-style globs as soon as it contains `*`, `?`, `[`, `{`, or
starts with `!`:

```
*.lua              every Lua file, at any depth
src/**/*.ts        TypeScript under src/
lua/               everything under lua/
*.{md,txt}         either extension
*.lua !tests/*     Lua files, excluding tests/
```

**grep** is a ripgrep regex with smart case: lowercase matches
case-insensitively, any capital makes it case-sensitive.

Searches always cover Neovim's current working directory and respect
`.gitignore`. A line is listed once no matter how many times the pattern occurs
on it, and the result jumps to the first match on that line.

## Configuration

`setup()` takes any subset of these; anything omitted keeps its default.

```lua
require("microscope").setup({
    layout = {
        width = 0.85,           -- fraction of the editor, or an absolute count
        height = 0.85,
        preview_width = 0.55,   -- share of the box the preview takes
        max_results_height = nil,
    },
    preview = {
        enabled = true,
        max_filesize = 1024 * 1024,
        treesitter = false,     -- regex syntax only; cheaper on large files
    },
    rg = {
        hidden = false,
        no_ignore = false,
        extra_args = {},        -- added to every ripgrep invocation
    },
    debounce = { grep = 80, preview = 60, stream = 60 },
    limits = {
        max_results = 20000,
        explicit_path_threshold = 2000,
        argv_chunk_bytes = 100 * 1024,
    },
    keymaps = { ... },          -- see lua/microscope/config.lua
    default_binds = true,
})
```

Highlight groups all link to standard groups and can be overridden: see
`lua/microscope/ui/highlight.lua`.

## How it stays fast

- The file list comes from one `rg --files` per directory and is **cached**, so
  reopening is instant. `:MicroscopeRefresh` (or `<C-h>`) drops the cache.
- Typing in the **files** field never spawns a process while the file set is
  large — it filters the cached list in memory with `matchfuzzypos`, and an
  extended query re-filters the previous result set rather than the whole list.
- Grep output is **bucketed by path** as it streams in, so narrowing the file
  set walks the (small) path list rather than the (large) match list.
- Once the file set is small enough (`explicit_path_threshold`), ripgrep is
  given those paths directly. That is exact and dodges the result cap, at the
  cost of re-running when the file set changes — cheap at that size.
- `--max-columns` is always on. Without it, one minified file turns a common
  query into gigabytes of output; a real 5,761-file tree went from 2.5 GB to
  7 MB.

## Commands

- `:Microscope [files|grep]` — open, focusing the given field
- `:MicroscopeRefresh` — drop the cached file lists

## Tests

```sh
nvim -l tests/run.lua          # everything
nvim -l tests/run.lua filter   # one spec
```
