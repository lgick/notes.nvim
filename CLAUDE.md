# notes.nvim — Developer Guide

## Language

Все ответы в Claude Code давать на **русском языке**.

## Project overview

A self-contained Neovim plugin written in pure Lua. No external plugin dependencies. Requires Neovim ≥ 0.10.

## Repository layout

```
notes.nvim/
  lua/
    notes/
      init.lua   — public API: setup(), open(), close(), close_interactive(), toggle(); config; state
      git.lua    — async git operations (clone, merge-pull, commit, push, conflict tracking) via vim.system
      picker.lua — two-pane model: scan folders+notes, title-from-content, filter, render, CRUD/move, keymaps
      ui.lua     — three windows in a tab (folders | notes + editor): open, close, open_in_edit, show_placeholder, nav keymaps
  README.md
  CLAUDE.md
```

## macOS-Notes model (high level)

The plugin imitates the macOS Notes app:
- **No manual filenames.** Each note is an opaque **ID file** (timestamp `%Y%m%d%H%M%S.md`,
  e.g. `20260627143000.md`). Its **title is the first non-blank line** of its content; an empty
  note is titled `New Note`. The ID never changes on edit, so titles never churn git history or
  collide. The editor opens notes as `markdown`.
- **Two-pane list:** a **folders** column (left) and a **notes** column (right) on top, with the
  editor below. No search box.
- **Folders are one level deep.** The folders column shows the virtual `Notes` (the **root**:
  notes with no folder) plus real folders, sorted so the folder with the most recently edited note
  comes first (`Notes` is always pinned first). Selecting one filters the notes column. Empty
  folders persist via a hidden `.gitkeep`.
- **Notes are sorted** empty-first (pinned top) then by mtime descending; each notes row reads
  `dd.mm.yyyy - <title>` (date is display-only, from mtime). **The title updates live while
  typing** (before `:w`) via a `TextChanged`/`TextChangedI` autocmd on the editor buffer.
- **Move by cursor:** `x` marks a note (`NotesCut` highlight over the title text, backed by
  `Visual`); focus stays in the notes column. Pressing `x` again on the already-marked note
  cancels the move. The user navigates to the folders column (`window_nav`) and presses `p`
  on a folder (or `Notes` = root) to drop the note (`paste_note`). After the drop the
  destination folder becomes the selected folder and rises to the top of the folders column
  (its moved note bumped to the newest mtime), so its notes fill the notes column.
  `<CR>` in the folders column only focuses the notes column — it no longer triggers the paste.
- **Same keys per column:** `a` creates (note in the notes column, folder in the folders column),
  `d` deletes; notes also have `x` (mark for move), folders also have `r` (rename) and `p` (paste).
- **Conflicts stay in the file.** A git merge conflict is left as standard markers in the note
  (no dialog); the conflicted note title and its folder name get a wavy error underline (`NotesConflict`).
  The user edits the markers out and saves — that completes the merge and pushes. Move/rename/delete
  of a conflicted note is blocked until it is resolved.

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
  conflicts      = nil,   -- set { [abs path] = true } of unmerged notes; nil = none. Set by git.lua, read by picker render/blocks
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `create`, `delete`, `rename`, `move`, `paste`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`). `create` and `delete` are a single key each, dispatched by column (`create_note`/`delete_note` in the notes column, `create_folder`/`delete_folder` in the folders column). `move` (`x`) marks a note for moving; `paste` (`p`, folders column only) drops the marked note into the selected folder. `config.list_height` sets the folders/notes row height in rows; `config.folders_width` sets the folders column width. The `close` default is `q`.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. The three windows form a 2-D layout, so navigation accepts `h/j/k/l` and dispatches to `vim.cmd('wincmd '..key)` (native spatial move). Exception: pressing `k` while in `edit_win` explicitly jumps to `list_win` (the notes column) rather than using `wincmd k`, which would otherwise land in whichever of the two top windows is above the cursor (often the folders column). Reading the char synchronously avoids the `timeoutlen` delay/flakiness that separate `<C-w>h/j/k/l` maps suffer from. It is mapped in both `n` and `i` modes (the editor may be in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) in the **notes** buffer scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`).

### Two-pane model (`picker.lua`)

