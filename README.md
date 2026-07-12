# notes.nvim

*[Русская версия](README.ru.md)*

A lightweight Neovim plugin for managing notes in a dedicated tab — modelled on the
**macOS Notes** app — with optional GitHub synchronization via Git (SSH).

<video src="https://github.com/user-attachments/assets/7ff882ff-7cfc-4739-8765-e9e4ddc6fd5f" autoplay loop muted playsinline></video>

```
──────────────┬──────────────────────────────────
 Folders      │ Notes                            ← statuslines
 Notes/        │ 26.06.2026 - Shopping list
 ├─ Work/      │ 25.06.2026 - Project idea
 └─ Personal/  │ 24.06.2026 - Report
──────────────┴──────────────────────────────────
 Notes/Shopping list                              ← statusline (folder/title)
 # Shopping list

 - [ ] Milk
 - [ ] Call the bank
```

Folders nest to any depth, shown drill-down one level at a time (`o` to enter / go up):

```
────────────────┬────────────────────────────────
 Folders        │ Notes
 Notes/Work/ .. │ 26.06.2026 - Sprint notes
 ├─ Projects/   │
 └─ Archive/    │
────────────────┴────────────────────────────────
```

## Features

- **Two-pane, macOS-Notes-style UI** — opens in a new full-screen tab: **folders** (left column) and **notes** (right column) on top, the editor on the bottom. Closing notes closes the tab.
- **Title from content** — a note has no manual filename. Its title is the **first non-blank line** of its text; an empty note is titled **"New Note"** and is always pinned to the top of the list. On disk each note is an opaque ID file (`.md` extension, e.g. `20260627143000.md`), so editing a title never churns git history or collides. The notes column shows `dd.mm.yyyy - Title`, sorted by modification time (newest first). **The title in the list updates live as you type**, without saving.
- **Nested folders, drill-down navigation** — the folders column shows one level at a time: row 1 is the current level (**"Notes"** at the root, or `Notes/<path>/ ..` once you've drilled in), followed by its immediate subfolders, sorted so the one whose subtree has the most recently edited note comes first. Press `o` on a subfolder to enter it, or `o` on row 1 to go back up. Selecting a row filters the notes column to that folder's direct notes. New folders (`a`) are created inside the current level. Empty folders are supported via a hidden `.gitkeep` so they commit and sync.
- **Move by cursor** — press `x` on a note to mark it (highlighted with the selection color); press `x` again on the same note to cancel. Then navigate to a folder in the folders column and press `p` to drop it there. The destination folder becomes the selected one and rises to the top of the folders column, and its notes fill the notes column.
- **Native editing** — the editor window behaves like a normal `markdown` file window (`number`, `cursorline`, `signcolumn`), so global `InsertEnter`/`InsertLeave` styling and statusline plugins work inside it.
- **Instant UI updates** — the note list updates immediately on `:w` (sort order, title); git sync runs in the background.
- **Full management** — same keys in each column: `a` creates (a note in the notes column, a folder in the folders column), `d` deletes; notes also support move (`x` + `p`), folders also support rename (`r`); refresh (`R`). **Every create/delete/move/rename immediately commits and pushes to GitHub.**
- **Configurable keymaps** — every action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull` (merge). On `:w`: commit + merge + push. On any create/delete/move/rename: immediate commit + merge + push. On close (`q`): commit + merge + push of any remaining changes.
- **Conflicts stay in the file** — a merge conflict is left as standard git markers in the note (no dialog). The conflicted note title and its folder name get a wavy error underline; edit the markers out, save, and the merge completes and pushes. Move/rename/delete of a conflicted note is blocked until you resolve it.
- **Unsaved changes prompt** — pressing `q` when the editor has unsaved changes shows a **Save / Discard / Cancel** dialog instead of silently writing or discarding. Choosing **Discard** reloads the saved version from disk.
- **Crash-safe** — on every open, tracked files deleted outside the plugin (e.g. an accidental `rm`) are restored from the last commit before anything is pushed, so an empty working tree never propagates to the remote.
- **Sync status icon** — the Neovim tab label shows a sync status indicator next to `notes.nvim`: an animated braille spinner (`⠋⠙⠹…`) while syncing, `✓` when idle, `!` when there is a merge conflict. Nerd Font glyphs are used automatically for idle/conflict (`nf-fa-check` / `nf-cod-warning`) if `nvim-web-devicons` is installed (required on demand, so load order doesn't matter); otherwise plain ASCII. No icon when `repo = ''`. Icons are fully configurable via `config.sync_icons`.
- **Toggle panels** — press `<C-t>` (configurable) from any window to hide the Folders and Notes columns, giving the editor the full screen; press again to restore them. Useful when writing longer notes.
- **No external dependencies** — pure Lua, no third-party plugins required.
- **Works from any directory** — open your notes regardless of the current working directory.

## Requirements

- Neovim ≥ 0.10
- Git (for sync; optional if `repo` is not set)
- SSH key configured for GitHub (if using a private repo)

## Installation

### vim.pack (built-in, Neovim 0.11+)

```lua
vim.pack.add({ src = 'https://github.com/lgick/notes.nvim' })

require('notes').setup({
  dir  = vim.fn.expand('~/.notes'),
  repo = 'git@github.com:youruser/notes.git',
})
```

### lazy.nvim

```lua
{
  'lgick/notes.nvim',
  opts = {
    dir  = vim.fn.expand('~/.notes'),
    repo = 'git@github.com:youruser/notes.git',
  },
}
```

### packer.nvim

```lua
use {
  'lgick/notes.nvim',
  config = function()
    require('notes').setup({
      dir  = vim.fn.expand('~/.notes'),
      repo = 'git@github.com:youruser/notes.git',
    })
  end,
}
```

## Configuration

```lua
require('notes').setup({
  -- Local directory where notes are stored (also the git worktree root).
  dir = vim.fn.expand('~/.notes'),

  -- SSH remote for GitHub sync.
  -- Leave empty ('') to use notes locally without any git sync.
  repo = 'git@github.com:youruser/notes.git',

  -- Height of the folders/notes row in rows (content rows, excluding statusline).
  list_height = 10,

  -- Width of the folders column.
  folders_width = 25,

  -- Keymaps (override individually; unset keys keep their defaults).
  keys = {
    open_file   = '<CR>',  -- folders: focus the notes column; notes: focus the editor
    create      = 'a',     -- folders: create a folder; notes: create a note
    delete      = 'd',     -- folders: delete the folder; notes: delete the note (confirmation)
    rename      = 'r',     -- folders: rename the selected folder
    move        = 'x',     -- notes: mark note for moving
    paste       = 'p',     -- folders: drop the marked note into the selected folder
    refresh     = 'R',     -- refresh the list
    open_github = 'O',     -- open the notes repository in the browser
    scroll_down = '<C-n>', -- notes: scroll the open note down
    scroll_up   = '<C-p>', -- notes: scroll the open note up
    close         = 'q',     -- close notes (works from any notes window)
    window_nav    = '<C-w>', -- prefix; then h/j/k/l → move between windows
    toggle_panels = '<C-t>', -- hide/show Folders + Notes columns
    change_folder = 'o',     -- folders: enter the folder under cursor / go up from row 1
  },

  -- Sync status icons shown in the tab label next to 'notes.nvim'.
  -- nil = auto: Nerd Font glyphs if nvim-web-devicons is loaded, otherwise Unicode.
  -- Set to a table to override individual icons.
  sync_icons = nil,
  -- sync_icons = { idle = '✓', syncing = '⠋', conflict = '!' },
})
```

### Keymap (suggested)

```lua
vim.keymap.set('n', '<leader>m', '<cmd>Notes<CR>', { desc = 'Notes' })
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Notes` | Open the notes tab |

### Default keymaps

All keys are configurable via `config.keys` (see above).

| Key | Action | Where |
|-----|--------|-------|
| `j` / `k` | Move cursor → filter notes to that folder | folders |
| `a` | Create a folder inside the current level | folders |
| `r` | Rename the selected folder | folders |
| `d` | Delete the selected folder (confirmation) | folders |
| `o` | Enter the folder under cursor / go up from row 1 | folders |
| `<CR>` | Focus the notes column | folders |
| `p` | Drop the marked note into this folder | folders |
| `j` / `k` | Move cursor + open note instantly | notes |
| `<CR>` | Focus the editor window | notes |
| `a` | Create a new note in the current folder (or root) | notes |
| `d` | Delete the selected note (confirmation) | notes |
| `x` | Mark the note for moving (then navigate to a folder and press `p`) | notes |
| `<C-n>` / `<C-p>` | Scroll the open note down / up | notes |
| `R` | Refresh the list | folders / notes |
| `O` | Open the notes repository in the browser | folders / notes |
| `<C-t>` | Toggle Folders + Notes columns (hide / show) | any |
| `<C-w>` then `h`/`j`/`k`/`l` | Move between windows | any |
| `q` | Close notes (prompts if editor has unsaved changes) | any |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`. It moves spatially between the three windows (`wincmd h/j/k/l`). Pressing `<C-w>k` from the editor always goes to the notes column (not folders).

### Highlight groups

Override these to customize colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folder rows |
| `NotesFile` | `Normal` | note rows (defined for overriding; not applied per-row by default) |
| `NotesTitle` | `bold` | the title text of each note row (after the date prefix) |
| `NotesActive` | `CursorLine` | the currently open note in the notes column |
| `NotesDirActive` | computed | the selected folder in the folders column |
| `NotesCut` | `Visual` | the note marked for moving (`x`) |
| `NotesConflict` | undercurl, `sp` from `DiagnosticError` | wavy error underline on a note in a merge conflict, and on its folder |

`NotesDirActive` is computed at open time from the resolved colors of `Directory` (fg) and `CursorLine` (bg), combining the folder color with the selection background. Override it with an explicit `nvim_set_hl` call in your config after setup.

`NotesActive` and `NotesDirActive` both use `line_hl_group` to fill the full line width so they stay visible when focus is elsewhere. `NotesCut` has higher priority (200) than `NotesActive` (0), so it is never hidden by it even when both land on the same row. The folders and notes windows do not use `cursorline`; the terminal cursor shows the current position.

### Statusline plugins

All three windows use fixed per-window statuslines. The folders column shows ` Folders`, the notes column shows ` Notes`, and the editor shows ` folder/title [+]` when a note is open (e.g. ` Notes/Shopping list` or ` Work/Project idea`), falling back to ` Editor` when no note is selected. If you use a statusline plugin (lualine, etc.) that overrides per-window statuslines, add the filetypes `NotesFolders` and `NotesList` to its exclusion list, and exclude the editor window by filetype (`markdown`) or by checking the buffer path.

The notes tab is labelled `notes.nvim` plus a sync status indicator (e.g. `notes.nvim ✓`, or a spinning `notes.nvim ⠋` while syncing). The label is pinned in the tab-local variable `t:title`, so tabline plugins that read it show the right name regardless of which inner window is focused. Only if you have **no** `tabline` set does the plugin install its own (restored on close). See `config.sync_icons` to customize or disable the icon.

### File structure

```
~/.notes/                  ← config.dir
  20260626223010.md        ← a note: opaque ID file (.md); title = first line
  Work/                    ← a folder (any depth is supported)
    20260625101500.md      ← a note inside the folder
    Projects/               ← a subfolder, entered with `o`
      20260701090000.md
    .gitkeep               ← hidden marker so an empty folder still commits
  Personal/
    .gitkeep
```

Each note is an ID-named `.md` file; its title in the list is read from the first non-blank line of its content. The virtual "Notes" entry in the folders column is the repo root (notes with no folder). Folders can nest to any depth; the folders column shows one level at a time — press `o` to drill in or go back up. Create with `a` (inside the current level), rename with `r`, delete with `d`; move notes between folders with `x` (mark) then `p` (paste into the selected folder). Moving an entire folder is not supported yet — only individual notes.

### Git sync behaviour

| Event | Action |
|-------|--------|
| Every open | Restore tracked files deleted outside the plugin (`git checkout -- <deleted>`) |
| First `:Notes` per session | `git clone` if missing, then `git pull` (merge) |
| Subsequent `:Notes` | Restore only; no network call (already synced) |
| Saving a file (`:w`) | UI refreshes instantly; then `git commit` → `git pull` (merge) → `git push` |
| Create / delete / move / rename | Immediate `git commit` → `git pull` (merge) → `git push` |
| Closing notes (`q`) | Optionally saves the open buffer, then `git commit` → `git pull` (merge) → `git push` |

### Conflicts

There are **no dialogs**. When a `git pull` can't merge cleanly, the conflict is left in the note as standard git markers and the repository enters a normal "merging" state:

```
<<<<<<< HEAD
your local line
=======
the version from GitHub
>>>>>>> origin/main
```

The conflicted note title — and the name of the folder that contains it — get a wavy underline in the error color (`NotesConflict`) in the two columns, so you can see exactly which notes need attention. To resolve: open the note, edit the markers out, and save (`:w`). That completes the merge and pushes. A half-resolved note (markers still present) is never committed.

While a note is in conflict, **move / rename / delete** of it (or its folder) is blocked with a `Resolve the conflict first` message — moving a file mid-merge would corrupt git's index. A modify/delete conflict (one side edited, the other deleted) auto-resolves by keeping the surviving file, so sync never deadlocks.

Multiple rapid CRUD actions are serialised: at most one git chain runs at a time, with one queued follow-up that captures everything that accumulated while the first chain was in flight.

Set `repo = ''` to disable all git operations.

## Donate

If you find this plugin useful, you can support development with a Bitcoin donation:

<img width="200" height="200" alt="Image" src="https://github.com/user-attachments/assets/c2109efa-5116-42cc-925b-231dafc3c483" />

`bc1q0fnakv2jean57p3rjqzhq826jklygpj6gc7evu`

## License

MIT
