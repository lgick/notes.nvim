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
- **Folders nest to any depth, shown drill-down (one level at a time).** The folders column shows
  row 1 = the current level (`Notes`, or `Notes/<path>/ ..` once drilled into a folder — `..` hints
  `o` = go up), followed by that level's **immediate** children only, sorted so the child whose
  subtree has the most recently edited note comes first. Pressing `o` on a child row drills into
  it; `o` on row 1 goes up one level (no-op at the true root). Selecting a row filters the notes
  column to that folder's **direct** notes (not descendants — those are seen by drilling in).
  Empty folders persist via a hidden `.gitkeep`. New folders (`a`) are always created as a child of
  the current level.
- **Notes are sorted** empty-first (pinned top) then by mtime descending; each notes row reads
  `dd.mm.yyyy - <title>` (date is display-only, from mtime). **The title updates live while
  typing** (before `:w`) via a `TextChanged`/`TextChangedI` autocmd on the editor buffer.
- **Move by cursor:** `x` marks a note (in the notes column) or a folder (in the folders column) —
  both use the same `NotesCut` highlight (over the title text for a note, over the row text for a
  folder), backed by `Visual`; focus stays put. Pressing `x` again on the already-marked item
  cancels the move. Marking a note clears any marked folder and vice versa — only one item can be
  marked at a time. For a note, the user navigates to the folders column (`window_nav`) and
  presses `p` on a folder (or `Notes` = root) to drop it (`paste_note`); for a folder, the user
  navigates *within* the folders column itself (drill in/out with `o`, move the cursor) to the
  destination and presses `p` there (`paste_folder` — `paste_note` dispatches to it when a folder,
  not a note, is marked). The true root (`Notes`) can't be marked, and a folder can't be moved into
  itself or one of its own descendants. After the drop the destination folder becomes the selected
  folder and rises to the top of the folders column (the moved note/folder bumped to the newest
  mtime); for a moved folder, the folders column also drills into the destination so the moved
  folder shows up as one of its children, with the cursor parked on that row.
  `<CR>` in the folders column only focuses the notes column — it no longer triggers the paste.
- **Same keys per column:** `a` creates (note in the notes column, folder in the folders column),
  `d` deletes, `x` marks for move, `p` pastes; folders also have `r` (rename).
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
  current_folder = nil,   -- selected folder path (relative, any depth); nil = "Notes" (root)
  main_folder    = nil,   -- relative path of the folders column's drill-down level; nil = root
  cut            = nil,   -- path of the note marked for moving (set by `x`)
  cut_folder     = nil,   -- relative path of the folder marked for moving (set by `x` in the folders column)
  folders        = nil,   -- array of { name, folder, is_main }; folders[1] is the main row
  notes_all      = nil,   -- full scan: array of { file, folder, title, mtime, empty }
  items          = nil,   -- filtered notes for current folder + query; notes line n → items[n]
  conflicts      = nil,   -- set { [abs path] = true } of unmerged notes; nil = none. Set by git.lua, read by picker render/blocks
  panels_hidden  = false, -- true while Folders + Notes columns are toggled off (toggle_panels)
}
```

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `create`, `delete`, `rename`, `move`, `paste`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`, `toggle_panels`, `change_folder`). `create` and `delete` are a single key each, dispatched by column (`create_note`/`delete_note` in the notes column, `create_folder`/`delete_folder` in the folders column). `move` (`x`) marks a note (notes column, `cut_note`) or a folder (folders column, `cut_folder`) for moving; `paste` (`p`, folders column only) drops the marked note or folder into the selected folder — `paste_note` is the bound function and dispatches to `paste_folder()` when `state.cut_folder` is set. `change_folder` (default `o`, folders column only) drills into the folder under the cursor, or goes up one level from the main row (see `picker.change_folder`). `toggle_panels` (default `<C-t>`) shows/hides the Folders and Notes columns; mapped in all three buffers. `config.list_height` sets the folders/notes row height in rows; `config.folders_width` sets the folders column width. The `close` default is `q`.