- `title_of(file)` — reads only the first lines (`fn.readfile(file, '', 20)`) and returns the first non-blank, trimmed line plus `empty=false`; an all-blank/missing file returns `New Note, empty=true`.
- `scan()` — walks `config.dir` with `vim.fs.dir` **one level deep**. Collects real top-level folder names and `state.notes_all` (`{ file, folder, title, mtime, empty }` for every file at the root — `folder=''` — and inside each top-level folder — `folder=<dir name>`). Skips hidden entries (`.` prefix → excludes `.git`/`.gitkeep`). Sorts notes **empty-first, then mtime descending**. Then builds `state.folders`: the virtual root `{ name='Notes', folder=nil }` **pinned first**, then real folders sorted by `folder_mtime` descending — defined as the mtime of each folder's most recently modified note, or the directory's own mtime for empty folders (so a newly created empty folder sorts to the top). The comparator is a **strict total order** (`table.sort` is not stable, so equal keys must be broken deterministically): after `folder_mtime`, a folder that **contains a note** ranks before an empty folder on an equal timestamp, then a final tie-break by name. The note-bearing tie-break is what makes `paste_note` reliable: moving a note out of a folder empties the source and bumps *its directory* mtime to the same second as the moved note's bumped mtime in the destination — without the tie-break the unstable sort could float the (empty) source above the destination.
- `filter()` — `target = current_folder or ''`; keeps notes whose `folder == target` (so the root `Notes` shows only `folder==''` notes). Result → `state.items`. No query/search.
- `render_folders()` — renders folders as a file tree into `state.folders_buf`: the root row is `Notes/` (no prefix), intermediate real folders get `├─ name/`, the last real folder gets `└─ name/`. Each row gets a `line_hl_group` extmark: `NotesDir` normally, `NotesDirActive` for the row matching `current_folder` (namespace `ns_folders`). Uses `nvim_buf_set_extmark` (not `nvim_buf_add_highlight`) so the highlight fills the full line width. **Conflict highlight:** any folder containing at least one note in `state.conflicts` (root `Notes` = `folder==''`) gets a `NotesConflict` **`hl_group`** extmark (`hl_mode='combine'`, `end_col=#line`, namespace `ns_conflict`, priority 300) over its row text — a wavy error underline. It must be `hl_group`, **not** `line_hl_group`: the folder row already carries a `line_hl_group` (`NotesDir`/`NotesDirActive`) at the default extmark priority (4096), which would hide a lower-priority `line_hl_group`; `hl_group` is a separate layer that combines with it regardless. Selection is always by cursor position → `state.folders[n]`, so the display text does not affect any selection logic.
- `render_notes()` — writes `os.date('%d.%m.%Y', mtime) .. ' - ' .. title` lines into `state.list_buf`. Empty result renders `(no notes)`. For every row it adds a `NotesTitle` extmark (namespace `ns_title`, priority 100, `hl_mode='combine'`) over **the title text only** — starting at byte offset `13` (the fixed length of the `dd.mm.yyyy - ` prefix) through `end_col = #line` — so the title is bolded while the date prefix stays plain. **Conflict highlight:** rows whose `it.file` is in `state.conflicts` get a `NotesConflict` `hl_group` extmark over the row text (`hl_mode='combine'`, `end_col=#line`, namespace `ns_conflict`, priority 300 — above Title/Active/Cut) — a wavy error underline that overlays the title color/bold rather than replacing it. Then applies a `NotesCut` extmark (priority 200) via `hl_group` over the title text only (`end_col = #line`, not full width) on the `state.cut` row (namespace `ns`), then `highlight_active()`. **Cursor:** places the notes cursor on the row of the active note (`state.current_file`) if it is in the current list, otherwise line 1 — **not** an unconditional reset to line 1. This keeps a background re-render (git sync completing, `BufWritePost`) from yanking the cursor to the top (and auto-opening the top note) while the user is navigating; on a first show / folder switch there is no matching `current_file`, so it falls back to line 1.
- `highlight_active()` — clears `ns_active` and adds an `hl_group = 'NotesActive'` extmark (covering the full line text via `end_col = #line`) with explicit `priority = 0` (so the cut highlight, priority 200, is never hidden when both land on the active row) to the row whose `item.file == state.current_file`. Uses `hl_group` rather than `line_hl_group` so that priority comparison works against `NotesCut`'s 200 — `line_hl_group` is a separate rendering layer that overrides `hl_group` regardless of priority.
- `update_live_title(buf, file)` — reads the first 50 lines of `buf` in-memory (no disk read), finds the first non-blank line as the new title (or `EMPTY_TITLE`), updates `title`/`empty` on the matching entry in `state.notes_all` and `state.items`, then calls `render_notes()`. Registered as a `TextChanged`/`TextChangedI` autocmd on the editor buffer in `open_in_edit` so the list stays in sync while the user types.
- `populate()` = `scan` + `validate_folder` + `filter` + `render_folders` + `render_notes`. `validate_folder` resets `current_folder` to `nil` if the selected folder vanished. `refresh` is an alias for `populate`; both run on open and after each git step.
- **Note selection = `list_win` cursor**; **folder selection = `folders_win` cursor.** `selected_note()`/`selected_folder()` read each window's cursor and index `state.items`/`state.folders`.
- `select_folder()` — folders-column cursor handler: sets `state.current_folder` to the row's folder and re-filters/re-renders the notes column.
- `open_selected()` (`<CR>` in notes / CursorMoved) → `ui.open_in_edit(item.file)` + `highlight_active()`; **does not move focus**.
- **Conflict guard:** while a note is in a merge conflict (`is_conflicted(file)` = `state.conflicts[file]`), destructive ops on it are refused with `Resolve the conflict first`: `cut_note`/`delete_note` (the conflicted note), `paste_note` (when `state.cut` is conflicted), and `rename_folder`/`delete_folder` (when the folder holds any conflicted note via `folder_has_conflict`). Moving a file with an unmerged index entry via `fn.rename` would desync the index from the working tree, so the user must resolve in the editor first.
- Actions (each calls the module-local `sync()` after a change). `sync()` is a no-op when `repo == ''` **or while `state.synced` is false** (the initial `restore`/`pull` is still running) — the latter gate is critical: a CRUD `sync()` firing during the open `M.pull` would run git concurrently with it and could push a commit that makes the open pull abort on a still-untracked file (`Cannot fast-forward your working tree`). Anything created during that window is committed by the post-pull `sync_on_exit()` in `init.open` (the same `synced` gate already protects `BufWritePost`). Otherwise `sync()` just calls `git.sync_on_exit()` — fully async and serialised by that function's `syncing`/`sync_pending` mutex. It does **not** run its own `git add -A`: `sync_on_exit`'s `commit_only` stages everything (including a deletion, so `restore()` can't resurrect it). An earlier design staged separately here — first synchronously (`:wait()`, which froze the UI on a slow disk), then asynchronously (which spawned an un-serialised git process that raced the open pull); both were removed.
  - `create_note()` (`a`, notes column) — target folder = `current_folder` (or root when `Notes` is selected). If that folder already holds an **empty** note, it is reopened instead of creating a second (one empty note per folder). Otherwise writes an empty **ID file** (`new_id` = `%Y%m%d%H%M%S.md` + collision suffix before the extension) and opens it in the editor **without moving window focus** (focus stays in the notes column). It calls `open_in_edit(target)` **before** `populate()` so that `render_notes` (which parks the cursor on `current_file`) lands the notes cursor on the new note — which, being empty, is pinned to the top row. The empty-note-reuse branch already opens then populates for the same reason.
  - `create_folder()` (`a`, folders column) — `vim.ui.input` name (rejects `/`: folders are one level), `mkdir -p`, writes a hidden `.gitkeep` so the empty folder can commit.
  - `rename_folder()` (`r`, folders column) — refuses the virtual root `Notes` row; if the open note is inside the folder **and modified, writes it first** (so unsaved edits survive the move — see the pitfall below), then `fn.rename`s the directory; if the open note is inside, reopens the editor at the new path and wipes the stale buffer; updates `current_folder` if it was the renamed one.
  - `delete_note()` (`d`, notes column) / `delete_folder()` (`d`, folders column) — `confirm`, then `fn.delete`; if the open note (or, for a folder, a note inside it) is removed, calls `ui.show_placeholder()` so the editor drops the orphaned buffer (avoids `E211`).
  - `cut_note()` (`x`) — sets `state.cut`, re-renders (NotesCut highlight), and notifies the user to navigate and press `keys.paste`. Focus stays in the notes column (the user moves to the folders column themselves via `window_nav`). Pressing `x` on the note that is **already** marked (`state.cut == it.file`) clears `state.cut` (cancels the move) and re-renders instead. **The notes cursor is preserved**: `render_notes` resets it to line 1, but `cut_note` captures the row before rendering and restores it after (the `items` list is unchanged by a mark), so marking a note deep in the list does not jump the cursor to the top.
  - `folder_enter()` (`<CR>`, folders column) — focuses the notes column (`list_win`). No paste logic; exists only to give the user a way to jump back to notes from folders.
  - `paste_note()` (`p`, folders column) — if `state.cut` is set, moves the marked note into the selected folder via `fn.rename`; if the moved note is the open one **and modified, writes it before the rename** (so unsaved edits survive and no duplicate is recreated — see the pitfall below); reopens the editor at the new path if the note was open; clears `state.cut`. After the rename it **bumps the moved file's mtime to now** (`vim.uv.fs_utime`) — `fn.rename` preserves mtime, and folder recency = the newest note's mtime, so this floats the destination folder to the top of the folders column (and the moved note to the top of its new folder's list). It then sets `state.current_folder = f.folder` (nil for root `Notes`) so `populate()` filters the notes column to the destination and highlights it `NotesDirActive`, and finally moves the `folders_win` cursor onto the destination folder's (re-sorted) row before `sync()`.
- `attach_folders(buf)` — normal-mode: `h`/`l` → `<Nop>` (block horizontal cursor movement), `open_file`→`folder_enter`, `paste`→`paste_note`, `create`→`create_folder`, `rename`→`rename_folder`, `delete`→`delete_folder`, `refresh`, `open_github`, `close`. `attach_notes(buf)` — normal-mode: `h`/`l` → `<Nop>`, `open_file`→focus editor, `create`→`create_note`, `delete`→`delete_note`, `move`→`cut_note`, `scroll_*`, `refresh`, `open_github`, `close`. `ui.set_nav_keymaps` adds the `window_nav` prefix to all three buffers; the editor buffer also gets a normal-mode `close` map in `open_in_edit`.

### Three windows (`ui.lua`)

A dedicated tab (`tabnew`) holds three windows: a top row split into **folders** (left, `config.folders_width` cols, `winfixwidth`, statusline ` Folders`) and **notes** (right, statusline ` Notes`), then the **editor** (bottom, statusline ` Editor`, remaining height). Folders/notes have `winfixheight` so the editor always takes the remaining space. The folders and notes windows have `cursorline = false` — only the terminal cursor shows the position; the active note is marked by the `NotesActive` extmark and the selected folder by `NotesDirActive` instead.

- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut`/`NotesActive`/`NotesTitle`/`NotesConflict`/`NotesDirActive`; `NotesConflict` is a wavy underline (`undercurl`) whose `sp` color is taken from `DiagnosticError` — falling back to `ErrorMsg` — so it is always a *wavy* error-colored line regardless of the colorscheme's diagnostic-underline groups), runs `tabnew`, **pins the tab label** (`t:title = 'notes.nvim'`; if the user has no `tabline` set — `vim.o.tabline == ''` — also installs `vim.o.tabline = '%!…tabline()'`, saving the old value in `_old_tabline` for restore on `close()`), seats the placeholder in the base window (editor), then `split='above'` → notes column, then `split='left'` (off the notes window) → folders. Attaches `picker.attach_folders`/`attach_notes` and `set_nav_keymaps` to all three buffers, registers autocmds, and sets focus to the **folders column** (so the user can navigate folders immediately).
- `tabline()` — the expression behind `vim.o.tabline` when the plugin installs its own. It renders every tabpage's label, using each tab's `t:title` var when present (so the notes tab always reads `notes.nvim` regardless of which inner window is focused) and falling back to the focused window's buffer name otherwise. Only installed when the user had no `tabline`; `close()` restores `_old_tabline`. Statusline/tabline plugins that read `t:title` get the pinned label for free.
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file`, sets `filetype=markdown` (notes are ID-named with no extension), and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=no`, soft-wrap on for prose — `wrap`/`linebreak`/`breakindent` — `spell=false`, markdown conceal on — `conceallevel=2`, `concealcursor='nc'` — and `statusline=' Editor %m'` where `%m` shows `[+]` while the note has unsaved changes). `show_placeholder` resets the inverse plain set (no number/cursorline/signcolumn, `wrap=false`, `conceallevel=0`). Does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close_interactive` map + a `TextChanged`/`TextChangedI` autocmd (calls `picker.update_live_title`) to the new buffer. The live-title autocmd is registered in a dedicated `NotesEditLiveTitle` augroup and `nvim_clear_autocmds` runs for that group+buffer first, so revisiting a note (its buffer is reused by `:edit`) never stacks duplicate handlers that would re-run `update_live_title` once per prior visit on every keystroke. It **does not move focus** — opening a note leaves the cursor in the notes window.
- `show_placeholder()` — seats a fresh `nofile`/`bufhidden=wipe` scratch buffer (single line `Select a note or create a new one (a).`) in `edit_win`, resets `state.edit_buf` and `state.current_file = nil`, sets plain window options (no number/cursorline/signcolumn, `statusline=' Editor'`), and re-applies `set_nav_keymaps` + the normal-mode `close` map. Crucially it **force-wipes the previous real-file buffer** (only when its `buftype == ''`): without this, the just-deleted backing file makes `checktime` raise `E211: File … no longer available`. Called from `open()` for the initial empty editor and from `picker.delete_note()`/`delete_folder()` when the deleted path is (or contains) the open note.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the notes buffer.
- `close()` — sets `st.closing = true`, clears all state fields (including `folders_win`/`folders_buf`/`current_folder`/`cut`), then `tabclose <tabnr>`. The `st.closing` guard in `WinClosed` prevents recursion when `tabclose` triggers that autocmd for each closing window.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and runs `wincmd h/j/k/l`. Special case: `k` from `edit_win` jumps explicitly to `list_win` instead of using `wincmd k`, because `wincmd k` would land in whichever of the two top windows is above the cursor (cursor position dependent).

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing any of the three windows triggers `notes.close()` (guarded by `st.closing`).
- `CursorMoved` on `list_buf` → if the current window is `list_win`, calls `picker.open_selected()` (auto-open). The `current_win` guard prevents false triggers when `render_notes()` resets the cursor to line 1 while focus is elsewhere.
- `CursorMoved` on `folders_buf` → if the current window is `folders_win`, calls `picker.select_folder()` (filter notes to the focused folder).
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → calls `picker.refresh()` immediately (so sort order and title update without waiting for git), then starts `git.sync_on_exit()`. Skipped when `st.closing` is true and while `st.synced` is false (to avoid committing a dirty tree before the initial restore/pull completes).

### Public API (`init.lua`)

- `is_open()` — checks `state.tab` validity. If the tab was closed externally (e.g. `:tabclose`), self-heals by wiping all stale state fields so old window IDs cannot trigger false autocmd matches on a future session.
- `open()` — guard against double-open; calls `ui.open()` + `picker.populate()`, then kicks off the async git chain (ensure_repo → restore → pull).
- `close()` — calls `ui.close()` then `git.sync_on_exit()`. Does not prompt; safe to call from autocmds.
- `close_interactive()` — checks the editor buffer for unsaved changes. If modified, shows a `confirm()` dialog: **Save** (`:silent write` then close+sync), **Discard** (`:silent edit!` to reload the saved version from disk, then close+sync), **Cancel** (abort). The `:edit!` on Discard is essential: the editor buffer is hidden (not wiped) on close, so without reloading, its unsaved edits would reappear the next time the same note is opened (`:edit` reuses the modified hidden buffer instead of reading disk). Bound to the `close` key in all three windows. `toggle()` uses this as well.

### Git sync (`git.lua`)

All git commands run via `vim.system` (non-blocking) through the `git()` helper. Callbacks are always wrapped in `vim.schedule` because `vim.system` callbacks fire outside the main loop. The helper sets `env = { LC_ALL = 'C', LANG = 'C' }` so git output is **English regardless of the user's locale** — our stdout/stderr string matching (`nothing to commit`, push-reject `fetch first`/`non-fast-forward`/`rejected`) would silently fail under a localized git otherwise.

**Conflict model: merge, not rebase.** A conflict is left in the file as standard git markers (`<<<<<<<`/`=======`/`>>>>>>>`); the repo enters `MERGING` (`.git/MERGE_HEAD` present). There are **no modal dialogs**. The conflicted notes are recorded in `state.conflicts` (via `update_conflicts`) so the UI underlines them with a wavy error line (`NotesConflict`); the user edits the markers out and saves, which on the next `sync_on_exit` completes the merge and pushes. History is therefore **not linear** — merges create merge commits. This is a deliberate trade for the simple, dialog-free conflict UX.

Key design decision: **no hardcoded branch name**. Pull uses `git pull --no-rebase --no-edit` (`--no-edit` so the merge commit message isn't prompted). On open, `pull()` **commits local changes first** then merges plain (no `--autostash`) — see the pitfall below: an autostash pop conflict leaves markers with **no** `MERGE_HEAD`, a state the merge model can't see and would later commit. Push uses `git push -u origin HEAD` — pushes the current branch by symbolic ref and sets upstream, so the **first** push of a fresh repo (no upstream yet) succeeds where plain `git push` would error.

Helpers:
- `merging(dir)` — `.git/MERGE_HEAD` exists (a merge is in progress).
- `has_markers(file)` — the file still contains conflict-marker lines. A staged-but-marker-laden file must never be committed.
- `conflict_label(path)` / `notify_conflict(paths)` — build a `Conflict in: <labels> — edit and save to resolve` WARN; the label is the file's first real (non-marker) content line, falling back to the file name.
- `update_conflicts(dir, cb)` — `git diff --name-only --diff-filter=U -z`, builds `state.conflicts` as a set of **absolute** paths (rel paths from git → `dir .. '/' .. rel`; `nil` when empty), then `cb(set)`. This is the single source of truth for `state.conflicts`; `picker` only reads it.

`sync_on_exit()` is called from: `notes.close()`, the `BufWritePost` autocmd (on `:w`), and after each change action.

**Concurrency guard:** module-level `syncing` / `sync_pending` serialise concurrent calls. A call arriving mid-chain sets `sync_pending` and returns; `finish()` (every terminal point) clears `syncing` and, if pending, starts one more run — collapsing queued calls into a single follow-up. At idle `finish()` calls `picker.refresh()` (so highlight/list reflect the new `state.conflicts`) and fires the one-shot `M._on_idle` test hook.

Inner helpers (forward-declared, mutually recursive):
- `commit_only(cb)` — `git add -A` → `git commit -m 'notes: <date>'`; treats `nothing to commit` as success → `cb()`.
- `do_push()` — clears `state.conflicts`, `git push -u origin HEAD`. On a reject (`fetch first`/`non-fast-forward`/`rejected`, guarded once by `pushed_retry`) it `git pull --no-rebase --no-edit` then `do_resolve()` — so a conflict introduced by that pull is handled like any other.
- `do_resolve()` — `update_conflicts`; if **any** still-unmerged file `has_markers`, `notify_conflict` the marker files and `finish()` (leave `MERGING` for the user). Otherwise (no markers anywhere — content resolved, and modify/delete files left in the tree) `commit_only(do_push)` completes the merge and pushes.

**Flow:**

```
sync_on_exit:
  update_conflicts; merging() OR any unmerged file?
              yes → do_resolve()         (a save that resolved markers finishes the merge;
                                          also catches an unmerged file with NO MERGE_HEAD)
              no  → commit_only:         (commit local edits first)
                      ls-remote has heads?
                        no  → do_push    (fresh repo: push initial commit, set upstream)
                        yes → git pull --no-rebase --no-edit → do_resolve
do_resolve:
  any conflicted file still has markers → notify + stop (stay MERGING; UI shows the wavy underline)
  else                                  → commit_only → do_push
```

Because `do_resolve` auto-commits when no markers remain, a **modify/delete** conflict (one side edited, the other deleted) — which git leaves marker-free in the tree — resolves automatically to *keep the present file* on the sync that detects it; it never deadlocks. Pure content conflicts wait for the user.

`pull()` (on open) — if already `merging()` from a previous session, just `update_conflicts` + `notify_conflict` and return (let the user resolve). Otherwise, skip if the remote has no branches, else **commit any local changes first** (`git add -A` + `git commit`, "nothing to commit" ignored) and then `git pull --no-rebase --no-edit` (plain merge, **not** `--autostash`) → `update_conflicts`; on conflict `notify_conflict`, on other failure a WARN. Committing first makes a conflict a real `MERGE_HEAD` merge (markers + `MERGE_HEAD`) instead of an autostash-pop conflict (markers, **no** `MERGE_HEAD`). A conflict here leaves `MERGING`, which the next `sync_on_exit` picks up via `do_resolve`. (`init.open` skips its post-pull `sync_on_exit` when `MERGE_HEAD` exists, to avoid a duplicate conflict notification.)

`restore()` runs on **every** open (before pull), independent of `repo`, **but is skipped while `merging()`** (checking out files would corrupt the unmerged index). It runs `git ls-files --deleted -z` and `git checkout -- <files>` for any tracked file missing from the working tree, recovering an accidental shell `rm` so the deletion isn't pushed. Only deletions are restored; modified-but-present files are left alone. `-z` avoids path quoting so Cyrillic/space filenames work.

A companion guard in `ui.lua`'s `BufWritePost`: it skips sync while `state.synced` is false, so an early `:w` during the async open/restore/pull window can't commit a dirty tree before restore finishes.

`open_github()` (bound to `O` in the folders/notes columns) converts `config.repo` to a browsable `https://host/user/repo` URL via the pure helper `repo_url(repo)` (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`. `repo_url` is split out from `open_github` so the conversion can be unit-tested without invoking `vim.ui.open`.

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

- `test/picker_spec.lua` — headless, synchronous: folders+notes `scan`, title-from-first-line, empty-note pinned/deduped, root-only `Notes` view + folder `filter`, folder recency sort, `dd.mm.yyyy - title` row format, the `NotesTitle` extmark (one per row, starts at byte 13 after the date prefix), the **conflict highlight** (`NotesConflict` extmark on the conflicted note row and on its folder row), the **conflict op-blocks** (`cut_note`/`paste_note`/`delete_note`/`rename_folder`/`delete_folder` refuse a conflicted note/folder), `create_folder` (`.gitkeep`), note move (`cut_note`+`paste_note`), the move-with-unsaved-edits write-before-rename, `rename_folder`, the delete-of-open-note fallback to the placeholder (asserts no `E211`, `current_file` cleared), the `close_interactive` **Discard** reload-from-disk path, the live-title autocmd dedup, and `git.repo_url` URL conversion (scp/ssh/https). Run alone: `nvim --headless -l test/picker_spec.lua`.
- `test/sync_spec.sh` + `test/sync_driver.lua` — builds a bare `remote.git` plus two clones (`A` = the plugin's dir, `B` = a second machine) and drives `sync_on_exit` / `pull` / `restore` on `A` through the driver, which arms `git._on_idle` (or a pull/restore callback) and `vim.wait`s for the async chain to settle. **No dialogs** in the merge model, so there is no `vim.fn.confirm` monkeypatch. Covers: **S1** remote-add (pull), **S2** same-file conflict → markers left + `MERGING` + not pushed, then resolve (remove markers) → committed+pushed, **S2-guard** leaving markers in place must not commit, **S3** different-file auto-merge, **S4** remote-delete, **S5** diverged history + dirty → merge, **S6** clean local-ahead + remote-advanced → merge+push, **S7** accidental-rm restore, **S8** same-file conflict on open (`pull`) → markers, no broken state, **S9** modify/delete → auto-resolves to keep the modified file, **S10** dirty (uncommitted) same-file conflict on open → a real `MERGE_HEAD` merge (not an autostash stash-pop orphan), no stash leaked, and the following `sync` must **not** commit/push the marker file (regression for the autostash bug). Conflict state is asserted via `.git/MERGE_HEAD` and `grep '^<<<<<<< '`.

Manual / ad-hoc headless checks:

```bash
# module load smoke test
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua print(require('notes').config.dir)" \
  -c "qa!"

# list render: folders column + notes column (title from first line, "dd.mm.yyyy - title")
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

