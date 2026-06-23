# notes.nvim — Developer Guide

## Project overview

A self-contained Neovim plugin written in pure Lua. No external plugin dependencies. Requires Neovim ≥ 0.10.

## Repository layout

```
notes.nvim/
  lua/
    notes/
      init.lua   — public API: setup(), open(), close(), toggle(); config; state
      git.lua    — async git operations (clone, pull, commit, push) via vim.system
      tree.lua   — file tree: scan, render, buffer-local keymaps
      ui.lua     — floating window geometry, open, close, nav keymaps
  README.md
  CLAUDE.md
```

## Architecture

### Module dependency graph

```
init.lua  ──requires──▶  git.lua
          ──requires──▶  ui.lua
          ──requires──▶  tree.lua
tree.lua  ──requires──▶  notes (init)   [for config/state]
          ──requires──▶  notes.ui       [set_nav_keymaps]
ui.lua    ──requires──▶  notes (init)   [for config/state]
          ──requires──▶  notes.tree     [attach keymaps]
git.lua   ──requires──▶  notes (init)   [for config]
```

### State (`init.lua → M.state`)

All mutable runtime state lives in one table in `init.lua`. Sub-modules access it via `require('notes').state`. Never cache the state table in a local variable at module load time — always call `require('notes').state` inside functions to get the live reference.

```lua
M.state = {
  synced    = false,   -- pull already ran this session; prevents duplicate pulls
  closing   = false,   -- re-entrancy guard for close()
  tree_win  = nil,     -- window id of the tree float
  tree_buf  = nil,     -- buffer id of the tree float
  edit_win  = nil,     -- window id of the editor float
  edit_buf  = nil,     -- buffer id of the editor float
  cut_node  = nil,     -- node staged by x, consumed by p
  nodes     = nil,     -- array: index = line number in tree_buf → node table
  expanded  = {},      -- path → true for expanded directories
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()`. Sub-modules read config through `require('notes').config` (never cached at module load).

### File tree (`tree.lua`)

- `scan()` — reads `config.dir` with `vim.fs.dir`. Builds a flat array of `node` tables representing the visible tree (directories first, then root-level files). If a directory is in `state.expanded`, its `.md` children are inserted inline. Skips hidden entries (`.` prefix) and non-`.md` files.
- `render()` — calls `scan()`, builds line strings, writes them into `state.tree_buf` (temporarily sets `modifiable = true`), stores the node array in `state.nodes`. Line `n` → `state.nodes[n]`.
- `attach(buf)` — sets buffer-local keymaps: `<CR>`, `a`, `d`, `x`, `p`, `R`, `q`, `<Esc>`.
- `target_dir(node)` — resolves where create/paste should land: if cursor is on a directory → that directory; if on a file → its parent; if nil → `config.dir`.

**One-level nesting rule:** directories are created with `vim.fn.mkdir` **at the root** only (the `a` handler strips the trailing `/` and always uses `config.dir` as the base). Files can be created inside any visible directory.

### Floating windows (`ui.lua`)

- `open()` — computes `W`, `H`, `row`, `col` from screen dimensions and config fractions. Creates tree float (left) and editor float (right) via `nvim_open_win`. Sets up `WinClosed` autocmd so closing either float triggers `notes.close()`.
- `close()` — saves the editor buffer if modified (`:silent write`), closes both windows via `nvim_win_close`, resets all state pointers.
- `set_nav_keymaps(buf)` — adds `<C-h>` (go to tree) and `<C-l>` (go to editor) to any buffer, guarded by win validity checks.

### Git sync (`git.lua`)

All git commands run via `vim.system` (non-blocking). Callbacks are always wrapped in `vim.schedule` because `vim.system` callbacks fire outside the main loop.

Key design decision: **no explicit branch in pull/push**. Using `git pull --rebase` and `git push` (without `origin <branch>`) relies on the upstream tracking ref that `git clone` sets automatically. This avoids breakage when the user's `init.defaultBranch` differs from the hardcoded branch name.

Flow for `sync_on_exit()`:
1. `git status --porcelain` → if empty stdout, nothing to do.
2. `git add -A`
3. `git commit -m "notes: YYYY-MM-DD HH:MM"`
4. `git push`

Each step is guarded: if any step fails, a WARN/ERROR notification is shown and the chain stops.

`ensure_repo()` handles three cases:
- `.git` exists → call `cb()` immediately.
- `repo == ''` → just `mkdir` the directory and call `cb()`.
- Otherwise → `git clone <repo> <dir>` then call `cb()`.

## Code style

- Two-space indent, single quotes, 100-column line width (matches project's `.stylua.toml`).
- No comments explaining *what* code does. Comments only for non-obvious *why* (hidden constraints, workarounds).
- Russian comments are acceptable (author's preference).
- No error handling for impossible paths. Trust Neovim API guarantees.
- No backwards-compat shims or feature flags.

## How to load the plugin locally (for development)

In `~/.config/nvim/lua/plugins/init.lua`, add the local path before setup:

```lua
vim.pack.add({ src = '/Users/dmitry/Sites/my/notes.nvim' })

require('notes').setup({
  dir  = vim.fn.expand('~/notes'),
  repo = 'git@github.com:lgick/notes.git',
  width = 0.8,
  height = 0.8,
})
```

## Testing

The plugin has no automated test suite. Verification is done manually or with headless nvim:

```bash
# module load smoke test
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua print(require('notes').config.dir)" \
  -c "qa!"

# tree render
mkdir -p /tmp/notes-test/work && echo '# hi' > /tmp/notes-test/hi.md
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua require('notes.ui').open(); require('notes.tree').render()" \
  -c "lua local b=require('notes').state.tree_buf; for _,l in ipairs(vim.api.nvim_buf_get_lines(b,0,-1,false)) do print(l) end" \
  -c "qa!"
```

## Common pitfalls

- **`st.expanded[path] = not st.expanded[path] or nil`** — sets `nil` (removes key) when toggling off, which keeps the table clean. `= false` would leave a falsy key that still counts as "exists" in `pairs()`.
- **`state.closing = true` guard** — `WinClosed` fires for both windows when we close them programmatically. Without the guard, `close()` would recurse.
- **`vim.schedule` in git callbacks** — `vim.system` callbacks run in a libuv thread. Any nvim API call from there must be deferred with `vim.schedule`.