`config.sync_icons` — optional table `{ idle, syncing, conflict }` with custom icon strings for each sync state. When `nil` (default), the plugin auto-selects: for `syncing` — animated braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) unless `sync_icons.syncing` is set; for `idle`/`conflict` — Nerd Font glyphs (nf-fa-check / nf-cod-warning) if `nvim-web-devicons` is already loaded in the session (used as a proxy for Nerd Fonts being present), otherwise plain ASCII fallback (`✓` / `!`). No icon is shown when `config.repo == ''`.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. The three windows form a 2-D layout, so navigation accepts `h/j/k/l` and dispatches to `vim.cmd('wincmd '..key)` (native spatial move). Exception: pressing `k` while in `edit_win` explicitly jumps to `list_win` (the notes column) rather than using `wincmd k`, which would otherwise land in whichever of the two top windows is above the cursor (often the folders column). Reading the char synchronously avoids the `timeoutlen` delay/flakiness that separate `<C-w>h/j/k/l` maps suffer from. It is mapped in both `n` and `i` modes (the editor may be in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) in the **notes** buffer scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`).

### Two-pane model (`picker.lua`)

- `title_of(file)` — reads only the first lines (`fn.readfile(file, '', 20)`) and returns the first non-blank, trimmed line plus `empty=false`; an all-blank/missing file returns `New Note, empty=true`.
- `scan()` — walks `config.dir` with `vim.fs.dir` **recursively, to any depth**. Collects every folder's relative path (`"Work"`, `"Work/Projects"`, …) into a module-local `all_folders` (not part of `state`; `build_folders()` derives the visible drill-down level from it) and `state.notes_all` (`{ file, folder, title, mtime, empty }` for every file, where `folder` is its full relative path — `''` at the root, `"Work/Projects"` when nested). Skips hidden entries (`.` prefix → excludes `.git`/`.gitkeep`). Sorts `notes_all` **empty-first, then mtime descending**; unchanged from the single-level version.
- `folder_recursive_mtime(folder_rel)` — module-local. Freshness of a folder = the most recent mtime among all notes in it **and all its descendants** (matched by exact `folder` equality or a `folder_rel .. '/'` prefix); falls back to the directory's own mtime if the subtree has no notes at all (so a newly created empty folder sorts to the top among its siblings). Returns `mtime, has_note` — `has_note` feeds the same tie-break as before.
- `build_folders()` — builds the **visible drill-down level** of `state.folders` from `all_folders` and `state.main_folder`: row 1 is the main row (`{ folder = main_folder, is_main = true }`, `nil` = root), followed by `main_folder`'s **immediate** children (paths under the `main_folder .. '/'` prefix with no further `/`), sorted by `folder_recursive_mtime` descending. The tie-break is the same **strict total order** as before (`table.sort` is not stable): freshness → note-bearing (via `has_note`) → name. The note-bearing tie-break is what makes `paste_note` reliable: moving a note out of a folder empties the source and bumps *its directory* mtime to the same second as the moved note's bumped mtime in the destination — without the tie-break the unstable sort could float the (empty) source above the destination. Called from `populate()` after `scan()` + `validate_folder()`.
- `filter()` — `target = current_folder or ''`; keeps notes whose `folder == target` (exact match, so the notes column shows only the selected folder's **direct** notes — descendants are seen after drilling in with `o`). Result → `state.items`. No query/search.
- `change_folder()` — bound to `o` in the folders column. On the main row (row 1): if `main_folder` is set, goes up one level (`main_folder = main_folder:match('^(.*)/[^/]+$')`, `nil` at the top); no-op at the true root. On a child row: drills in (`main_folder = current_folder = f.folder`). Either way calls `populate()` then parks the `folders_win` cursor on row 1 — the resulting `CursorMoved → select_folder()` (or, if the cursor didn't move, `change_folder` having already set `current_folder` itself) keeps `current_folder` consistent with the new main row.
- `render_folders()` — renders the drill-down level into `state.folders_buf`: row 1 (`is_main`) reads `Notes/` at the root or `Notes/<main_folder>/ ..` when drilled in (the trailing `/` matches the child rows' `name/` format, and `..` hints `o` = go up); children get `├─ name/`/`└─ name/` prefixes as before (`name` = the child's leaf, `state.folders[i].folder` its full relative path). **Left-truncation:** the main row's text is passed through `fit_left(line, width)` (`width` = the live `folders_win` width, falling back to `config.folders_width` when the window isn't valid yet) — at deep nesting the full `Notes/<path>/ ..` string can exceed the fixed-width folders column, and Neovim's default right-truncation would hide the current folder's own name; `fit_left` instead drops leading characters and prefixes `…`, keeping the tail (current folder name + `/ ..`) always visible. Only applied to the main row — child rows keep plain right-truncation since their leaf name already starts the line. `fit_left` uses `vim.fn.strdisplaywidth`/`strcharpart` (correct for multibyte names). Each row gets an `hl_group` extmark (namespace `ns_folders`, `end_col=#line`, `priority=0`): `NotesDir` normally, `NotesDirActive` for the row matching `current_folder`. Deliberately `hl_group`, not `line_hl_group`: `line_hl_group` is a separate rendering layer that would override any overlapping `hl_group` extmark (`NotesCut`, `NotesConflict`) regardless of its priority — the same fix already applied to `NotesActive` in `render_notes`/`highlight_active` (see below), now mirrored here so a cut/conflicted row that is also the selected folder still shows its `NotesCut`/`NotesConflict` color instead of being hidden under the selection highlight. The trade-off is that the highlight only spans the row's text width, not the full window width to the right edge (a `line_hl_group` fills to the edge; `hl_group` with `end_col=#line` does not). **Conflict highlight (recursive):** each row (main or child) gets a `NotesConflict` `hl_group` extmark (`hl_mode='combine'`, `end_col=#line`, ns `ns_conflict`, priority 300) when `folder_has_conflict(f.folder)` is true — i.e. a conflicted note exists anywhere in that folder's **subtree**, not just directly in it; the root main row (`folder=nil`) covers the whole tree. **Cut highlight:** the row whose `f.folder` equals `state.cut_folder` gets a `NotesCut` `hl_group` extmark (`end_col=#line`, ns `ns` — shared with the notes column's cut highlight, but namespaces are per-buffer so no collision, priority 200), mirroring the note-cut highlight in `render_notes`; priority 200 beats the base row highlight's priority 0, so it stays visible even when the cut folder is also the selected one. Selection is by cursor position → `state.folders[n]`.
- `render_notes()` — writes `os.date('%d.%m.%Y', mtime) .. ' - ' .. title` lines into `state.list_buf`. Empty result renders `(no notes)`. For every row it adds a `NotesTitle` extmark (namespace `ns_title`, priority 100, `hl_mode='combine'`) over **the title text only** — starting at byte offset `13` (the fixed length of the `dd.mm.yyyy - ` prefix) through `end_col = #line` — so the title is bolded while the date prefix stays plain. **Conflict highlight:** rows whose `it.file` is in `state.conflicts` get a `NotesConflict` `hl_group` extmark over the row text (`hl_mode='combine'`, `end_col=#line`, namespace `ns_conflict`, priority 300 — above Title/Active/Cut) — a wavy error underline that overlays the title color/bold rather than replacing it. Then applies a `NotesCut` extmark (priority 200) via `hl_group` over the title text only (`end_col = #line`, not full width) on the `state.cut` row (namespace `ns`), then `highlight_active()`. **Cursor:** places the notes cursor on the row of the active note (`state.current_file`) if it is in the current list, otherwise line 1 — **not** an unconditional reset to line 1. This keeps a background re-render (git sync completing, `BufWritePost`) from yanking the cursor to the top (and auto-opening the top note) while the user is navigating; on a first show / folder switch there is no matching `current_file`, so it falls back to line 1.
- `highlight_active()` — clears `ns_active` and adds `hl_group='NotesActive'` extmark (`end_col=#line`, `priority=0`) to the row matching `state.current_file`. `priority=0` lets the cut highlight (200) win when both land on the same row. Uses `hl_group` not `line_hl_group` so priority ordering applies.
- `update_live_title(buf, file)` — reads the first 50 lines of `buf` in-memory (no disk read), finds the first non-blank line as the new title (or `EMPTY_TITLE`), updates `title`/`empty` on the matching entry in `state.notes_all` and `state.items`, then calls `render_notes()` and `ui.refresh_editor_statusline()` (so the editor statusline path also updates live while the user types). Registered as a `TextChanged`/`TextChangedI` autocmd on the editor buffer in `open_in_edit` so the list stays in sync while the user types.
- `populate()` = `scan` + `validate_folder` + `build_folders` + `filter` + `render_folders` + `render_notes`. `validate_folder` checks `main_folder`/`current_folder` **against disk** (`fn.isdirectory`), not against `state.folders` — the folders column only shows one drill-down level at a time, so a stale path from a different branch of the tree would not be found there even if it still exists. If `main_folder` no longer exists, both `main_folder` and `current_folder` reset to `nil` (root); if only `current_folder` is gone, it falls back to `main_folder`. `refresh` is an alias for `populate`; both run on open and after each git step.
- **Note selection = `list_win` cursor**; **folder selection = `folders_win` cursor.** `selected_note()`/`selected_folder()` read each window's cursor and index `state.items`/`state.folders`.
- `select_folder()` — folders-column cursor handler: sets `state.current_folder` to the row's folder and re-filters/re-renders the notes column.
- `open_selected()` (`<CR>` in notes / CursorMoved) → `ui.open_in_edit(item.file)` + `highlight_active()`; **does not move focus**.
- **Conflict guard:** while a note is in a merge conflict (`is_conflicted(file)` = `state.conflicts[file]`), destructive ops on it are refused with `Resolve the conflict first`: `cut_note`/`delete_note` (the conflicted note), `paste_note` (when `state.cut` is conflicted), and `rename_folder`/`delete_folder`/`cut_folder`/`paste_folder` (when the folder holds any conflicted note via `folder_has_conflict`, which now checks the folder's full subtree — a conflict several levels below the selected folder still blocks it). Moving a file (or a whole folder) with an unmerged index entry via `fn.rename` would desync the index from the working tree, so the user must resolve in the editor first.
- Actions (each calls the module-local `sync()` after a change). `sync()` is a no-op when `repo == ''` **or while `state.synced` is false** (the initial `restore`/`pull` is still running) — the latter gate is critical: a CRUD `sync()` firing during the open `M.pull` would run git concurrently with it and could push a commit that makes the open pull abort on a still-untracked file (`Cannot fast-forward your working tree`). Anything created during that window is committed by the post-pull `sync_on_exit()` in `init.open` (the same `synced` gate already protects `BufWritePost`). Otherwise `sync()` just calls `git.sync_on_exit()` — fully async and serialised by that function's `syncing`/`sync_pending` mutex. It does **not** run its own `git add -A`: `sync_on_exit`'s `commit_only` stages everything (including a deletion, so `restore()` can't resurrect it).
  - `create_note()` (`a`, notes column) — target folder = `current_folder` (or root when `Notes` is selected). If that folder already holds an **empty** note, it is reopened instead of creating a second (one empty note per folder). Otherwise writes an empty **ID file** (`new_id` = `%Y%m%d%H%M%S.md` + collision suffix before the extension) and opens it in the editor **without moving window focus** (focus stays in the notes column). It calls `open_in_edit(target)` **before** `populate()` so that `render_notes` (which parks the cursor on `current_file`) lands the notes cursor on the new note — which, being empty, is pinned to the top row. The empty-note-reuse branch already opens then populates for the same reason.
  - `create_folder()` (`a`, folders column) — `vim.ui.input` name (rejects `/`: one leaf name per call), created as a child of the current drill-down level (`state.main_folder`, or the root when `nil`), `mkdir -p`, writes a hidden `.gitkeep` so the empty folder can commit. Deeper nesting is reached by drilling in with `o` and creating again, not by typing a path with `/`.
  - `rename_folder()` (`r`, folders column) — works on the main row (the folder currently drilled into) or a child row; only the true root `Notes` (`folder == nil`) is refused. The input default is the folder's leaf name; only that leaf changes, its parent path stays put. If the open note is inside the folder **and modified, writes it first** (so unsaved edits survive), then `fn.rename`s the directory; if the open note is inside, reopens the editor at the new path and wipes the stale buffer. `current_folder`/`main_folder` are rewritten if they equal the renamed folder or are nested under it (prefix swap: the old relative path prefix is replaced with the new one), since either may point several levels below the renamed folder.
  - `delete_note()` (`d`, notes column) / `delete_folder()` (`d`, folders column) — `confirm`, then `fn.delete`; if the open note (or, for a folder, a note inside it) is removed, calls `ui.show_placeholder()` so the editor drops the orphaned buffer (avoids `E211`). `delete_folder` also fixes up navigation: if `main_folder` is the deleted folder or nested under it, `main_folder` (and `current_folder`) goes up to the deleted folder's parent; otherwise if only `current_folder` was inside it, `current_folder` falls back to `main_folder`.
  - `cut_note()` (`x`, notes column) — sets `state.cut` (and clears any marked folder, `state.cut_folder = nil` — a note and a folder can't be marked at the same time), re-renders (NotesCut highlight), and notifies the user to navigate and press `keys.paste`. Focus stays in the notes column (the user moves to the folders column themselves via `window_nav`). Pressing `x` on the note that is **already** marked (`state.cut == it.file`) clears `state.cut` (cancels the move) and re-renders instead. **The notes cursor is preserved**: `render_notes` resets it to line 1, but `cut_note` captures the row before rendering and restores it after (the `items` list is unchanged by a mark), so marking a note deep in the list does not jump the cursor to the top.
  - `cut_folder()` (`x`, folders column) — same mark/cancel/mutual-exclusion pattern as `cut_note`, for the selected folder row (`state.cut_folder`, clearing `state.cut`). Refuses the true root (`f.folder == nil`, `Cannot move the root folder`) and a conflicted folder (`folder_has_conflict`, recursive). Unlike a note (moved via the folders column), the destination for a marked folder is chosen by navigating *within the folders column itself* — drilling in/out with `o` and moving the cursor — since folders live there, not in a separate column. **The folders cursor is preserved** the same way `cut_note` preserves the notes cursor.
  - `folder_enter()` (`<CR>`, folders column) — focuses the notes column (`list_win`). No paste logic; exists only to give the user a way to jump back to notes from folders.
  - `paste_note()` (`p`, folders column) — the key's bound function; first checks `state.cut_folder` and dispatches to `paste_folder()` if set. Otherwise, if `state.cut` is set, moves the marked note into the selected folder via `fn.rename`; if the moved note is the open one **and modified, writes it before the rename** (so unsaved edits survive); reopens the editor at the new path if the note was open; clears `state.cut`. After the rename it **bumps the moved file's mtime to now** (`vim.uv.fs_utime`) — `fn.rename` preserves mtime, and folder recency = the newest note's mtime, so this floats the destination folder to the top of the folders column (and the moved note to the top of its new folder's list). It then sets `state.current_folder = f.folder` (nil for root `Notes`) so `populate()` filters the notes column to the destination and highlights it `NotesDirActive`, and finally moves the `folders_win` cursor onto the destination folder's (re-sorted) row before `sync()`.
  - `paste_folder()` (dispatched from `paste_note()` when `state.cut_folder` is set) — moves the marked folder (any depth) into the selected folder (or root) via `fn.rename` on the directory. Refuses if the marked folder is now conflicted, or if the destination **is** the marked folder or one of its own descendants (`Cannot move a folder into itself` — checked by prefix match on the relative paths), or if a folder with the same leaf name already exists at the destination. A no-op (silently re-renders) if the destination is the folder's current parent (moving it "into" where it already is). Persists unsaved edits first if the open note lives inside the moved subtree (same pattern as `rename_folder`), reopens the editor at the new path, and bumps the moved directory's mtime to now (same reasoning as `paste_note`). Rather than rewriting `current_folder`/`main_folder` prefixes (the `rename_folder` approach), it **drills the folders column into the destination** (`state.main_folder = state.current_folder = dest`) so the moved folder appears as a child there, and parks the cursor on that child's row — this covers both the common case (destination unrelated to where the user was browsing) and the edge case of moving the very folder the user is currently drilled into (its directory is gone at the old path by the time `populate()`'s disk-based `validate_folder` runs, but `main_folder` was already repointed to `dest` first).
- `attach_folders(buf)` — normal-mode: `h`/`l` → `<Nop>` (block horizontal cursor movement), `open_file`→`folder_enter`, `paste`→`paste_note`, `move`→`cut_folder`, `create`→`create_folder`, `rename`→`rename_folder`, `delete`→`delete_folder`, `change_folder`→`change_folder` (drill in/up), `refresh`, `open_github`, `toggle_panels`→`ui.toggle_panels`, `close`. `attach_notes(buf)` — normal-mode: `h`/`l` → `<Nop>`, `open_file`→focus editor, `create`→`create_note`, `delete`→`delete_note`, `move`→`cut_note`, `scroll_*`, `refresh`, `open_github`, `toggle_panels`→`ui.toggle_panels`, `close`. `ui.set_nav_keymaps` adds the `window_nav` prefix to all three buffers; the editor buffer also gets normal-mode `close` and `toggle_panels` maps in both `open_in_edit` and `show_placeholder`.

### Three windows (`ui.lua`)

A dedicated tab (`tabnew`) holds three windows: a top row split into **folders** (left, `config.folders_width` cols, `winfixwidth`, statusline ` Folders`) and **notes** (right, statusline ` Notes`), then the **editor** (bottom, statusline ` folder/title %m` when a note is open or ` Editor` when no note is open, remaining height). Folders/notes have `winfixheight` so the editor always takes the remaining space. The folders and notes windows have `cursorline = false` — only the terminal cursor shows the position; the active note is marked by the `NotesActive` extmark and the selected folder by `NotesDirActive` instead.

- `set_sync_status(status)` — updates the tab's `t:title` variable. For `'syncing'`: if `config.sync_icons.syncing` is set, uses it as a static icon; otherwise starts an animated braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) via `vim.uv.new_timer` (100 ms interval, first frame set synchronously so there is no initial lag). For `'idle'` / `'conflict'`: stops the spinner (`stop_spin()`), then sets a static icon from `SYNC_ICONS` — Nerd Font glyph or plain Unicode depending on `has_nerd_fonts()`. `has_nerd_fonts()` returns true if `package.loaded['nvim-web-devicons']` is non-nil **or** if `pcall(require, 'nvim-web-devicons')` succeeds. No-op when the tab is invalid or `config.repo == ''`. `stop_spin()` is called at the start of every `set_sync_status` call and in `M.close()`.
- `toggle_panels()` — hides or restores the Folders + Notes columns. **Hiding:** stores `folders_win`/`list_win` in locals, nils out `state.folders_win`/`state.list_win`/`state.folders_buf`/`state.list_buf` and `state.panels_hidden = true` *before* calling `nvim_win_close` — so the `WinClosed` autocmd (which compares against `state.folders_win`/`list_win`) does not mistake the controlled close for an external closure and call `notes.close()`. The `bufhidden=wipe` on both buffers means closing them also wipes the buffers and auto-removes their buffer-local `CursorMoved` autocmds. **Showing:** recreates both buffers and windows (mirrors the layout code in `open()`), re-attaches `picker.attach_*` keymaps and `set_nav_keymaps`, calls `setup_panel_autocmds(st)` for new CursorMoved autocmds, and calls `picker.populate()`.
- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut`/`NotesActive`/`NotesTitle`/`NotesConflict`/`NotesDirActive`; `NotesConflict` is `undercurl` with `sp` from `DiagnosticError` → `ErrorMsg` fallback), runs `tabnew`, pins tab label via `set_sync_status('syncing')` (sets `t:title`; installs `vim.o.tabline` if unset, saves old in `_old_tabline`), seats the placeholder in the base window, then `split='above'` → notes column, `split='left'` → folders. Attaches keymaps, registers autocmds, focuses the **folders column**.
- `tabline()` — the expression behind `vim.o.tabline` when the plugin installs its own. It renders every tabpage's label, using each tab's `t:title` var when present (so the notes tab always reads `notes.nvim` regardless of which inner window is focused) and falling back to the focused window's buffer name otherwise. Only installed when the user had no `tabline`; `close()` restores `_old_tabline`. Statusline/tabline plugins that read `t:title` get the pinned label for free.
- `editor_path_label(path)` — module-local helper. Strips `config.dir/` from `path` to get the relative path, extracts everything before the last `/` as the folder component (`Notes` when the note lives at the root), then looks up the note's current title in `state.notes_all` (falls back to `'New Note'` if not found yet, e.g. during `create_note` before `populate`). Escapes `%` characters in both components to `%%` so they are not interpreted as statusline sequences. Returns `'folder/title'` (supports any depth of nesting — `folder/subfolder/title` — for future multi-level folders).
- `refresh_editor_statusline()` — public. Rebuilds the editor statusline as `' ' .. editor_path_label(current_file) .. ' %m'` and assigns it to `edit_win`. No-op when `edit_win` is invalid or `current_file` is nil. Called from `open_in_edit` and from `picker.update_live_title` so the path stays current while the user types.
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file`, sets `filetype=markdown` (notes are ID-named with no extension), and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=no`, soft-wrap — `wrap`/`linebreak`/`breakindent`, `spell=false`, `conceallevel=2`, `concealcursor='nc'`, `statusline=' folder/title %m'` from `editor_path_label`). `show_placeholder` resets to plain (no number/cursorline/signcolumn, `wrap=false`, `conceallevel=0`, `statusline=' Editor'`). Does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close_interactive` map + a `TextChanged`/`TextChangedI` autocmd (calls `picker.update_live_title`) in `NotesEditLiveTitle` augroup with `nvim_clear_autocmds` first (prevents stacking on revisit). It **does not move focus** — opening a note leaves the cursor in the notes window.
- `show_placeholder()` — seats a fresh `nofile`/`bufhidden=wipe` scratch buffer (single line `Select a note or create a new one (a).`) in `edit_win`, resets `state.edit_buf` and `state.current_file = nil`, sets plain window options (no number/cursorline/signcolumn, `statusline=' Editor'`), and re-applies `set_nav_keymaps` + the normal-mode `close` map. Crucially it **force-wipes the previous real-file buffer** (only when its `buftype == ''`): without this, the just-deleted backing file makes `checktime` raise `E211: File … no longer available`. Called from `open()` for the initial empty editor and from `picker.delete_note()`/`delete_folder()` when the deleted path is (or contains) the open note.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the notes buffer.
- `close()` — sets `st.closing = true`, clears all state fields (including `folders_win`/`folders_buf`/`current_folder`/`cut`), then `tabclose <tabnr>`. The `st.closing` guard in `WinClosed` prevents recursion when `tabclose` triggers that autocmd for each closing window.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and runs `wincmd h/j/k/l`. Special case: `k` from `edit_win` jumps explicitly to `list_win` instead of using `wincmd k`, because `wincmd k` would land in whichever of the two top windows is above the cursor (cursor position dependent).

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing any of the three windows triggers `notes.close()` (guarded by `st.closing`). The handler compares against the live `st.folders_win`/`st.list_win`/`st.edit_win` — which are nil'd **before** controlled closes in `toggle_panels`, so panel toggle does not trigger the full close.
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → calls `picker.refresh()` immediately (so sort order and title update without waiting for git), then starts `git.sync_on_exit()`. Skipped when `st.closing` is true and while `st.synced` is false (to avoid committing a dirty tree before the initial restore/pull completes).

`setup_panel_autocmds(st)` — module-local helper, registers in the **`NotesPanels`** group (separate from `NotesWin` so toggling panels can re-register without disturbing WinClosed/BufWritePost):
- `CursorMoved` on `list_buf` → if the current window is `list_win`, calls `picker.open_selected()` (auto-open). The `current_win` guard prevents false triggers when `render_notes()` resets the cursor to line 1 while focus is elsewhere.
- `CursorMoved` on `folders_buf` → if the current window is `folders_win`, calls `picker.select_folder()` (filter notes to the focused folder).
Called from `setup_autocmds` on initial open, and from `toggle_panels` on each restore of the panels (with `{ clear = true }` so stale entries from the previous show are removed; wiped buffers also auto-remove their buffer-local autocmds when closed).

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
- `conflict_label(path)` / `notify_conflict(paths)` — build a `Conflict in: <labels> — edit and save to resolve` WARN; the label is `folder/title` where `folder` is `Notes` for root notes or the subdirectory name, and `title` is the first real (non-marker) content line, falling back to the file name. `conflict_label` is exported as `M.conflict_label` for unit tests (same pattern as `repo_url`).
- `update_conflicts(dir, cb)` — `git diff --name-only --diff-filter=U -z`, builds `state.conflicts` as a set of **absolute** paths (rel paths from git → `dir .. '/' .. rel`; `nil` when empty), then `cb(set)`. This is the single source of truth for `state.conflicts`; `picker` only reads it.

`sync_on_exit()` is called from: `notes.close()`, the `BufWritePost` autocmd (on `:w`), and after each change action.

**Concurrency guard:** module-level `syncing` / `sync_pending` serialise concurrent calls. A call arriving mid-chain sets `sync_pending` and returns; `finish()` (every terminal point) clears `syncing` and, if pending, starts one more run — collapsing queued calls into a single follow-up. At idle `finish()` calls `picker.refresh()` (so highlight/list reflect the new `state.conflicts`), updates the tab title via `ui.set_sync_status('conflict')` or `set_sync_status('idle')` depending on `state.conflicts`, and fires the one-shot `M._on_idle` test hook.

**Sync status updates in git.lua:** `set_sync_status('syncing')` is called at the entry of `sync_on_exit()` (right after `syncing = true`), `pull()` (before the ls-remote check), and `restore()` (after the `is_repo` guard). `set_sync_status('conflict')` is called when `pull()` detects a conflict (since `sync_on_exit` is skipped when MERGE_HEAD exists, so `finish()` won't update the status). `finish()` handles idle → `'idle'` and conflict → `'conflict'` for the sync chain terminal points.

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

`pull()` (on open) — if already `merging()` from a previous session, just `update_conflicts` + `notify_conflict` and return. Otherwise, skip if the remote has no branches, else **commit any local changes first** (`git add -A` + `git commit`, "nothing to commit" ignored) and then `git pull --no-rebase --no-edit` (plain merge, **not** `--autostash`) → `update_conflicts`; on conflict `notify_conflict`, on other failure a WARN. Committing first makes a conflict a real `MERGE_HEAD` merge instead of an autostash-pop conflict (markers but **no** `MERGE_HEAD`, invisible to the merge model). A conflict here leaves `MERGING`, picked up by the next `sync_on_exit` via `do_resolve`.

`restore()` runs on **every** open (before pull), independent of `repo`, **but is skipped while `merging()`** (checking out files would corrupt the unmerged index). It runs `git ls-files --deleted -z` and `git checkout -- <files>` for any tracked file missing from the working tree, recovering an accidental shell `rm` so the deletion isn't pushed. Only deletions are restored; modified-but-present files are left alone. `-z` avoids path quoting so Cyrillic/space filenames work.

A companion guard in `ui.lua`'s `BufWritePost`: it skips sync while `state.synced` is false, so an early `:w` during the async open/restore/pull window can't commit a dirty tree before restore finishes.

`open_github()` (bound to `O` in the folders/notes columns) converts `config.repo` to a browsable `https://host/user/repo` URL via the pure helper `repo_url(repo)` (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`. `repo_url` is split out from `open_github` so the conversion can be unit-tested without invoking `vim.ui.open`.

`ensure_repo()` handles three cases:
- `.git` exists → call `cb()` immediately.
- `repo == ''` → just `mkdir` the directory and call `cb()`.
- Otherwise → `git clone <repo> <dir>` then call `cb()`.

## Post-development checklist

After every feature or fix, in this order:

1. **Tests** — if the change touches picker/UI/git logic, add or update tests in `test/picker_spec.lua` or `test/sync_spec.sh` / `test/sync_driver.lua`. New public functions must have coverage; new behaviour visible in the list/statusline must have an extmark or render assertion.
2. **Run tests** — `bash test/run.sh` must exit 0 before the work is done.
3. **CLAUDE.md** — update any section that describes changed behaviour (state fields, function signatures, UI layout, architecture notes). Keep descriptions precise; this file is the authoritative developer reference.
4. **README.md / README.ru.md** — update user-facing content (feature list, ASCII diagram, keymaps table, statusline section) if the change is visible to end users. README.ru.md must stay in sync with README.md.

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

- `test/picker_spec.lua` — headless, synchronous. Covers: scan/filter/render (tree format, `dd.mm.yyyy - title`), extmarks (`NotesTitle` byte-13 offset, `NotesConflict` on note+folder rows, `NotesCut`/`NotesActive` priorities), conflict op-blocks (`cut_note`/`paste_note`/`delete_note`/`rename_folder`/`delete_folder` refuse conflicted), CRUD (create/delete note+folder, `rename_folder`, `cut_note`+`paste_note`, write-before-rename for unsaved edits), delete-open-note→placeholder (no `E211`, `current_file` cleared), `close_interactive` Discard reload-from-disk, live-title autocmd dedup, `git.repo_url` (scp/ssh/https), `set_sync_status` (braille spinner, Unicode fallback, `config.sync_icons.syncing`, no crash on unknown status), `toggle_panels` (hide/show/close-while-hidden). Nested folders: recursive `scan()` (full relative `folder` path), `build_folders()` drill-down (root shows only top-level children; a drilled-in level shows only its own children, not grandchildren), `change_folder()` (`o` drills in / goes up / no-op at the true root), recursive folder freshness (a note in a grandchild bumps an ancestor), `create_folder` scoped to the current drill-down level, `rename_folder`/`delete_folder` on nested paths (prefix rewrite of `current_folder`/`main_folder`, fallback-to-parent navigation), recursive conflict highlight (a deeply nested conflict highlights an ancestor folder row), disk-based `validate_folder`, main-row left-truncation at narrow `folders_width` (`fit_left` keeps the current folder's name and the `..` hint visible instead of hiding them behind Neovim's right-truncation). Folder move (cut/paste): `cut_folder` mark/cancel and true-root refusal, `cut_folder`/`cut_note` mutual exclusion, `paste_folder` moving a nested folder to a sibling (notes travel with it, destination is drilled into, cursor lands on the moved folder's row), guards against moving a folder into its own subtree and against a destination name collision, conflict guard on both `cut_folder` and `paste_folder`. Run alone: `nvim --headless -l test/picker_spec.lua`.
- `test/sync_spec.sh` + `test/sync_driver.lua` — integration: bare `remote.git` + two clones, drives `sync_on_exit`/`pull`/`restore` via `git._on_idle` callbacks. **S1** remote-add pull; **S2** same-file conflict→markers+`MERGING`+not pushed, resolve→committed+pushed; **S2-guard** markers in place must not commit; **S3** different-file auto-merge; **S4** remote-delete; **S5** diverged+dirty→merge; **S6** local-ahead+remote-advanced→merge+push; **S7** accidental-rm restore; **S8** conflict on open→markers+no broken state; **S9** modify/delete→auto-resolve keep file; **S10** dirty same-file conflict on open→real `MERGE_HEAD` (not autostash orphan), no stash leak, next sync must not commit marker file. State asserted via `.git/MERGE_HEAD` and `grep '^<<<<<<< '`.

Smoke test:

```bash
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua print(require('notes').config.dir)" \
  -c "qa!"
```

