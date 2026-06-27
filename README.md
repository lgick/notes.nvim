# notes.nvim

A lightweight Neovim plugin for managing notes in a dedicated tab — modelled on the
**macOS Notes** app — with optional GitHub synchronization via Git (SSH).

```
──────────────┬──────────────────────────────────
 Folders      │ Notes                            ← statuslines
 Notes         │ 26.06.2026 - Shopping list
 Work          │ 25.06.2026 - Project idea
 Personal      │ 24.06.2026 - Report
──────────────┴──────────────────────────────────
 Editor                                           ← statusline
 # Shopping list

 - [ ] Milk
 - [ ] Call the bank
```

## Features

- **Two-pane, macOS-Notes-style UI** — opens in a new full-screen tab: **folders** (left column) and **notes** (right column) on top, the editor on the bottom. Closing notes closes the tab.
- **Title from content** — a note has no manual filename. Its title is the **first non-blank line** of its text; an empty note is titled **"New Note"** and is always pinned to the top of the list. On disk each note is an opaque ID file (no extension), so editing a title never churns git history or collides. The notes column shows `dd.mm.yyyy - Title`, sorted by modification time (newest first). **The title in the list updates live as you type**, without saving.
- **Folders, one level deep** — the folders column lists **"Notes"** (the root: notes that have no folder) plus your folders, sorted so the folder with the most recently edited note comes first. Selecting a folder filters the notes column to it. Empty folders are supported via a hidden `.gitkeep` so they commit and sync.
- **Move by cursor** — press `x` on a note to mark it (highlighted with the selection color), then navigate to a folder in the folders column and press `p` to drop it there.
- **Native editing** — the editor window behaves like a normal `markdown` file window (`number`, `cursorline`, `signcolumn`), so global `InsertEnter`/`InsertLeave` styling and statusline plugins work inside it.
- **Instant UI updates** — the note list updates immediately on `:w` (sort order, title); git sync runs in the background.
- **Full management** — same keys in each column: `a` creates (a note in the notes column, a folder in the folders column), `d` deletes; notes also support move (`x` + `p`), folders also support rename (`r`); refresh (`R`). **Every create/delete/move/rename immediately commits and pushes to GitHub.**
- **Configurable keymaps** — every action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull --rebase --autostash`. On `:w`: commit+push. On any create/delete/move/rename: immediate commit+push. On close (`<C-[>`): commit+push of any remaining changes.
- **Unsaved changes prompt** — pressing `<C-[>` when the editor has unsaved changes shows a **Save / Discard / Cancel** dialog instead of silently writing or discarding.
- **Crash-safe** — on every open, tracked files deleted outside the plugin (e.g. an accidental `rm`) are restored from the last commit before anything is pushed, so an empty working tree never propagates to the remote.
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
  dir  = vim.fn.expand('~/notes'),
  repo = 'git@github.com:youruser/notes.git',
})
```

### lazy.nvim

```lua
{
  'lgick/notes.nvim',
  opts = {
    dir  = vim.fn.expand('~/notes'),
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
      dir  = vim.fn.expand('~/notes'),
      repo = 'git@github.com:youruser/notes.git',
    })
  end,
}
```

## Configuration

```lua
require('notes').setup({
  -- Local directory where notes are stored (also the git worktree root).
  dir = vim.fn.expand('~/notes'),

  -- SSH remote for GitHub sync.
  -- Leave empty ('') to use notes locally without any git sync.
  repo = 'git@github.com:youruser/notes.git',

  -- Height of the folders/notes row in rows (content rows, excluding statusline).
  list_height = 20,

  -- Width of the folders column.
  folders_width = 22,

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
    close       = '<C-[>', -- close notes (works from any notes window)
    window_nav  = '<C-w>', -- prefix; then h/j/k/l → move between windows
  },
})
```

> **Note:** `<C-[>` is byte-identical to `<Esc>` in the terminal — with the default
> `close` binding, pressing `<Esc>` also closes notes.

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
| `a` | Create a folder | folders |
| `r` | Rename the selected folder | folders |
| `d` | Delete the selected folder (confirmation) | folders |
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
| `<C-w>` then `h`/`j`/`k`/`l` | Move between windows | any |
| `<C-[>` / `<Esc>` | Close notes (prompts if editor has unsaved changes) | any |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`. It moves spatially between the three windows (`wincmd h/j/k/l`). Pressing `<C-w>k` from the editor always goes to the notes column (not folders).

### Highlight groups

Override these to customize colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folder rows |
| `NotesFile` | `Normal` | note rows (defined for overriding; not applied per-row by default) |
| `NotesActive` | `CursorLine` | the currently open note in the notes column |
| `NotesDirActive` | computed | the selected folder in the folders column |
| `NotesCut` | `Visual` | the note marked for moving (`x`) |

`NotesDirActive` is computed at open time from the resolved colors of `Directory` (fg) and `CursorLine` (bg), combining the folder color with the selection background. Override it with an explicit `nvim_set_hl` call in your config after setup.

`NotesActive` and `NotesDirActive` both use `line_hl_group` to fill the full line width so they stay visible when focus is elsewhere. `NotesCut` has higher priority (200) than `NotesActive` (0), so it is never hidden by it even when both land on the same row. The folders and notes windows do not use `cursorline`; the terminal cursor shows the current position.

### Statusline plugins

All three windows use fixed per-window statuslines (` Folders`, ` Notes`, ` Editor`). If you use a statusline plugin (lualine, etc.) that overrides per-window statuslines, add the filetypes `NotesFolders` and `NotesList` to its exclusion list, and exclude the editor window by filetype (`markdown`) or by checking the buffer path.

### File structure

```
~/notes/             ← config.dir
  20260626223010     ← a note: opaque ID file, no extension; title = first line
  Work/              ← a folder (one level deep)
    20260625101500   ← a note inside the folder
    .gitkeep         ← hidden marker so an empty folder still commits
  Personal/
    .gitkeep
```

Each note is an ID-named file; its title in the list is read from the first non-blank line of its content. The virtual "Notes" entry in the folders column is the repo root (notes with no folder). Folders are one level deep — create with `a`, rename with `r`, delete with `d`; move notes between folders with `x` (mark) then `p` (paste into the selected folder).

### Git sync behaviour

| Event | Action |
|-------|--------|
| Every open | Restore tracked files deleted outside the plugin (`git checkout -- <deleted>`) |
| First `:Notes` per session | `git clone` if missing, then `git pull --rebase --autostash` |
| Subsequent `:Notes` | Restore only; no network call (already synced) |
| Saving a file (`:w`) | UI refreshes instantly; then fetch → reconcile → `git add -A` → `git commit` → `git push` |
| Create / delete / move / rename | Immediate fetch → reconcile → `git add -A` → `git commit` → `git push` |
| Closing notes (`<C-[>`) | Optionally saves the open buffer, then fetch → reconcile → `git add -A` → `git commit` → `git push` |

**Reconcile** means: if the remote is ahead, `git stash push` → `git pull --ff-only` → `git stash pop`. If the pop produces a conflict, a dialog appears:

```
[notes.nvim] GitHub updated: work/todo.md
Local changes will overwrite. Push?
[Yes] [No]
```

- **Yes** — your local version is kept and pushed to GitHub. This handles all conflict types: `UU` (both modified), `DU` (GitHub deleted, you modified), `UD` (GitHub modified, you deleted), etc. The file list refreshes automatically.
- **No** — your local changes are discarded; the editor reloads the GitHub version from disk and the file list refreshes automatically.

Multiple rapid CRUD actions are serialised: at most one git chain runs at a time, with one queued follow-up that captures everything that accumulated while the first chain was in flight.

Set `repo = ''` to disable all git operations.

## License

MIT
