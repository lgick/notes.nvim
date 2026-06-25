# notes.nvim — Developer Guide

## Project overview

A self-contained Neovim plugin written in pure Lua. No external plugin dependencies. Requires Neovim ≥ 0.10.

## Repository layout

```
notes.nvim/
  lua/
    notes/
      init.lua   — public API: setup(), open(), close(), close_interactive(), toggle(); config; state
      git.lua    — async git operations (clone, pull, commit, push) via vim.system
      picker.lua — flat list: scan, filter, render, CRUD actions, buffer-local keymaps
      ui.lua     — three stacked split windows in a tab: open, close, open_in_edit, nav keymaps
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
  tab          = nil,    -- tabpage handle for the notes tab
  input_win    = nil,    -- window id of the search split
  input_buf    = nil,    -- buffer id of the search split
  list_win     = nil,    -- window id of the list split
  list_buf     = nil,    -- buffer id of the list split
  edit_win     = nil,    -- window id of the editor split
  edit_buf     = nil,    -- buffer id of the editor split (swapped on open_in_edit)
  current_file = nil,    -- path of the file currently open in the editor
  all_items    = nil,    -- full scan: array of { file, rel, mtime }
  items        = nil,    -- filtered array; list line n → items[n]
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `next`, `prev`, `create_file`, `delete`, `rename`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`). `config.list_height` sets the list window's content height in rows. The `close` default `<C-[>` is byte-identical to `<Esc>` in the terminal — Neovim cannot tell them apart, so `<Esc>` also closes notes.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. Navigation is **strictly ordered** across the three stacked windows (search → list → editor): only `j` (one window down) and `k` (one window up) are accepted, no skipping and no other keys. It finds the current window's index in `{ input, list, edit }` and moves ±1. This avoids the `timeoutlen` delay/flakiness that separate `<C-w>j` / `<C-w>k` maps suffer from. It is mapped in both `n` and `i` modes (the search window lives in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer; landing on the search window re-enters insert.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) behave differently depending on the focused window: in the **search** buffer they call `move_and_open` (move list cursor + open the selected file, same as `next`/`prev`); in the **list** buffer they scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`). The search buffer sets `vim.b.completion = false` (disables blink.cmp) and `vim.bo.complete = ''` (disables native keyword completion) — no autocompletion popup in search.

### Flat list (`picker.lua`)

- `scan()` — recursively walks `config.dir` with `vim.fs.dir`. Builds a flat array `{ file, rel, mtime }` of **every** file at any depth (any extension, not just `.md`). Skips hidden entries (`.` prefix, which also excludes `.git`). Sorts by `mtime` descending (most recent first). Stored in `state.all_items`.
- `filter(query)` — case-insensitive substring match of `query` against each item's `rel` path (`find(query, 1, true)`); empty query keeps everything. Result → `state.items`.
- `render_list()` — writes `item.rel` lines into `state.list_buf` (temporarily `modifiable = true`, then back to `false`). Empty result renders `(no matches)`. Re-applies highlights in two namespaces: `ns` (`NotesFile` per row + `NotesMatch` on the matched substring from the current search query), then calls `highlight_active()` to mark the open file. Resets the list cursor to line 1 (selection visibility + reset after filtering).
- `highlight_active()` — clears namespace `ns_active` and adds `NotesActive` highlight to the row whose `item.file == state.current_file`. Called from `render_list()` and from `open_selected()` so the highlight stays accurate after navigation without requiring a full re-render.
- `populate()` = `scan` + `filter('')` + `render_list`; `refresh()` (`R`) is the same but preserves the current search text. `populate` runs on open and after each git step; `refresh` re-reads the directory on demand.
- **Selection = `list_win` cursor.** `selected()` reads `nvim_win_get_cursor(list_win)[1]` and indexes `state.items`. The list window's `cursorline` marks the cursor; `NotesActive` (separate namespace) marks the currently open file — they can differ when focus is in search or editor. `move(delta)` clamps and moves that cursor remotely.
- `open_selected()` (`<CR>`) → `ui.open_in_edit(item.file)` + `highlight_active()`. Opens the file **without moving focus**. Also called from the `CursorMoved` autocmd when list_win has focus (auto-open on navigation).
- CRUD actions, all relative to `config.dir`: `create_file()` (`a`) is the single create entry — it prompts with a `default` of the first free `new.txt`/`new1.txt`/… and accepts a **relative path**; a trailing `/` makes it a folder (`mkdir -p`), otherwise a missing extension defaults to `.txt`, the parent is `mkdir -p`'d, an **existing file is not truncated** (just opened), and the new file is opened in the editor. `delete()` (`d`) confirms then `fn.delete(file, 'rf')`. `rename()` (`r`) prompts with `default = item.rel`; the new relative path can drop or change the folder, so it doubles as **move** (e.g. `work/todo.md` → `todo.md` moves to root). **Each CRUD action calls `git.sync_on_exit()` immediately after** — create, delete, and rename all trigger a commit+push without waiting for close.
- `attach_input(buf)` — `{ 'i', 'n' }` keymaps: `next`/`prev`/`<Down>`/`<Up>` and `scroll_down`/`scroll_up` all call `move_and_open` (move list cursor + open selected file); `open_file` opens the selected file; `close` calls `close_interactive()`. `attach_list(buf)` — normal-mode keymaps for `open_file`, the CRUD actions, `scroll_down`/`scroll_up` (scroll editor), and `close`. The `window_nav` prefix is added separately by `ui.set_nav_keymaps` to all three buffers; the editor buffer also gets a normal-mode `close` map in `open_in_edit`.

**Nesting:** files and folders may live at any depth — `scan` is recursive and the list shows full `folder/sub/name.ext` paths. Create/rename take a relative path, so there is no root-only restriction.

### Split windows (`ui.lua`)

Three split windows stacked vertically inside a dedicated tab (`tabnew`): **search** (top, 1 content row, statusline shows ` Search`), **list** (middle, `config.list_height` rows, statusline shows ` Notes`), **editor** (bottom, remaining height, normal statusline showing file info). The search and list windows have `winfixheight = true` so the editor always takes the remaining space.

- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut`/`NotesMatch`/`NotesActive` with `default = true`), runs `tabnew`, places an initial scratch buffer in the base window (editor), then `split = 'above'` to create the list window, then another `split = 'above'` to create the search window above the list. Sets per-window options: `statusline = ' Notes'` / `' Search'` for list and search; `number`/`cursorline`/`signcolumn` for the editor are set in `open_in_edit`. Attaches `picker.attach_input`/`attach_list` and `set_nav_keymaps` to all three buffers, registers autocmds, and `startinsert` (focus the search box).
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file` and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=yes`). Does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close_interactive` map to the new buffer. It **does not move focus** — opening a file (`<CR>`) leaves the cursor in the search/list window.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the search and list buffers.
- `close()` — sets `st.closing = true`, clears all state fields, then calls `tabclose <tabnr>` to close the entire tab. The `st.closing` guard in `WinClosed` prevents recursion when `tabclose` triggers that autocmd for each closing window.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and moves **one window** along `{ input, list, edit }`: `j` down, `k` up (no skipping, no other keys), re-entering insert when it lands on the search window.

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing any of the three windows triggers `notes.close()` (guarded by `st.closing`).
- `CursorMoved` on `list_buf` → if the current window is `list_win`, calls `picker.open_selected()` to auto-open the file under the cursor. The `current_win` guard prevents false triggers when `render_list()` programmatically resets the cursor to line 1 while focus is elsewhere.
- `TextChangedI`/`TextChanged` on `input_buf` → live filter: `picker.filter(text)` + `picker.render_list()`.
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → git sync on `:w`. Skipped when `st.closing` is true and while `st.synced` is false (to avoid committing a dirty tree before the initial restore/pull completes).

### Public API (`init.lua`)

- `is_open()` — checks `state.tab` validity. If the tab was closed externally (e.g. `:tabclose`), self-heals by wiping all stale state fields so old window IDs cannot trigger false autocmd matches on a future session.
- `open()` — guard against double-open; calls `ui.open()` + `picker.populate()`, then kicks off the async git chain (ensure_repo → restore → pull).
- `close()` — calls `ui.close()` then `git.sync_on_exit()`. Does not prompt; safe to call from autocmds.
- `close_interactive()` — checks the editor buffer for unsaved changes. If modified, shows a `confirm()` dialog: **Save** (`:silent write` then close+sync), **Discard** (close+sync without saving), **Cancel** (abort). Bound to the `close` key in all three windows. `toggle()` uses this as well.

### Git sync (`git.lua`)

All git commands run via `vim.system` (non-blocking). Callbacks are always wrapped in `vim.schedule` because `vim.system` callbacks fire outside the main loop.

Key design decision: **no explicit branch in pull/push**. Using `git pull --rebase --autostash` and `git push` (without `origin <branch>`) relies on the upstream tracking ref that `git clone` sets automatically. This avoids breakage when the user's `init.defaultBranch` differs from the hardcoded branch name. `--autostash` keeps the pull from failing when the working tree has uncommitted changes (it stashes them before the rebase and re-applies after).

`sync_on_exit()` is called from: `notes.close()` (on `<C-[>`), the `BufWritePost` autocmd (on `:w`), and immediately after each CRUD action (create, delete, rename).

**Concurrency guard:** two module-level booleans `syncing` / `sync_pending` serialise concurrent calls. If a second call arrives while a chain is in flight, it sets `sync_pending = true` and returns. `finish()` (called at every terminal point of the chain) clears `syncing` and, if `sync_pending` is set, immediately starts one more run — collapsing any number of queued calls into a single follow-up sync. If no follow-up is pending and notes is open, `finish()` calls `picker.refresh()` so any files added or deleted by the pull are immediately reflected in the list.

**Flow when uncommitted changes exist (`git status --porcelain` non-empty):**

```
git fetch origin
  └─ remote ahead of HEAD? (git rev-list HEAD..FETCH_HEAD --count)
       No  → git add -A → git commit → git push
       Yes → git stash push --include-untracked
               └─ git pull --ff-only
                    Fail (histories diverged) → git pull --rebase --autostash → commit → push
                                                                                 Fail → ERROR, abort
                    OK, nothing was stashed   → commit → push
                    OK, stash exists          → git stash pop
                                                   OK       → commit → push
                                                   Conflict → git status --porcelain (collect XY + filename per conflict)
                                                                └─ confirm dialog:
                                                                     Yes → resolve per conflict type:
                                                                             UD/DD (local deleted) → git rm --force (stage deletion)
                                                                             other XY              → git checkout --theirs (restore local)
                                                                           → stash drop → commit → push
                                                                     No  → git reset --hard HEAD + stash drop
                                                                             → :edit! current_file (force-reload buffer from disk)
                                                                             → abort (no commit/push)
                                                                   No conflict markers but pop failed (e.g. untracked filename collision)
                                                                     → stash drop → commit → push
                                                (finish() calls picker.refresh() at all terminal points when notes is open)
```

Fetching **before** committing (not after a failed push) is the key invariant: the local working tree is still uncommitted when the stash/pull/pop runs, so if the pop produces a conflict the user sees a clean "GitHub updated X, push anyway?" dialog rather than a git rebase error.

**Flow when working tree is clean but local commits exist:** `git rev-list @{u}..HEAD --count` → if non-zero (or no upstream), `git push`.

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

- **Do not pin `StatusLine`/`CursorLineNr` in the editor's `winhighlight`** — the user's global `UpdateInsertModeColor` (`InsertEnter`/`InsertLeave`) remaps those groups via the *current window's* `winhighlight`. Pinning them in the plugin would shadow that and break insert-mode recoloring. `open_in_edit` only sets plain window options (`number`/`cursorline`/`signcolumn`/…) and leaves `winhighlight` alone.
- **`statusline` for search/list is per-window** — set via `vim.wo[win].statusline`. Users with a statusline plugin (lualine, etc.) may want to add `NotesSearch` and `NotesList` to that plugin's exclusion list if their plugin overrides per-window statuslines.
- **Selection is the `list_win` cursor**, not stored state. Read it with `nvim_win_get_cursor(list_win)[1]` → `state.items[n]`; move it remotely from the search box with `nvim_win_set_cursor`. `cursorline` provides the visual; there is no selection highlight group.
- **`state.closing = true` guard** — `WinClosed` fires for every window when `tabclose` processes them. Without the guard, the scheduled `notes.close()` call would run for each window and recurse.
- **`state.tab` self-heal in `is_open()`** — if the notes tab is closed externally (`:tabclose`), `state.tab` is stale. `is_open()` detects the invalid tabpage and wipes all state fields so old window IDs cannot cause false matches in the `WinClosed` autocmd on a subsequent open.
- **`vim.schedule` in git callbacks** — `vim.system` callbacks run in a libuv thread. Any nvim API call from there must be deferred with `vim.schedule`.
- **CRUD sync races** — `sync_on_exit()` is called immediately after each CRUD action. Rapid creates/renames/deletes are serialised by the `syncing`/`sync_pending` mutex: at most one git chain runs at a time, and at most one follow-up run is queued. All changes accumulated during the in-flight chain are captured by the single follow-up's `git add -A`.
- **Fetch-before-commit invariant** — `sync_with_remote_then_commit()` always runs `git fetch origin` before `git add -A`. This is critical: if we committed first and then discovered the remote diverged, a `git pull --rebase` on top of the committed change would fail with a conflict. By fetching and reconciling (stash → pull → pop) while the working tree is still uncommitted, any conflict is a simple working-tree conflict that can be resolved with a Yes/No dialog.
- **"No" discard must use `:edit!`, not `open_in_edit`** — after `git reset --hard HEAD`, the editor buffer still holds the old local content and is marked modified. `open_in_edit` writes a modified buffer before `:edit`, which would overwrite the just-reset disk file and undo the discard. The discard path therefore calls `nvim_win_call(edit_win, 'edit! <path>')` directly to force-reload without writing. The subsequent `finish()` call handles `picker.refresh()` universally — do not add a second explicit refresh in the "No" branch.
- **`finish()` always refreshes the list** — `finish()` calls `picker.refresh()` at every terminal point of the sync chain (when no follow-up sync is pending and notes is open). This covers "Yes" conflict resolution, clean stash pop, no-remote-ahead paths, and the "No" discard path. Do not add explicit `picker.refresh()` calls inside the chain; let `finish()` handle it uniformly.
- **`UD`/`DD` conflicts require `git rm`, not `checkout --theirs`** — for `UD` (GitHub modified, local deleted), stage 3 is absent in the merge index. Running `git checkout --theirs -- file` exits with code 1 ("does not have a theirs version") and leaves the conflict unresolved. `git add -A` then silently resolves it as "keep ours" (GitHub content), `git commit` reports "nothing to commit" (message goes to stdout not stderr), and the error surfaces as `git commit failed:` with an empty message. The fix is to use `git rm --force -- file` for `UD`/`DD` entries, which stages the deletion correctly.
- **`do_commit_push` "nothing to commit" is a non-error** — if `git commit` exits non-zero but stdout/stderr contains "nothing to commit", the working tree was already in sync with HEAD. Treat it as success and proceed to `do_push()`. This can happen after untracked-file collision during stash pop (pop fails, stash dropped, `add -A` finds nothing).
- **Always drop the stash in `handle_stash_conflict`** — if `git stash pop` fails but `git status --porcelain` shows no conflict markers (untracked filename collision: "A.txt already exists, no checkout"), the stash is not consumed. The `#conflicts == 0` branch must explicitly `git stash drop` before calling `do_commit_push`, otherwise stashes accumulate across sync calls.
