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
      picker.lua — two-pane model: scan folders+notes, title-from-content, filter, render, CRUD/move, keymaps
      ui.lua     — three windows in a tab (folders | notes + editor): open, close, open_in_edit, show_placeholder, nav keymaps
  README.md
  CLAUDE.md
```

## macOS-Notes model (high level)

The plugin imitates the macOS Notes app:
- **No manual filenames.** Each note is an opaque **ID file** (timestamp `%Y%m%d%H%M%S`, no
  extension). Its **title is the first non-blank line** of its content; an empty note is titled
  `New Note`. The ID never changes on edit, so titles never churn git history or collide.
  The editor opens notes as `markdown`.
- **Two-pane list:** a **folders** column (left) and a **notes** column (right) on top, with the
  editor below. No search box.
- **Folders are one level deep.** The folders column shows the virtual `Notes` (the **root**:
  notes with no folder) plus real folders, sorted so the folder with the most recently edited note
  comes first (`Notes` is always pinned first). Selecting one filters the notes column. Empty
  folders persist via a hidden `.gitkeep`.
- **Notes are sorted** empty-first (pinned top) then by mtime descending; each notes row reads
  `dd.mm.yyyy - <title>` (date is display-only, from mtime).
- **Move by cursor:** `x` marks a note (`NotesCut`), focus jumps to the folders column, `<CR>` on
  a folder (or `Notes` = root) moves it.
- **Same keys per column:** `a` creates (note in the notes column, folder in the folders column),
  `d` deletes; notes also have `x` (move), folders also have `r` (rename).

All user-facing strings (labels, prompts, notifications) are in English; only code comments may
be in Russian (author's preference).

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
  synced         = false, -- pull already ran this session; prevents duplicate pulls
  closing        = false, -- re-entrancy guard for close()
  tab            = nil,   -- tabpage handle for the notes tab
  folders_win    = nil,   -- window id of the folders column
  folders_buf    = nil,   -- buffer id of the folders column
  list_win       = nil,   -- window id of the notes column
  list_buf       = nil,   -- buffer id of the notes column
  edit_win       = nil,   -- window id of the editor split
  edit_buf       = nil,   -- buffer id of the editor split (swapped on open_in_edit)
  current_file   = nil,   -- path of the note currently open in the editor
  current_folder = nil,   -- selected folder name; nil = "Notes" (root notes)
  cut            = nil,   -- path of the note marked for moving (set by `x`)
  folders        = nil,   -- array of { name, folder }; folder nil = the virtual "all" entry
  notes_all      = nil,   -- full scan: array of { file, folder, title, mtime, empty }
  items          = nil,   -- filtered notes for current folder + query; notes line n → items[n]
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `create`, `delete`, `rename`, `move`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`). `create` and `delete` are a single key each, dispatched by column (`create_note`/`delete_note` in the notes column, `create_folder`/`delete_folder` in the folders column). `config.list_height` sets the folders/notes row height in rows; `config.folders_width` sets the folders column width. The `close` default `<C-[>` is byte-identical to `<Esc>` in the terminal — Neovim cannot tell them apart, so `<Esc>` also closes notes.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. The three windows form a 2-D layout, so navigation accepts `h/j/k/l` and dispatches to `vim.cmd('wincmd '..key)` (native spatial move). Reading the char synchronously avoids the `timeoutlen` delay/flakiness that separate `<C-w>h/j/k/l` maps suffer from. It is mapped in both `n` and `i` modes (the editor may be in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) in the **notes** buffer scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`).

### Two-pane model (`picker.lua`)

- `title_of(file)` — reads only the first lines (`fn.readfile(file, '', 20)`) and returns the first non-blank, trimmed line plus `empty=false`; an all-blank/missing file returns `New Note, empty=true`.
- `scan()` — walks `config.dir` with `vim.fs.dir` **one level deep**. Collects real top-level folder names and `state.notes_all` (`{ file, folder, title, mtime, empty }` for every file at the root — `folder=''` — and inside each top-level folder — `folder=<dir name>`). Skips hidden entries (`.` prefix → excludes `.git`/`.gitkeep`). Sorts notes **empty-first, then mtime descending**. Then builds `state.folders`: the virtual root `{ name='Notes', folder=nil }` **pinned first**, then real folders sorted by `folder_mtime` (the mtime of each folder's most recently modified note) descending.
- `filter()` — `target = current_folder or ''`; keeps notes whose `folder == target` (so the root `Notes` shows only `folder==''` notes). Result → `state.items`. No query/search.
- `render_folders()` — writes folder names into `state.folders_buf`; each row gets `NotesDir`, or `NotesActive` for the row matching `current_folder` (namespace `ns_folders`).
- `render_notes()` — writes `os.date('%d.%m.%Y', mtime) .. ' - ' .. title` lines into `state.list_buf`. Empty result renders `(no notes)`. Highlights (namespace `ns`): `NotesFile` per row, `NotesCut` on the `state.cut` row, then `highlight_active()`. Resets the notes cursor to line 1.
- `highlight_active()` — clears `ns_active` and adds `NotesActive` to the row whose `item.file == state.current_file`.
- `populate()` = `scan` + `validate_folder` + `filter` + `render_folders` + `render_notes`. `validate_folder` resets `current_folder` to `nil` if the selected folder vanished. `refresh` is an alias for `populate`; both run on open and after each git step.
- **Note selection = `list_win` cursor**; **folder selection = `folders_win` cursor.** `selected_note()`/`selected_folder()` read each window's cursor and index `state.items`/`state.folders`.
- `select_folder()` — folders-column cursor handler: sets `state.current_folder` to the row's folder and re-filters/re-renders the notes column.
- `open_selected()` (`<CR>` in notes / CursorMoved) → `ui.open_in_edit(item.file)` + `highlight_active()`; **does not move focus**.
- Actions (each calls `git.sync_on_exit()` after a change):
  - `create_note()` (`a`, notes column) — target folder = `current_folder` (or root when `Notes` is selected). If that folder already holds an **empty** note, it is reopened instead of creating a second (one empty note per folder). Otherwise writes an empty **ID file** (`new_id` = `%Y%m%d%H%M%S` + collision counter, no extension) and opens it in the editor **without moving focus** (cursor stays in the notes column).
  - `create_folder()` (`a`, folders column) — `vim.ui.input` name (rejects `/`: folders are one level), `mkdir -p`, writes a hidden `.gitkeep` so the empty folder can commit.
  - `rename_folder()` (`r`, folders column) — refuses the virtual root `Notes` row; `fn.rename`s the directory; if the open note is inside, reopens the editor at the new path and wipes the stale buffer; updates `current_folder` if it was the renamed one.
  - `delete_note()` (`d`, notes column) / `delete_folder()` (`d`, folders column) — `confirm`, then `fn.delete`; if the open note (or, for a folder, a note inside it) is removed, calls `ui.show_placeholder()` so the editor drops the orphaned buffer (avoids `E211`).
  - `cut_note()` (`x`) — sets `state.cut`, re-renders (highlight), and moves focus to the folders column. `folder_enter()` (`<CR>` in folders) drops the marked note into the row's folder (or root) via `fn.rename`, reopening the editor if it was the open note; with no `cut` active it just focuses the notes column.
- `attach_folders(buf)` — normal-mode: `open_file`→`folder_enter`, `create`→`create_folder`, `rename`→`rename_folder`, `delete`→`delete_folder`, `refresh`, `open_github`, `close`. `attach_notes(buf)` — normal-mode: `open_file`→focus editor, `create`→`create_note`, `delete`→`delete_note`, `move`→`cut_note`, `scroll_*`, `refresh`, `open_github`, `close`. `ui.set_nav_keymaps` adds the `window_nav` prefix to all three buffers; the editor buffer also gets a normal-mode `close` map in `open_in_edit`.

### Three windows (`ui.lua`)

A dedicated tab (`tabnew`) holds three windows: a top row split into **folders** (left, `config.folders_width` cols, `winfixwidth`, statusline ` Folders`) and **notes** (right, statusline ` Notes`), then the **editor** (bottom, remaining height). Folders/notes have `winfixheight` so the editor always takes the remaining space.

- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut`/`NotesActive` with `default = true`), runs `tabnew`, seats the placeholder in the base window (editor), then `split='above'` → notes column, then `split='left'` (off the notes window) → folders. Attaches `picker.attach_folders`/`attach_notes` and `set_nav_keymaps` to all three buffers, registers autocmds, and sets focus to the notes column (no search box to enter, so no `startinsert`).
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file`, sets `filetype=markdown` (notes are ID-named with no extension), and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=yes`). Does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close_interactive` map to the new buffer. It **does not move focus** — opening a note leaves the cursor in the notes window.
- `show_placeholder()` — seats a fresh `nofile`/`bufhidden=wipe` scratch buffer (single line `Select a note or create a new one (a).`) in `edit_win`, resets `state.edit_buf` and `state.current_file = nil`, sets plain window options (no number/cursorline/signcolumn), and re-applies `set_nav_keymaps` + the normal-mode `close` map. Crucially it **force-wipes the previous real-file buffer** (only when its `buftype == ''`): without this, the just-deleted backing file makes `checktime` raise `E211: File … no longer available`. Called from `open()` for the initial empty editor and from `picker.delete_note()`/`delete_folder()` when the deleted path is (or contains) the open note.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the notes buffer.
- `close()` — sets `st.closing = true`, clears all state fields (including `folders_win`/`folders_buf`/`current_folder`/`cut`), then `tabclose <tabnr>`. The `st.closing` guard in `WinClosed` prevents recursion when `tabclose` triggers that autocmd for each closing window.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and runs `wincmd h/j/k/l`.

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing any of the three windows triggers `notes.close()` (guarded by `st.closing`).
- `CursorMoved` on `list_buf` → if the current window is `list_win`, calls `picker.open_selected()` (auto-open). The `current_win` guard prevents false triggers when `render_notes()` resets the cursor to line 1 while focus is elsewhere.
- `CursorMoved` on `folders_buf` → if the current window is `folders_win`, calls `picker.select_folder()` (filter notes to the focused folder).
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → git sync on `:w`. Skipped when `st.closing` is true and while `st.synced` is false (to avoid committing a dirty tree before the initial restore/pull completes).

### Public API (`init.lua`)

- `is_open()` — checks `state.tab` validity. If the tab was closed externally (e.g. `:tabclose`), self-heals by wiping all stale state fields so old window IDs cannot trigger false autocmd matches on a future session.
- `open()` — guard against double-open; calls `ui.open()` + `picker.populate()`, then kicks off the async git chain (ensure_repo → restore → pull).
- `close()` — calls `ui.close()` then `git.sync_on_exit()`. Does not prompt; safe to call from autocmds.
- `close_interactive()` — checks the editor buffer for unsaved changes. If modified, shows a `confirm()` dialog: **Save** (`:silent write` then close+sync), **Discard** (close+sync without saving), **Cancel** (abort). Bound to the `close` key in all three windows. `toggle()` uses this as well.

### Git sync (`git.lua`)

All git commands run via `vim.system` (non-blocking). Callbacks are always wrapped in `vim.schedule` because `vim.system` callbacks fire outside the main loop.

Key design decision: **no explicit branch in pull/push**. Using `git pull --rebase --autostash` and `git push` (without `origin <branch>`) relies on the upstream tracking ref that `git clone` sets automatically. This avoids breakage when the user's `init.defaultBranch` differs from the hardcoded branch name. `--autostash` keeps the pull from failing when the working tree has uncommitted changes (it stashes them before the rebase and re-applies after).

`sync_on_exit()` is called from: `notes.close()` (on `<C-[>`), the `BufWritePost` autocmd (on `:w`), and immediately after each change action (create note/folder, delete note/folder, move note, rename folder).

**Concurrency guard:** two module-level booleans `syncing` / `sync_pending` serialise concurrent calls. If a second call arrives while a chain is in flight, it sets `sync_pending = true` and returns. `finish()` (called at every terminal point of the chain) clears `syncing` and, if `sync_pending` is set, immediately starts one more run — collapsing any number of queued calls into a single follow-up sync. If no follow-up is pending and notes is open, `finish()` calls `picker.refresh()` so any files added or deleted by the pull are immediately reflected in the list. At true idle (no pending sync), `finish()` also fires the one-shot `M._on_idle` hook if set — an internal completion callback used only by the test suite to await the async chain; production never sets it.

**Flow when uncommitted changes exist (`git status --porcelain` non-empty):**

```
git fetch origin
  └─ remote ahead of HEAD? (git rev-list HEAD..FETCH_HEAD --count)
       No  → git add -A → git commit → git push
       Yes → git stash push --include-untracked
               └─ git pull --ff-only
                    Fail (histories diverged) → git pull --rebase   (tree is clean: changes are stashed)
                                                  Fail → git rebase --abort
                                                           → restore stash (if any) → ERROR, abort
                                                  OK   → pop_and_commit (below)
                    OK                        → pop_and_commit:
                                                   nothing was stashed → commit → push
                                                   stash exists        → git stash pop
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

**Diverged history + uncommitted changes (`pull --ff-only` fails):** after the manual `stash push` the working tree is clean, so the diverged case runs plain `git pull --rebase` (rebases local commits onto the remote) and then the shared `pop_and_commit` helper (`stash pop` → `do_commit_push`, or `handle_stash_conflict` on a pop conflict). If the rebase itself conflicts (committed histories touch the same lines), it runs `git rebase --abort` to leave a clean tree, restores the stash, and reports — it never leaves the repo mid-rebase. This unifies the stashed and nothing-stashed diverged cases; there is no longer a dead-end "could not merge" abort that left sync permanently stuck.

**Flow when working tree is clean but local commits exist:** `git rev-list @{u}..HEAD --count` → if non-zero (or no upstream), `do_push`.

**Self-healing push (`do_push`):** on success it notifies and finishes. On a rejected push whose stderr matches `fetch first` / `non-fast-forward` / `rejected` (the remote advanced after our last fetch), it runs `git pull --rebase --autostash` and retries the push **once**, guarded by a per-chain `pushed_retry` boolean so it can never loop. If that rebase conflicts it runs `git rebase --abort` and reports. This safety net covers every push path — notably the clean-tree local-ahead case, which pushes without a prior fetch.

Each step is guarded: if any step fails, a WARN/ERROR notification is shown and the chain stops.

`pull()` (on open) runs `git pull --rebase --autostash`. If it fails — typically a rebase conflict between a local unpushed commit and the remote — it runs `git rebase --abort` before the WARN, so the working tree is never left mid-rebase for the next `sync_on_exit` to commit on top of.

`restore()` runs on **every** open (before pull), independent of `repo`. It runs `git ls-files --deleted -z` and, for any tracked file missing from the working tree, `git checkout -- <files>` to bring it back from the last commit. Rationale: the plugin commits all of its own edits, so an uncommitted *deletion* at open time is accidental (e.g. `rm` in the shell) and must not propagate to the remote on the next push. Only deletions are restored — modified-but-uncommitted tracked files are left alone so real edits survive. `-z` avoids path quoting so Cyrillic/space filenames work.

A companion guard in `ui.lua`'s `BufWritePost`: it skips sync while `state.synced` is false, so an early `:w` during the async open/restore/pull window can't commit a dirty tree before restore finishes.

`open_github()` (bound to `O` in the folders/notes columns) converts `config.repo` to a browsable `https://host/user/repo` URL (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`.

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

Automated suite lives in `test/` and needs only `git` + `nvim` on `PATH`:

```bash
bash test/run.sh        # picker spec + git-sync spec; exits non-zero on any failure
```

- `test/picker_spec.lua` — headless, synchronous: folders+notes `scan`, title-from-first-line, empty-note pinned/deduped, root-only `Notes` view + folder `filter`, folder recency sort, `dd.mm.yyyy - title` row format, `create_folder` (`.gitkeep`), note move (`cut_note`+`folder_enter`), `rename_folder`, and the delete-of-open-note fallback to the placeholder (asserts no `E211`, `current_file` cleared). Run alone: `nvim --headless -l test/picker_spec.lua`.
- `test/sync_spec.sh` + `test/sync_driver.lua` — builds a bare `remote.git` plus two clones (`A` = the plugin's dir, `B` = a second machine) and drives `sync_on_exit` / `pull` / `restore` on `A` through the driver, which arms `git._on_idle` (or a pull/restore callback) and `vim.wait`s for the async chain to settle. Covers S1–S8: remote-add, same-file conflict (Yes/No), different-file auto-merge, remote-delete, diverged-history rebase-after-stash, clean local-ahead push-reject retry, accidental-rm restore, and pull-rebase-conflict abort. Dialogs are made deterministic by monkeypatching `vim.fn.confirm` (`NOTES_CONFIRM`).

Manual / ad-hoc headless checks:

```bash
# module load smoke test
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua print(require('notes').config.dir)" \
  -c "qa!"

# list render: folders column + notes column (title from first line, "dd.mm.yyyy  title")
mkdir -p /tmp/notes-test/work
printf '# hi\n'      > /tmp/notes-test/work/20260101000000
printf 'plain idea\n' > /tmp/notes-test/20260102000000
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua require('notes.ui').open(); require('notes.picker').populate()" \
  -c "lua local s=require('notes').state; print('folders:'); for _,l in ipairs(vim.api.nvim_buf_get_lines(s.folders_buf,0,-1,false)) do print(l) end; print('notes:'); for _,l in ipairs(vim.api.nvim_buf_get_lines(s.list_buf,0,-1,false)) do print(l) end" \
  -c "qa!"
# expect folders: "Notes", "work"; notes (root view): only the "plain idea" row
```

## Common pitfalls

- **Do not pin `StatusLine`/`CursorLineNr` in the editor's `winhighlight`** — the user's global `UpdateInsertModeColor` (`InsertEnter`/`InsertLeave`) remaps those groups via the *current window's* `winhighlight`. Pinning them in the plugin would shadow that and break insert-mode recoloring. `open_in_edit` only sets plain window options (`number`/`cursorline`/`signcolumn`/…) and leaves `winhighlight` alone.
- **`statusline` for folders/notes is per-window** — set via `vim.wo[win].statusline`. Users with a statusline plugin (lualine, etc.) may want to add `NotesFolders` and `NotesList` to that plugin's exclusion list if their plugin overrides per-window statuslines.
- **Note selection is the `list_win` cursor; folder selection is the `folders_win` cursor** — not stored state. Read with `nvim_win_get_cursor(win)[1]` → `state.items[n]` / `state.folders[n]`. `cursorline` provides the visual; `state.current_folder` records the active folder (set from the folders CursorMoved handler).
- **Title comes from content, not the filename** — notes are ID files (`%Y%m%d%H%M%S`, no extension); the list title is read live from the first non-blank line via `title_of` on every scan. There is no rename-on-save, so a note's path is stable across edits. Only **one empty note per folder** may exist (`create_note` reopens an existing one).
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
