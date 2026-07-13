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
      picker.lua — filetree explorer model: scan folders+notes, title-from-content, build/render tree, CRUD/move, keymaps
      ui.lua     — two windows in a tab (explorer + editor): open, close, open_in_edit, show_placeholder, nav keymaps
  README.md
  CLAUDE.md
```

## macOS-Notes model (high level)

The plugin imitates the macOS Notes app, presented as a single filetree explorer:
- **No manual filenames.** Each note is an opaque **ID file** (timestamp `%Y%m%d%H%M%S.md`,
  e.g. `20260627143000.md`). Its **title is the first non-blank line** of its content; an empty
  note is titled `New Note`. The ID never changes on edit, so titles never churn git history or
  collide. The editor opens notes as `markdown`.
- **Single filetree explorer:** one tree window on top (folders and notes together, any depth),
  with the editor below. No search box, no separate folders/notes columns.
- **Folders nest to any depth and expand/collapse in place.** All folders start **collapsed**.
  Each row is indented `2 * depth` spaces. At every level, folders are listed before notes;
  siblings (folders among themselves, and notes among themselves) are sorted so the one whose
  subtree has the most recently edited note comes first (folders) or the most recently edited/empty
  one comes first (notes). Folder rows show a closed/open glyph (configurable via
  `config.tree_icons`, Nerd Font or Unicode fallback); notes have no icon by default (indent + date
  distinguish them). Pressing `o` or `<CR>` on a folder toggles `state.expanded_folders[path]` and
  re-renders in place; pressing it on a note focuses the editor. Empty folders persist via a hidden
  `.gitkeep`.
- **Notes are sorted** empty-first (pinned top) then by mtime descending, within each folder; each
  notes row reads `dd.mm.yyyy - <title>` (date is display-only, from mtime). **The title updates
  live while typing** (before `:w`) via a `TextChanged`/`TextChangedI` autocmd on the editor buffer.
- **Context folder:** every create/paste action targets the "context folder" — the folder under the
  cursor, or the folder of the note under the cursor. A **trailing blank row** at the end of the
  tree (rendered by `render_tree`, not a real tree item) resolves to the root (`''`) when nothing is
  under the cursor there — the only way to explicitly target the root once folders exist at the top
  level (a root-level folder's own row targets *itself*, not the root).
- **Move by cursor:** `x` marks a note or a folder under the cursor — both use the same `NotesCut`
  highlight (over the title text for a note, over the row text for a folder), backed by `Visual`;
  focus stays put. Pressing `x` again on the already-marked item cancels the move. Marking a note
  clears any marked folder and vice versa — only one item can be marked at a time. The user
  navigates anywhere in the tree (expanding/collapsing as needed, or landing on the trailing blank
  row for the root) and presses `p` to drop the marked note or folder into the context folder
  (`paste_note` is the bound function; it dispatches to `paste_folder()` when a folder, not a note,
  is marked). A folder can't be moved into itself or one of its own descendants. After the drop the
  destination folder auto-expands (so the moved item is visible) and the cursor lands on the moved
  note/folder's row (the moved item's mtime is bumped to now, so it also sorts first among its new
  siblings).
- **Same keys, dispatched by row type:** `o`/`<CR>` (expand/collapse vs. focus editor), `d`
  (`delete_note`/`delete_folder`), `x` (`cut_note`/`cut_folder`) all read the item under the cursor
  and act accordingly. `a` always creates a note, `A` always creates a folder — both in the context
  folder — since a single tree has no "current column" to infer intent from. `r` (rename) only
  applies to folders.
- **Conflicts stay in the file.** A git merge conflict is left as standard markers in the note
  (no dialog); the conflicted note title and its folder row (any ancestor, recursively) get a wavy
  error underline (`NotesConflict`). The user edits the markers out and saves — that completes the
  merge and pushes. Move/rename/delete of a conflicted note is blocked until it is resolved.

All user-facing strings (labels, prompts, notifications) are in English; only code comments may
be in Russian (author's preference).

## Architecture

### Module dependency graph

```
init.lua    ──requires──▶  git.lua
            ──requires──▶  ui.lua
            ──requires──▶  picker.lua
picker.lua  ──requires──▶  notes (init)   [for config/state]
            ──requires──▶  notes.ui       [open_in_edit, tree_icons]
ui.lua      ──requires──▶  notes (init)   [for config/state]
            ──requires──▶  notes.picker   [attach keymaps, live title, populate]
