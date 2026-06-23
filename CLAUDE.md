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

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`toggle_dir`, `open_file`, `create_file`, `create_dir`, `delete`, `cut`, `paste`, `refresh`, `open_github`, `close`, `window_nav`). The `close` default `<C-[>` is byte-identical to `<Esc>` in the terminal — Neovim cannot tell them apart, so `<Esc>` in normal mode also closes notes.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`, dispatching `h`/`k` → tree and `l`/`j` → editor. This avoids the `timeoutlen` delay/flakiness that separate `<C-w>h` / `<C-w>l` maps suffer from (Neovim waits to disambiguate the `<C-w>` prefix against other mappings).

### File tree (`tree.lua`)

- `scan()` — reads `config.dir` with `vim.fs.dir`. Builds a flat array of `node` tables representing the visible tree (directories first, then root-level files). If a directory is in `state.expanded`, its `.md` children are inserted inline. Skips hidden entries (`.` prefix) and non-`.md` files.
- `render()` — calls `scan()`, builds line strings, writes them into `state.tree_buf` (temporarily sets `modifiable = true`), stores the node array in `state.nodes`. Line `n` → `state.nodes[n]`. Then clears and re-applies per-line highlights in the module-local namespace `ns`: `NotesDir` / `NotesFile` by node type, `NotesCut` for the node matching `state.cut_node.path`.
- `toggle_dir()` (`o`) toggles `state.expanded` for a directory node; `open_selected()` (`<CR>`) opens a file node via `open_file()`. They are split so `<CR>` never toggles folders and `o` never opens files.
- `create_file()` (`a`) prompts via `vim.ui.input` with a `default` of the first free `new.md` / `new1.md` / … in `target_dir`. `create_dir()` (`A`) prompts for a folder name and `mkdir`s it at the root.
- `attach(buf)` — sets buffer-local keymaps for the tree-only actions, reading lhs from `config.keys`. Close + panel-focus keys are NOT set here; they live in `ui.set_nav_keymaps` (attached to both buffers).
- `target_dir(node)` — resolves where create/paste should land: if cursor is on a directory → that directory; if on a file → its parent; if nil → `config.dir`.

**One-level nesting rule:** directories are created with `vim.fn.mkdir` **at the root** only (`create_dir` always uses `config.dir` as the base). Files can be created inside any visible directory.

### Floating windows (`ui.lua`)

- `open()` — computes `W`, `H`, `row`, `col` from screen dimensions and config fractions. Calls `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut` with `default = true`, so user overrides win). Creates tree float (left, titled ` Notes `) and editor float (right, **no title** until a file is opened) via `nvim_open_win`. Registers autocmds (see below).
- `set_edit_title(path)` — updates the editor float's title to `path` relative to `config.dir` (e.g. `/folder/name.md`); pass `nil` to clear it. Called by `tree.open_file`. Note: `title_pos` may only be set together with a non-empty `title`, so the clear path sets just `title = ''`.
- `close()` — saves the editor buffer if modified (`:silent write`), closes both windows via `nvim_win_close`, resets all state pointers.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) and `close` (default `<C-[>`) keymaps to a buffer, from `config.keys`. The `window_nav` handler reads the next char via `getcharstr` and focuses the tree (`h`/`k`) or editor (`l`/`j`) with explicit `nvim_set_current_win` (no spatial float navigation, no `timeoutlen` delay). Attached to **both** the tree and editor buffers so navigation and closing work from either window.

`setup_autocmds(st)` registers three autocmds in the `NotesWin` group:
- `WinClosed` → closing either float triggers `notes.close()` (guarded by `st.closing`).
- `BufWritePost` (pattern `config.dir .. '/*'`) → git sync on `:w`. Skipped when `st.closing` is true, because `close()` already writes the buffer and then syncs once itself — without the guard the two chains race and the second `git commit` errors with "nothing to commit".
- `WinEnter` → if notes is open and focus lands in a **non-floating** window outside the two floats, schedules a jump back (prefers `edit_win`). The non-floating check keeps `vim.ui.input` / notification floats from being hijacked.

### Git sync (`git.lua`)

All git commands run via `vim.system` (non-blocking). Callbacks are always wrapped in `vim.schedule` because `vim.system` callbacks fire outside the main loop.

Key design decision: **no explicit branch in pull/push**. Using `git pull --rebase --autostash` and `git push` (without `origin <branch>`) relies on the upstream tracking ref that `git clone` sets automatically. This avoids breakage when the user's `init.defaultBranch` differs from the hardcoded branch name. `--autostash` keeps the pull from failing when the working tree has uncommitted changes (it stashes them before the rebase and re-applies after).

`sync_on_exit()` runs in two places: from `notes.close()` (on `<C-[>`) and from the `BufWritePost` autocmd (on `:w`). Flow:
1. `git status --porcelain` → if empty stdout, fall through to the unpushed-commits check.
2. `git add -A`
3. `git commit -m "notes: YYYY-MM-DD HH:MM"`
4. `git push`

Each step is guarded: if any step fails, a WARN/ERROR notification is shown and the chain stops.

`restore()` runs on **every** open (before pull), independent of `repo`. It runs `git ls-files --deleted -z` and, for any tracked file missing from the working tree, `git checkout -- <files>` to bring it back from the last commit. Rationale: the plugin commits all of its own edits, so an uncommitted *deletion* at open time is accidental (e.g. `rm` in the shell) and must not propagate to the remote on the next push. Only deletions are restored — modified-but-uncommitted tracked files are left alone so real edits survive. `-z` avoids path quoting so Cyrillic/space filenames work.

A companion guard in `ui.lua`'s `BufWritePost`: it skips sync while `state.synced` is false, so an early `:w` during the async open/restore/pull window can't commit a dirty tree before restore finishes.

`open_github()` (bound to `O` in the tree) converts `config.repo` to a browsable `https://host/user/repo` URL (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`.

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
