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
      picker.lua — flat list: scan, filter, render, CRUD actions, buffer-local keymaps
      ui.lua     — three stacked floats: geometry, open, close, open_in_edit, nav keymaps
  README.md
  CLAUDE.md
```

## Architecture

### Module dependency graph

```
init.lua    ──requires──▶  git.lua
            ──requires──▶  ui.lua
            ──requires──▶  picker.lua
picker.lua  ──requires──▶  notes (init)   [for config/state]
            ──requires──▶  notes.ui       [open_in_edit]
ui.lua      ──requires──▶  notes (init)   [for config/state]
            ──requires──▶  notes.picker   [attach keymaps, live filter, populate]
git.lua     ──requires──▶  notes (init)   [for config]
```

### State (`init.lua → M.state`)

All mutable runtime state lives in one table in `init.lua`. Sub-modules access it via `require('notes').state`. Never cache the state table in a local variable at module load time — always call `require('notes').state` inside functions to get the live reference.

```lua
M.state = {
  synced       = false,  -- pull already ran this session; prevents duplicate pulls
  closing      = false,  -- re-entrancy guard for close()
  input_win    = nil,    -- window id of the search float
  input_buf    = nil,    -- buffer id of the search float
  list_win     = nil,    -- window id of the list float
  list_buf     = nil,    -- buffer id of the list float
  edit_win     = nil,    -- window id of the editor float
  edit_buf     = nil,    -- buffer id of the editor float (swapped on open_in_edit)
  current_file = nil,    -- path of the file currently open in the editor
  all_items    = nil,    -- full scan: array of { file, rel, mtime }
  items        = nil,    -- filtered array; list line n → items[n]
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `next`, `prev`, `create_file`, `delete`, `rename`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`). `config.list_height` sets the list window's content height in rows. The `close` default `<C-[>` is byte-identical to `<Esc>` in the terminal — Neovim cannot tell them apart, so `<Esc>` also closes notes.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. Navigation is **strictly ordered** across the three stacked windows (search → list → editor): only `j` (one window down) and `k` (one window up) are accepted, no skipping and no other keys. It finds the current window's index in `{ input, list, edit }` and moves ±1. This avoids the `timeoutlen` delay/flakiness that separate `<C-w>j` / `<C-w>k` maps suffer from. It is mapped in both `n` and `i` modes (the search window lives in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer; landing on the search window re-enters insert.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`) from the search or list window without moving focus. Mapping them in the search buffer's insert mode also suppresses the native `<C-n>`/`<C-p>` keyword completion (no autocompletion popup in search).

### Flat list (`picker.lua`)

- `scan()` — recursively walks `config.dir` with `vim.fs.dir`. Builds a flat array `{ file, rel, mtime }` of **every** file at any depth (any extension, not just `.md`). Skips hidden entries (`.` prefix, which also excludes `.git`). Sorts by `mtime` descending (most recent first). Stored in `state.all_items`.
- `filter(query)` — case-insensitive substring match of `query` against each item's `rel` path (`find(query, 1, true)`); empty query keeps everything. Result → `state.items`.
- `render_list()` — writes `item.rel` lines into `state.list_buf` (temporarily `modifiable = true`, then back to `false`). Empty result renders `(нет совпадений)`. Re-applies the `NotesFile` highlight per line in the module-local namespace `ns`, and resets the list cursor to line 1 (selection visibility + reset after filtering).
- `populate()` = `scan` + `filter('')` + `render_list`; `refresh()` (`R`) is the same but preserves the current search text. `populate` runs on open and after each git step; `refresh` re-reads the directory on demand.
- **Selection = `list_win` cursor.** `selected()` reads `nvim_win_get_cursor(list_win)[1]` and indexes `state.items`. There is no separate selection highlight — the list window's `cursorline` shows it. `move(delta)` (called from the search box via `next`/`prev`) clamps and moves that cursor remotely.
- `open_selected()` (`<CR>`) → `ui.open_in_edit(item.file)`. It opens the file **without moving focus** — the cursor stays in the search/list window.
- CRUD actions, all relative to `config.dir`: `create_file()` (`a`) is the single create entry — it prompts with a `default` of the first free `new.txt`/`new1.txt`/… and accepts a **relative path**; a trailing `/` makes it a folder (`mkdir -p`), otherwise a missing extension defaults to `.txt`, the parent is `mkdir -p`'d, an **existing file is not truncated** (just opened), and the new file is opened in the editor. (There is no separate `create_dir`/`A`.) `delete()` (`d`) confirms then `fn.delete(file, 'rf')`. `rename()` (`r`) prompts with `default = item.rel`; the new relative path can drop or change the folder, so it doubles as **move** (e.g. `work/todo.md` → `todo.md` moves to root). Each action ends with `populate()`.
- `attach_input(buf)` — `{ 'i', 'n' }` keymaps for `next`/`prev`/`<Down>`/`<Up>` (move selection), `open_file` (open file, focus stays), `scroll_down`/`scroll_up` (scroll editor), and `close`. `attach_list(buf)` — normal-mode keymaps for `open_file`, the CRUD actions, `scroll_down`/`scroll_up`, and `close`. The `window_nav` prefix is added separately by `ui.set_nav_keymaps` to all three buffers; the editor buffer also gets a normal-mode `close` map in `open_in_edit`.

**Nesting:** files and folders may live at any depth — `scan` is recursive and the list shows full `folder/sub/name.ext` paths. Create/rename take a relative path, so there is no root-only restriction.

### Floating windows (`ui.lua`)

Three floats stacked vertically as one centered overlay: **search** (top, 1 row, titled ` Search `), **list** (middle, `config.list_height` rows, titled ` Notes `), **editor** (bottom, remaining height, **no title** until a file is opened). All titles use `title_pos = 'left'`.

- `layout()` — computes geometry from `config.width/height` and screen size. A `rounded` border adds +1 row top/bottom and +1 col each side (footprint = content + 2); `nvim_open_win`'s `width/height` are content. Each window's content `row` = its footprint top + 1. The list height is clamped to leave ≥1 content row for the editor. Returns the three config tables (the editor table omits `title`).
- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut` with `default = true`), creates the three scratch buffers + windows from `layout()`, sets window options (search/list: no number, `signcolumn=no`; list: `cursorline=true`; editor seeded with a hint line), attaches `picker.attach_input`/`attach_list` and `set_nav_keymaps` to all three buffers, registers autocmds, and `startinsert` (focus the search box).
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file` and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=yes`). **Fix #2:** it does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close` map to the new buffer and sets the title. It **does not move focus** — opening a file (`<CR>`) leaves the cursor in the search/list window.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the search and list buffers.
- `set_edit_title(path)` — sets the editor float's title (`title_pos = 'left'`) to `path` relative to `config.dir` (e.g. `/folder/name.md`); `nil` clears it. Note: `title_pos` may only be set with a non-empty `title`, so the clear path sets just `title = ''`.
- `close()` — saves the editor buffer if it's a real modified file (`:silent write`), closes all three windows, resets every `*_win`/`*_buf`, `current_file`, `items`, `all_items`.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and moves **one window** along `{ input, list, edit }`: `j` down, `k` up (no skipping, no other keys), re-entering insert when it lands on the search window.

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing any of the three floats triggers `notes.close()` (guarded by `st.closing`).
- `TextChangedI`/`TextChanged` on `input_buf` → live filter: `picker.filter(text)` + `picker.render_list()`.
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → git sync on `:w`. Skipped when `st.closing` is true (close() already writes + syncs once; without the guard the two chains race and the second `git commit` errors "nothing to commit"), and while `st.synced` is false.
- `VimResized` → if open, recompute `layout()` and `nvim_win_set_config` each valid window; the editor table has no `title`, so `set_edit_title(current_file)` is re-applied (**fix #4**).
- `WinEnter` → if notes is open and focus lands in a **non-floating** window outside the three floats, schedules a jump back (prefers `edit_win`). The non-floating check keeps `vim.ui.input` / notification floats from being hijacked.

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

`open_github()` (bound to `O` in the list) converts `config.repo` to a browsable `https://host/user/repo` URL (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`.

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

# list render (recursive scan, any extension, recent first)
mkdir -p /tmp/notes-test/work
printf '# hi\n'  > /tmp/notes-test/work/todo.md
printf 'plain\n' > /tmp/notes-test/ideas.txt
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua require('notes.ui').open(); require('notes.picker').populate()" \
  -c "lua local b=require('notes').state.list_buf; for _,l in ipairs(vim.api.nvim_buf_get_lines(b,0,-1,false)) do print(l) end" \
  -c "qa!"
# expect: ideas.txt and work/todo.md
```

## Common pitfalls

- **Do not pin `StatusLine`/`CursorLineNr` in the editor's `winhighlight`** — the user's global `UpdateInsertModeColor` (`InsertEnter`/`InsertLeave`) remaps those groups via the *current window's* `winhighlight`. Pinning them in the plugin would shadow that and break insert-mode recoloring. `open_in_edit` only sets plain window options (`number`/`cursorline`/`signcolumn`/…) and leaves `winhighlight` alone (fix #2).
- **Selection is the `list_win` cursor**, not stored state. Read it with `nvim_win_get_cursor(list_win)[1]` → `state.items[n]`; move it remotely from the search box with `nvim_win_set_cursor`. `cursorline` provides the visual; there is no selection highlight group.
- **`state.closing = true` guard** — `WinClosed` fires for every window when we close them programmatically. Without the guard, `close()` would recurse.
- **`vim.schedule` in git callbacks** — `vim.system` callbacks run in a libuv thread. Any nvim API call from there must be deferred with `vim.schedule`.