git.lua     ──requires──▶  notes (init)   [for config]
```

### State (`init.lua → M.state`)

All mutable runtime state lives in one table in `init.lua`. Sub-modules access it via `require('notes').state`. Never cache the state table in a local variable at module load time — always call `require('notes').state` inside functions to get the live reference.

```lua
M.state = {
  synced           = false, -- pull already ran this session; prevents duplicate pulls
  closing          = false, -- re-entrancy guard for close()
  tab              = nil,   -- tabpage handle for the notes tab
  explorer_win     = nil,   -- window id of the explorer (tree) window
  explorer_buf     = nil,   -- buffer id of the explorer (tree) window
  edit_win         = nil,   -- window id of the editor split
  edit_buf         = nil,   -- buffer id of the editor split (swapped on open_in_edit)
  current_file     = nil,   -- path of the note currently open in the editor
  cut              = nil,   -- path of the note marked for moving (set by `x`)
  cut_folder       = nil,   -- relative path of the folder marked for moving (set by `x`)
  expanded_folders = nil,   -- set { [rel folder path] = true } of expanded folders; nil = none
  notes_all        = nil,   -- full scan: array of { file, folder, title, mtime, empty }
  tree_items       = nil,   -- flat tree rows; buffer line n → tree_items[n]
  conflicts        = nil,   -- set { [abs path] = true } of unmerged notes; nil = none. Set by git.lua, read by picker render/blocks
  panels_hidden    = false, -- true while the explorer is toggled off (toggle_panels)
}
```

`tree_items[n]` is either `{ type = 'folder', path, name, depth, expanded }` (`path` relative,
`name` the leaf) or `{ type = 'note', file, folder, title, mtime, empty, depth }` (`file` absolute).
Building it (`build_tree`) recurses only into folders present in `expanded_folders`, so the array
never contains a row whose ancestor chain isn't fully expanded.

### Config (`init.lua → M.config`)

Defaults are merged with user opts via `vim.tbl_deep_extend` in `setup()` (deep merge, so users can override individual `keys` entries). Sub-modules read config through `require('notes').config` (never cached at module load).

`config.keys` holds every remappable binding (`open_file`, `create`, `create_folder`, `delete`, `rename`, `move`, `paste`, `refresh`, `open_github`, `scroll_down`, `scroll_up`, `close`, `window_nav`, `toggle_panels`, `change_folder`). `open_file` and `change_folder` are both bound to the same dispatcher (`picker.toggle_expand`): a folder under the cursor expands/collapses, a note focuses the editor. `create` (`a`) always makes a note and `create_folder` (`A`) always makes a folder, both inside the "context folder" (`picker.context_folder()`: the folder under the cursor, or the folder of the note under the cursor, or `''` — root — when nothing is under the cursor, e.g. the trailing blank row). `delete` (`d`) dispatches to `delete_note`/`delete_folder` by row type. `move` (`x`) dispatches to marking a note or a folder (mutually exclusive) via `picker.cut()`. `paste` (`p`) drops the marked item into the context folder via `picker.paste()`, which dispatches to `paste_folder()` when `state.cut_folder` is set, else `paste_note()`. `rename` (`r`) only applies to folders. `toggle_panels` (default `<C-t>`) shows/hides the explorer window. `config.list_height` sets the explorer window height in rows. The `close` default is `q`.

`config.sync_icons` — optional table `{ idle, syncing, conflict }` with custom icon strings for each sync state. When `nil` (default), the plugin auto-selects: for `syncing` — animated braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) unless `sync_icons.syncing` is set; for `idle`/`conflict` — Nerd Font glyphs (nf-fa-check / nf-cod-warning) if `nvim-web-devicons` is already loaded in the session (used as a proxy for Nerd Fonts being present), otherwise plain ASCII fallback (`✓` / `!`). No icon is shown when `config.repo == ''`.

`config.tree_icons` — optional table `{ folder, folder_open, note }` overriding the tree glyphs. When `nil` (default), the plugin auto-selects per key: Nerd Font glyphs (nf-md-folder `` / nf-md-folder_open ``) if `nvim-web-devicons` is loaded, otherwise Unicode arrows (`▶` / `▼`); `note` defaults to `''` (no icon) either way. Resolved by `ui.tree_icons()`, called from `picker.render_tree()`.

`window_nav` is a single prefix (default `<C-w>`), not a full two-key sequence. `set_nav_keymaps` maps just the prefix and then reads the next char with `vim.fn.getcharstr()`. The two windows are stacked vertically, so navigation accepts `h/j/k/l` and dispatches to `vim.cmd('wincmd '..key)` (native spatial move). Exception: pressing `k` while in `edit_win` explicitly jumps to `explorer_win` rather than using `wincmd k` (equivalent with only two windows, but kept explicit for clarity/robustness). Reading the char synchronously avoids the `timeoutlen` delay/flakiness that separate `<C-w>h/j/k/l` maps suffer from. It is mapped in both `n` and `i` modes (the editor may be in insert) and calls `stopinsert` before reading the direction so the key isn't typed into the buffer.

`scroll_down`/`scroll_up` (default `<C-n>`/`<C-p>`) in the **explorer** buffer scroll the editor window (`<C-e>`/`<C-y>` via `ui.scroll_edit`).

### Filetree explorer model (`picker.lua`)

- `title_of(file)` — reads only the first lines (`fn.readfile(file, '', 20)`) and returns the first non-blank, trimmed line plus `empty=false`; an all-blank/missing file returns `New Note, empty=true`.
- `scan()` — walks `config.dir` with `vim.fs.dir` **recursively, to any depth**. Collects every folder's relative path (`"Work"`, `"Work/Projects"`, …) into a module-local `all_folders` (not part of `state`; `build_tree()` derives the tree from it) and `state.notes_all` (`{ file, folder, title, mtime, empty }` for every file, where `folder` is its full relative path — `''` at the root, `"Work/Projects"` when nested). Skips hidden entries (`.` prefix → excludes `.git`/`.gitkeep`). Sorts `notes_all` **empty-first, then mtime descending**.
- `folder_recursive_mtime(folder_rel)` — module-local. Freshness of a folder = the most recent mtime among all notes in it **and all its descendants** (matched by exact `folder` equality or a `folder_rel .. '/'` prefix); falls back to the directory's own mtime if the subtree has no notes at all (so a newly created empty folder sorts to the top among its siblings). Returns `mtime, has_note` — `has_note` feeds the tie-break below.
- `prune_expanded()` — module-local. Drops `state.expanded_folders` keys not present in `all_folders` (folder deleted/renamed outside a path that already updates the set itself). Called from `populate()` after `scan()`.
- `direct_children(folder_rel)` / `direct_notes(folder_rel)` — module-local. Immediate subfolders (from `all_folders`) and direct notes (from `state.notes_all`) of `folder_rel` (`''` = root). `direct_children` sorts by `folder_recursive_mtime` with a **strict total order** (`table.sort` is not stable): freshness → note-bearing (via `has_note`) → name. The note-bearing tie-break is what makes `paste_note` reliable: moving a note out of a folder empties the source and bumps *its directory* mtime to the same second as the moved note's bumped mtime in the destination — without the tie-break the unstable sort could float the (empty) source above the destination. `direct_notes` needs no extra sort — `scan()` already sorted `notes_all`.
- `build_tree()` — recursively walks from the root (`''`, depth 0), pushing **folders before notes** at each level into `state.tree_items`; a folder is only descended into (children appended, depth+1) when `state.expanded_folders[path] == true`. `state.expanded_folders` is lazily initialised to `{}` here if `nil`.
- `item_at_cursor()` — reads `state.tree_items[cursor_row]` in `explorer_win`; `nil` when the window is invalid or the cursor is past the last real row (the trailing blank row, or an empty tree).
- `context_folder()` — public. The folder under the cursor (`it.path`), or the folder of the note under the cursor (`it.folder`), or `''` (root) when `item_at_cursor()` returns `nil`.
- `render_tree()` — writes one line per `tree_items` entry, indented `string.rep('  ', depth)`: a folder is `<glyph> <name>/` (glyph from `ui.tree_icons()`, closed/open by `it.expanded`); a note is `[<note-icon> ]dd.mm.yyyy - title` (icon only if `tree_icons.note ~= ''`). Appends **one trailing blank line** after a non-empty tree — the "root drop zone" that `context_folder()` and `item_at_cursor()` resolve to nothing (see the model section above); an empty tree instead shows `(no notes)` with no drop zone (nothing to create/paste there but the implicit root, which `create_note`'s dedupe/`create_folder` already default to when nothing is under the cursor). Extmarks: `NotesDir` (hl_group, priority 0) on every folder row; `NotesTitle` (priority 100, combine) on a note's title text only, starting at the byte offset actually used for that row's prefix (indent + optional icon + date), **not** a fixed constant — deep indentation and custom icons change the offset per row; `NotesConflict` (priority 300, combine) on a note in `state.conflicts` or a folder where `folder_has_conflict(path)` is true (recursive over the subtree); `NotesCut` (priority 200) on the note/folder matching `state.cut`/`state.cut_folder`. Then `restore_cursor(prev_key)` and `M.highlight_active()`.
- **Cursor preservation across re-renders:** `render_tree()` captures the cursor's current item as an opaque key (`item_key`: `'note:'..file` or `'folder:'..path`) **before** rewriting the buffer, but only when `explorer_win` is the focused window at call time. After redrawing, `restore_cursor` tries that key first (`cursor_to`, a linear scan of the new `tree_items`), then falls back to `current_file`'s row, then row 1. This is what makes expand/collapse, background git-sync refreshes, and marking (`cut`) all keep the cursor on the same logical item even though row numbers shift — no action needs its own manual cursor save/restore (unlike the old two-column model, where `cut_note`/`cut_folder` did this by hand).
- `highlight_active()` — clears `ns_active` and adds `hl_group='NotesActive'` extmark (`end_col=#line`, `priority=0`) to the row matching `state.current_file`. `priority=0` lets the cut highlight (200) win when both land on the same row. Uses `hl_group` not `line_hl_group` so priority ordering applies (a `line_hl_group` extmark is a separate rendering layer that overrides any overlapping `hl_group` extmark regardless of priority).
- `update_live_title(buf, file)` — reads the first 50 lines of `buf` in-memory (no disk read), finds the first non-blank line as the new title (or `EMPTY_TITLE`), updates `title`/`empty` on the matching entry in **both** `state.notes_all` and `state.tree_items`, then calls `render_tree()` and `ui.refresh_editor_statusline()`. Registered as a `TextChanged`/`TextChangedI` autocmd on the editor buffer in `open_in_edit` so the tree stays in sync while the user types.
- `populate()` = `scan` + `prune_expanded` + `build_tree` + `render_tree`. `refresh` is an alias for `populate`; both run on open and after each git step.
- **Selection = `explorer_win` cursor.** `item_at_cursor()` reads it and indexes `state.tree_items`.
- `toggle_expand()` (`o` / `<CR>`) — a folder under the cursor: flips `state.expanded_folders[path]` (set to `true`, or `nil` to remove — not `false`, so the table stays a clean set), calls `build_tree()` + `render_tree()`, then explicitly re-centers the cursor on that same folder's row via `cursor_to` (its row number may shift as siblings/children appear or disappear). A note under the cursor: focuses `edit_win`, no tree change.
- `open_selected()` (CursorMoved auto-open) → if the item under the cursor is a note, `ui.open_in_edit(file)` + `highlight_active()`; a folder or the drop zone is a no-op.
- **Conflict guard:** while a note is in a merge conflict (`is_conflicted(file)` = `state.conflicts[file]`), destructive ops on it are refused with `Resolve the conflict first`: `cut()`/`delete_note` (the conflicted note), `paste_note` (when `state.cut` is conflicted), and `rename_folder`/`delete_folder`/`cut()`/`paste_folder` (when the folder holds any conflicted note via `folder_has_conflict`, recursive over the folder's full subtree). Moving a file (or a whole folder) with an unmerged index entry via `fn.rename` would desync the index from the working tree, so the user must resolve in the editor first.
- Actions (each calls the module-local `sync()` after a change, except `cut()` which only re-renders — marking doesn't touch the filesystem). `sync()` is a no-op when `repo == ''` **or while `state.synced` is false** (the initial `restore`/`pull` is still running) — the latter gate is critical: a CRUD `sync()` firing during the open `M.pull` would run git concurrently with it and could push a commit that makes the open pull abort on a still-untracked file (`Cannot fast-forward your working tree`). Anything created during that window is committed by the post-pull `sync_on_exit()` in `init.open` (the same `synced` gate already protects `BufWritePost`). Otherwise `sync()` just calls `git.sync_on_exit()` — fully async and serialised by that function's `syncing`/`sync_pending` mutex. It does **not** run its own `git add -A`: `sync_on_exit`'s `commit_only` stages everything (including a deletion, so `restore()` can't resurrect it).
  - `create_note()` (`a`) — target folder = `context_folder()`. If that folder already holds an **empty** note, it is reopened instead of creating a second (one empty note per folder). Otherwise writes an empty **ID file** (`new_id` = `%Y%m%d%H%M%S.md` + collision suffix before the extension) and opens it in the editor **without moving window focus**. Either way, the target folder is **auto-expanded** (`expanded_folders[folder] = true`, skipped when `folder == ''`) before `populate()` so the new/reused note is visible, then `cursor_to(note_key(...))` parks the explorer cursor on it explicitly (row-number preservation in `render_tree` would otherwise try to keep the *old* cursor position, not follow the new note).
  - `create_folder()` (`A`) — `vim.ui.input` name (rejects `/` and `\`: one leaf name per call, backslash rejected too so a Windows-style path can't smuggle in a nested structure), created as a child of `context_folder()`, `mkdir -p`, writes a hidden `.gitkeep` so the empty folder can commit. Deeper nesting is reached by expanding and creating again, not by typing a path with `/`. Auto-expands the parent and parks the cursor on the new folder, same pattern as `create_note`.
  - `rename_folder()` (`r`) — works on the folder under the cursor; if there isn't one, warns `Select a folder to rename`. The input default is the folder's leaf name (rejects `/` and `\`); only that leaf changes, its parent path stays put. If the open note is inside the folder **and modified, writes it first** (so unsaved edits survive), then `fn.rename`s the directory; if the open note is inside, reopens the editor at the new path and wipes the stale buffer. **`state.expanded_folders` keys are rewritten**: any key equal to the renamed folder or nested under it gets its path prefix swapped from old to new (a fresh table is built rather than mutated in place, since Lua can't safely rewrite keys during iteration). **A pending cut is rewritten too:** if `state.cut` (an absolute note path) is inside the renamed folder, its path is rewritten to the new location the same way; `state.cut_folder` gets the same prefix-swap as the `expanded_folders` keys — otherwise a pending `paste` after the rename would target a path that no longer exists.
  - `delete_note()` / `delete_folder()` — dispatched by `delete()` (`d`) based on the row type under the cursor. `confirm`, then `fn.delete`; if the open note (or, for a folder, a note inside it) is removed, calls `ui.show_placeholder()` so the editor drops the orphaned buffer (avoids `E211`). `delete_folder` also drops the deleted folder **and any of its descendant keys** from `state.expanded_folders` (there is no more "current drilled-into level" to fall back to — the tree just stops offering those now-nonexistent rows). **A pending cut inside the deleted subtree is cleared:** if `state.cut` (absolute note path) or `state.cut_folder` (relative folder path) was inside the deleted folder, it is reset to `nil` — otherwise a subsequent `paste` would try to move a path that no longer exists on disk.
  - `cut()` (`x`) — dispatches by row type to marking `state.cut` (note) or `state.cut_folder` (folder), clearing the other (a note and a folder can't be marked at the same time). Pressing `x` on the item that is **already** marked cancels the move. Calls `render_tree()` only (no rescan — marking doesn't change the tree's shape, only its highlight), which via the generic cursor-preservation mechanism above keeps the cursor on the same row without any manual save/restore.
  - `paste()` (`p`) — the key's bound function; dispatches to `paste_folder()` when `state.cut_folder` is set, else `paste_note()`.
  - `paste_note()` — if `state.cut` is set, moves the marked note into `context_folder()` via `fn.rename`; if the moved note is the open one **and modified, writes it before the rename** (so unsaved edits survive); reopens the editor at the new path if the note was open; clears `state.cut`. After the rename it **bumps the moved file's mtime to now** (`vim.uv.fs_utime`) — `fn.rename` preserves mtime, and folder recency = the newest note's mtime, so this floats the destination folder to the top among its siblings (and the moved note to the top of its new folder's notes). Auto-expands the destination, `populate()`s, then `cursor_to(note_key(target))` parks the cursor on the moved note.
  - `paste_folder()` (dispatched from `paste()` when `state.cut_folder` is set) — moves the marked folder (any depth) into `context_folder()` via `fn.rename` on the directory. Refuses if the marked folder is now conflicted, or if the destination **is** the marked folder or one of its own descendants (`Cannot move a folder into itself` — checked by prefix match on the relative paths), or if a folder with the same leaf name already exists at the destination. A no-op (silently re-renders) if the destination is the folder's current parent (moving it "into" where it already is). Persists unsaved edits first if the open note lives inside the moved subtree (same pattern as `rename_folder`), reopens the editor at the new path, and bumps the moved directory's mtime to now (same reasoning as `paste_note`). **`state.expanded_folders` keys are rewritten** the same way `rename_folder` does (old prefix → new), then the destination is auto-expanded and the cursor parked on the moved folder's new row via `cursor_to(folder_key(newrel))`.
- `attach_explorer(buf)` — single set of normal-mode maps on the one buffer: `h`/`l` → `<Nop>` (block horizontal cursor movement), `open_file`/`change_folder` → `toggle_expand`, `create` → `create_note`, `create_folder` → `create_folder`, `delete` → `delete` (dispatcher), `rename` → `rename_folder`, `move` → `cut`, `paste` → `paste`, `scroll_down`/`scroll_up` → `ui.scroll_edit`, `refresh`, `open_github`, `toggle_panels` → `ui.toggle_panels`, `close`. `ui.set_nav_keymaps` adds the `window_nav` prefix to both buffers; the editor buffer also gets normal-mode `close` and `toggle_panels` maps in both `open_in_edit` and `show_placeholder`.

### Two windows (`ui.lua`)

A dedicated tab (`tabnew`) holds two windows: the **explorer** (top, statusline ` Explorer`, `config.list_height` rows, `winfixheight`) and the **editor** (bottom, statusline ` folder/title %m` when a note is open or ` Editor` when no note is open, remaining height). The explorer window has `cursorline = false` — only the terminal cursor shows the position; the active note is marked by the `NotesActive` extmark instead.

- `set_sync_status(status)` — updates the tab's `t:title` variable. For `'syncing'`: if `config.sync_icons.syncing` is set, uses it as a static icon; otherwise starts an animated braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) via `vim.uv.new_timer` (100 ms interval, first frame set synchronously so there is no initial lag). For `'idle'` / `'conflict'`: stops the spinner (`stop_spin()`), then sets a static icon from `SYNC_ICONS` — Nerd Font glyph or plain Unicode depending on `has_nerd_fonts()`. `has_nerd_fonts()` returns true if `package.loaded['nvim-web-devicons']` is non-nil **or** if `pcall(require, 'nvim-web-devicons')` succeeds. No-op when the tab is invalid or `config.repo == ''`. `stop_spin()` is called at the start of every `set_sync_status` call and in `M.close()`.
- `tree_icons()` — public. Resolves the closed/open folder glyphs and the note icon: per key, a `config.tree_icons` override wins, otherwise `TREE_ICONS[key]` picks the Nerd Font glyph (`has_nerd_fonts()`) or the plain Unicode fallback; `note` has no built-in row and defaults to `''` unless overridden. Called from `picker.render_tree()` on every render (cheap: no caching, so toggling `nvim-web-devicons` or `config.tree_icons` mid-session takes effect on the next redraw).
- `toggle_panels()` — hides or restores the explorer window. **Hiding:** stores `explorer_win` in a local, nils out `state.explorer_win`/`state.explorer_buf` and sets `state.panels_hidden = true` *before* calling `nvim_win_close` — so the `WinClosed` autocmd (which compares against `state.explorer_win`) does not mistake the controlled close for an external closure and call `notes.close()`. The `bufhidden=wipe` buffer means closing it also wipes the buffer and auto-removes its buffer-local `CursorMoved` autocmd. **Showing:** recreates the buffer and window (mirrors the layout code in `open()`), re-attaches `picker.attach_explorer` and `set_nav_keymaps`, calls `setup_panel_autocmds(st)` for a new CursorMoved autocmd, and calls `picker.populate()`.
- `open()` — `setup_highlights()` (defines `NotesDir`/`NotesFile`/`NotesCut`/`NotesActive`/`NotesTitle`/`NotesConflict`; `NotesConflict` is `undercurl` with `sp` from `DiagnosticError` → `ErrorMsg` fallback), runs `tabnew`, pins tab label via `set_sync_status('syncing')` (sets `t:title`; installs `vim.o.tabline` if unset, saves old in `_old_tabline`), seats the placeholder in the base window (which becomes the editor), then `split='above'` → the explorer. Attaches keymaps, registers autocmds, focuses the **explorer**.
- `tabline()` — the expression behind `vim.o.tabline` when the plugin installs its own. It renders every tabpage's label, using each tab's `t:title` var when present (so the notes tab always reads `notes.nvim` regardless of which inner window is focused) and falling back to the focused window's buffer name otherwise. Only installed when the user had no `tabline`; `close()` restores `_old_tabline`. Statusline/tabline plugins that read `t:title` get the pinned label for free.
- `editor_path_label(path)` — module-local helper. Strips `config.dir/` from `path` to get the relative path, extracts everything before the last `/` as the folder component (`Notes` when the note lives at the root), then looks up the note's current title in `state.notes_all` (falls back to `'New Note'` if not found yet, e.g. during `create_note` before `populate`). Escapes `%` characters in both components to `%%` so they are not interpreted as statusline sequences. Returns `'folder/title'` (supports any depth of nesting — `folder/subfolder/title`).
- `refresh_editor_statusline()` — public. Rebuilds the editor statusline as `' ' .. editor_path_label(current_file) .. ' %m'` and assigns it to `edit_win`. No-op when `edit_win` is invalid or `current_file` is nil. Called from `open_in_edit` and from `picker.update_live_title` so the path stays current while the user types.
- `open_in_edit(path)` — first **writes the current editor buffer if it's a modified real file** (`:silent write`), then `:edit`s the new file inside `edit_win` via `nvim_win_call`. The write is essential: without it, re-displaying a modified buffer (notably opening the same file again) fails with `E37: No write since last change`, and any unsaved edits would also be lost at `close()`. Then repoints `state.edit_buf`/`current_file`, sets `filetype=markdown` (notes are ID-named with no extension), and sets the editor window options **like a normal file** (`number`, `relativenumber`, `cursorline`, `signcolumn=no`, soft-wrap — `wrap`/`linebreak`/`breakindent`, `spell=false`, `conceallevel=2`, `concealcursor='nc'`, `statusline=' folder/title %m'` from `editor_path_label`). `show_placeholder` resets to plain (no number/cursorline/signcolumn, `wrap=false`, `conceallevel=0`, `statusline=' Editor'`). Does *not* pin `StatusLine`/`CursorLineNr` in `winhighlight`, so the user's global `UpdateInsertModeColor` (triggered on `InsertEnter`/`InsertLeave`) recolors the editor itself. Re-applies `set_nav_keymaps` + a normal-mode `close_interactive` map + a `TextChanged`/`TextChangedI` autocmd (calls `picker.update_live_title`) in `NotesEditLiveTitle` augroup with `nvim_clear_autocmds` first (prevents stacking on revisit). It **does not move focus** — opening a note leaves the cursor in the explorer window.
- `show_placeholder()` — seats a fresh `nofile`/`bufhidden=wipe` scratch buffer (single line `Select a note or create a new one (a).`) in `edit_win`, resets `state.edit_buf` and `state.current_file = nil`, sets plain window options (no number/cursorline/signcolumn, `statusline=' Editor'`), and re-applies `set_nav_keymaps` + the normal-mode `close` map. Crucially it **force-wipes the previous real-file buffer** (only when its `buftype == ''`): without this, the just-deleted backing file makes `checktime` raise `E211: File … no longer available`. Called from `open()` for the initial empty editor and from `picker.delete_note()`/`delete_folder()` when the deleted path is (or contains) the open note.
- `scroll_edit(delta)` — scrolls `edit_win` by one line via `nvim_win_call` (`<C-e>` for `delta > 0`, `<C-y>` otherwise). Bound to `scroll_down`/`scroll_up` in the explorer buffer.
- `close()` — sets `st.closing = true`, clears all state fields (including `explorer_win`/`explorer_buf`/`cut`/`cut_folder`/`expanded_folders`/`tree_items`), then `tabclose <tabnr>`. The `st.closing` guard in `WinClosed` prevents recursion when `tabclose` triggers that autocmd for each closing window.
- `set_nav_keymaps(buf)` — adds the `window_nav` prefix (default `<C-w>`) in `n`+`i` modes; the handler `stopinsert`s, reads the next char via `getcharstr`, and runs `wincmd h/j/k/l`. Special case: `k` from `edit_win` jumps explicitly to `explorer_win`.

`setup_autocmds(st)` registers in the `NotesWin` group:
- `WinClosed` → closing either window triggers `notes.close()` (guarded by `st.closing`). The handler compares against the live `st.explorer_win`/`st.edit_win` — which are nil'd **before** the controlled close in `toggle_panels`, so panel toggle does not trigger the full close.
- `BufWritePost` (pattern `config.dir .. '/*'`, matches subdirs) → calls `picker.refresh()` immediately (so sort order and title update without waiting for git), then starts `git.sync_on_exit()`. Skipped when `st.closing` is true and while `st.synced` is false (to avoid committing a dirty tree before the initial restore/pull completes).

`setup_panel_autocmds(st)` — module-local helper, registers in the **`NotesPanels`** group (separate from `NotesWin` so toggling panels can re-register without disturbing WinClosed/BufWritePost):
- `CursorMoved` on `explorer_buf` → if the current window is `explorer_win`, calls `picker.open_selected()` (auto-open when the cursor lands on a note). The `current_win` guard prevents false triggers when `render_tree()` restores the cursor while focus is elsewhere.
Called from `setup_autocmds` on initial open, and from `toggle_panels` on each restore of the panel (with `{ clear = true }` so stale entries from the previous show are removed; a wiped buffer also auto-removes its buffer-local autocmd when closed).

### Public API (`init.lua`)

- `is_open()` — checks `state.tab` validity. If the tab was closed externally (e.g. `:tabclose`), self-heals by wiping all stale state fields so old window IDs cannot trigger false autocmd matches on a future session.
- `open()` — guard against double-open; calls `ui.open()` + `picker.populate()`, then kicks off the async git chain (ensure_repo → restore → pull).
- `close()` — calls `ui.close()` then `git.sync_on_exit()`. Does not prompt; safe to call from autocmds.
- `close_interactive()` — checks the editor buffer for unsaved changes. If modified, shows a `confirm()` dialog: **Save** (`:silent write` then close+sync), **Discard** (`:silent edit!` to reload the saved version from disk, then close+sync), **Cancel** (abort). The `:edit!` on Discard is essential: the editor buffer is hidden (not wiped) on close, so without reloading, its unsaved edits would reappear the next time the same note is opened (`:edit` reuses the modified hidden buffer instead of reading disk). Bound to the `close` key in both windows. `toggle()` uses this as well.

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

**Concurrency guard:** module-level `syncing` / `sync_pending` serialise concurrent calls. A call arriving mid-chain sets `sync_pending` and returns; `finish()` (every terminal point) clears `syncing` and, if pending, starts one more run — collapsing queued calls into a single follow-up. At idle `finish()` calls `picker.refresh()` (so highlight/tree reflect the new `state.conflicts`), updates the tab title via `ui.set_sync_status('conflict')` or `set_sync_status('idle')` depending on `state.conflicts`, and fires the one-shot `M._on_idle` test hook.

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

`open_github()` (bound to `O` in the explorer) converts `config.repo` to a browsable `https://host/user/repo` URL via the pure helper `repo_url(repo)` (handles `git@host:…`, `ssh://git@…`, and plain `https://…`, stripping a trailing `.git`) and opens it with `vim.ui.open`. No-op with a WARN if `repo == ''`. `repo_url` is split out from `open_github` so the conversion can be unit-tested without invoking `vim.ui.open`.

`ensure_repo()` handles three cases:
- `.git` exists → call `cb()` immediately.
- `repo == ''` → just `mkdir` the directory and call `cb()`.
- Otherwise → `git clone <repo> <dir>` then call `cb()`.

## Post-development checklist

After every feature or fix, in this order:

1. **Tests** — if the change touches picker/UI/git logic, add or update tests in `test/picker_spec.lua` or `test/sync_spec.sh` / `test/sync_driver.lua`. New public functions must have coverage; new behaviour visible in the tree/statusline must have an extmark or render assertion.
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

- `test/picker_spec.lua` — headless, synchronous. Covers: recursive `scan()` (full relative `folder` path at any depth), `build_tree()`/`render_tree()` (folders before notes at the same level, `2*depth`-space indentation, collapsed-by-default with expand/collapse via `toggle_expand`, a deeply nested item only visible once every ancestor is expanded), extmarks (`NotesTitle` starting at the row's actual prefix length rather than a fixed offset, `NotesConflict` on a note and recursively on every ancestor folder row, `NotesCut`/`NotesActive` priorities over `NotesDir`), `tree_icons()` (Unicode fallback in headless mode, `config.tree_icons` override reflected in a re-render), conflict op-blocks (`delete_note`/`cut`/`paste`/`rename_folder`/`delete_folder` all refuse on a conflicted note or a folder holding one anywhere in its subtree), CRUD on the tree (`create_note`/`create_folder` auto-expand their target and park the cursor on the new row; `create_note` dedupe; `rename_folder`; `cut`+`paste` for both notes and folders, including the mtime-tie destination-ordering repro; write-before-rename for unsaved edits), the "root drop zone" (a trailing blank row past the last tree item resolves `context_folder()` to `''`, the only way to target root once any folder exists there), cursor preservation across re-renders (`cut`, background `refresh()`, an unrelated expand elsewhere in the tree — none of these should move the cursor off the item it was on), delete-open-note→placeholder (no `E211`, `current_file` cleared), `close_interactive` Discard reload-from-disk, live-title autocmd dedup, `git.repo_url` (scp/ssh/https), `git.conflict_label`, `set_sync_status` (braille spinner, Unicode fallback, `config.sync_icons.syncing`, no crash on unknown status), `toggle_panels` (hide/show/close-while-hidden, now a single window). Stale-reference safety: `rename_folder`/`paste_folder` rewrite `state.expanded_folders` keys (and a pending `state.cut`/`state.cut_folder`) from the old path prefix to the new one; `delete_folder` drops the deleted folder's own key and all descendant keys from `state.expanded_folders`, and clears a pending `state.cut`/`state.cut_folder` that lived inside the deleted subtree; `prune_expanded()` drops keys for folders that no longer exist on disk (e.g. deleted outside the plugin); folder names reject both `/` and `\` (Windows path separator) in `create_folder`/`rename_folder`. **Note:** `nvim_buf_get_extmarks` treats a bare integer `start`/`end` as an extmark id, not a row — tests use a full-buffer scan filtered by row (`marks_on_row` helper), not a `(row-1, row)` range query. Run alone: `nvim --headless -l test/picker_spec.lua`.
- `test/sync_spec.sh` + `test/sync_driver.lua` — integration: bare `remote.git` + two clones, drives `sync_on_exit`/`pull`/`restore` via `git._on_idle` callbacks. **S1** remote-add pull; **S2** same-file conflict→markers+`MERGING`+not pushed, resolve→committed+pushed; **S2-guard** markers in place must not commit; **S3** different-file auto-merge; **S4** remote-delete; **S5** diverged+dirty→merge; **S6** local-ahead+remote-advanced→merge+push; **S7** accidental-rm restore; **S8** conflict on open→markers+no broken state; **S9** modify/delete→auto-resolve keep file; **S10** dirty same-file conflict on open→real `MERGE_HEAD` (not autostash orphan), no stash leak, next sync must not commit marker file. State asserted via `.git/MERGE_HEAD` and `grep '^<<<<<<< '`. Not touched by the filetree explorer refactor (git.lua is UI-agnostic).

Smoke test:

```bash
nvim --headless --clean \
  -c "lua package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path" \
  -c "lua require('notes').setup({ dir='/tmp/notes-test' })" \
  -c "lua print(require('notes').config.dir)" \
  -c "qa!"
```
