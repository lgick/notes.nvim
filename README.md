# notes.nvim

*[Русская версия](README.ru.md)*

A lightweight Neovim plugin for managing notes in a dedicated tab — modelled on the
**macOS Notes** app — with optional GitHub synchronization via Git (SSH).

<video src="https://github.com/user-attachments/assets/7ff882ff-7cfc-4739-8765-e9e4ddc6fd5f" autoplay loop muted playsinline></video>

```
────────────────────────────────────────────────
 Explorer                          ← statusline
 ▼ Notes/
   ▼ Work/
     ▶ Projects/
     10.07.2026 - Report
   ▶ Personal/
   26.06.2026 - Shopping list
────────────────────────────────────────────────
 Notes/Shopping list                ← statusline (folder/title)
 # Shopping list

 - [ ] Milk
 - [ ] Call the bank
```

Folders nest to any depth and expand/collapse in place (`o` or `<CR>`), including the
root `Notes/` row itself:

```
────────────────────────────────────────────────
 Explorer
 ▼ Notes/
   ▼ Work/
     ▼ Projects/
       ▶ Q3/
       26.06.2026 - Sprint notes
     ▶ Archive/
────────────────────────────────────────────────
```

## Features

- **Filetree explorer + editor** — opens in a new full-screen tab: a single **explorer** tree (folders and notes together, any depth) on top, the editor on the bottom. Closing notes closes the tab.
- **Title from content** — a note has no manual filename. Its title is the **first non-blank line** of its text; an empty note is titled **"New Note"** and is always pinned to the top of its folder. On disk each note is an opaque ID file (`.md` extension, e.g. `20260627143000.md`), so editing a title never churns git history or collides. Note rows show `dd.mm.yyyy - Title`, sorted by modification time (newest first) within each folder. **The title updates live as you type**, without saving.
- **Root row, nested folders, expand in place** — the tree always starts with a `Notes/` row (the repo root); real folders nest under it to any depth and start collapsed. Press `o` (or `<CR>`) on any folder — including `Notes/` itself — to expand/collapse it right there in the tree, indented two spaces per level; press it on a note to focus the editor. Siblings are sorted so the folder/note whose subtree has the most recently edited note comes first, folders before notes at the same level. Folder rows show a closed/open glyph (configurable, see `config.tree_icons`); notes have no icon by default. New notes (`a`) and folders (`A`) are created inside the folder under the cursor (or the folder of the note under the cursor); dropping onto the `Notes/` row itself targets the root explicitly. Empty folders are supported via a hidden `.gitkeep` so they commit and sync.
- **Move by cursor** — press `x` on a note or a folder to mark it (highlighted with the selection color); press `x` again on the same item to cancel. Navigate anywhere in the tree (expanding/collapsing as needed) to the destination folder and press `p` to drop the marked note/folder there (or onto the `Notes/` row to drop it at the root). The destination folder auto-expands so the moved item is visible, and the cursor lands on it. A folder can't be moved into itself, one of its own subfolders, or moved at all if it's the root `Notes/` row.
- **Full-width row highlight, no distracting block cursor** — the explorer window highlights the whole width of the row under the cursor (native `cursorline`); the terminal block cursor itself is hidden while the explorer is focused, so it never sits on top of a tree glyph. The currently *open* note keeps its own full-width highlight independently of where the cursor is.
- **Native editing** — the editor window behaves like a normal `markdown` file window (`number`, `cursorline`, `signcolumn`), so global `InsertEnter`/`InsertLeave` styling and statusline plugins work inside it.
- **Instant UI updates** — the tree updates immediately on `:w` (sort order, title); git sync runs in the background.
- **Full management** — `a` creates a note, `A` creates a folder (both inside the folder under the cursor), `d` deletes the note/folder under the cursor, `x` marks it for moving, `p` pastes; folders also support rename (`r`); refresh (`R`). **Every create/delete/move/rename immediately commits and pushes to GitHub.**
- **Configurable keymaps** — every action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull` (merge). On `:w`: commit + merge + push. On any create/delete/move/rename: immediate commit + merge + push. On close (`q`): commit + merge + push of any remaining changes.
- **Conflicts stay in the file** — a merge conflict is left as standard git markers in the note (no dialog). The conflicted note title and its folder name get a wavy error underline (the folder highlight covers any conflict anywhere in its subtree); edit the markers out, save, and the merge completes and pushes. Move/rename/delete of a conflicted note is blocked until you resolve it.
- **Unsaved changes prompt** — pressing `q` when the editor has unsaved changes shows a **Save / Discard / Cancel** dialog instead of silently writing or discarding. Choosing **Discard** reloads the saved version from disk.
- **Crash-safe** — on every open, tracked files deleted outside the plugin (e.g. an accidental `rm`) are restored from the last commit before anything is pushed, so an empty working tree never propagates to the remote.
- **Sync status icon** — the Neovim tab label shows a sync status indicator next to `notes.nvim`: an animated braille spinner (`⠋⠙⠹…`) while syncing, `✓` when idle, `!` when there is a merge conflict. Nerd Font glyphs are used automatically for idle/conflict (`nf-fa-check` / `nf-cod-warning`) if `nvim-web-devicons` is installed (required on demand, so load order doesn't matter); otherwise plain ASCII. No icon when `repo = ''`. Icons are fully configurable via `config.sync_icons`.
- **Toggle panels** — press `<C-t>` (configurable) from any window to hide the explorer, giving the editor the full screen; press again to restore it. Useful when writing longer notes.
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

  -- Height of the explorer window in rows (content rows, excluding statusline).
  list_height = 10,

  -- Keymaps (override individually; unset keys keep their defaults).
  keys = {
    open_file     = '<CR>',  -- explorer: folder → expand/collapse; note → focus editor
    create        = 'a',     -- explorer: create a note in the context folder
    create_folder = 'A',     -- explorer: create a folder in the context folder
    delete        = 'd',     -- explorer: delete the note/folder under the cursor
    rename        = 'r',     -- explorer: rename the folder under the cursor
    move          = 'x',     -- explorer: mark the note/folder under the cursor for moving
    paste         = 'p',     -- explorer: drop the marked note/folder into the context folder
    refresh       = 'R',     -- refresh the tree
    open_github   = 'O',     -- open the notes repository in the browser
    scroll_down   = '<C-n>', -- scroll the open note down
    scroll_up     = '<C-p>', -- scroll the open note up
    close         = 'q',     -- close notes (works from any notes window)
    window_nav    = '<C-w>', -- prefix; then h/j/k/l → move between windows
    toggle_panels = '<C-t>', -- hide/show the explorer
    change_folder = 'o',     -- explorer: folder → expand/collapse; note → focus editor
  },

  -- Sync status icons shown in the tab label next to 'notes.nvim'.
  -- nil = auto: Nerd Font glyphs if nvim-web-devicons is loaded, otherwise Unicode.
  -- Set to a table to override individual icons.
  sync_icons = nil,
  -- sync_icons = { idle = '✓', syncing = '⠋', conflict = '!' },

  -- Icons shown on folder rows (closed/open). Notes have no icon by default.
  -- nil = auto: Nerd Font glyphs (nf-md-folder / nf-md-folder_open) if
  -- nvim-web-devicons is loaded, otherwise Unicode arrows (▶ / ▼).
  tree_icons = nil,
  -- tree_icons = { folder = '▶', folder_open = '▼', note = '' },
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

All keys are configurable via `config.keys` (see above). Every explorer key acts
on the note/folder under the cursor, or on the folder of the note under the
cursor (the "context folder") for create/paste.

| Key | Action |
|-----|--------|
| `j` / `k` | Move cursor; landing on a note opens it instantly below |
| `o` / `<CR>` | Folder (incl. `Notes/`): expand/collapse in place · Note: focus the editor |
| `a` | Create a note in the context folder |
| `A` | Create a folder in the context folder |
| `d` | Delete the note/folder under the cursor (confirmation; not `Notes/`) |
| `r` | Rename the folder under the cursor (not `Notes/`) |
| `x` | Mark the note/folder under the cursor for moving (not `Notes/`) |
| `p` | Drop the marked note/folder into the context folder (drop onto `Notes/` for the root) |
| `<C-n>` / `<C-p>` | Scroll the open note down / up |
| `R` | Refresh the tree |
| `O` | Open the notes repository in the browser |
| `<C-t>` | Toggle the explorer (hide / show) |
| `<C-w>` then `h`/`j`/`k`/`l` | Move between windows |
| `q` | Close notes (prompts if editor has unsaved changes) |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`. It moves spatially between the explorer and the editor (`wincmd h/j/k/l`). Pressing `<C-w>k` from the editor always goes to the explorer.

### Highlight groups

Override these to customize colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folder rows |
| `NotesFile` | `Normal` | note rows (defined for overriding; not applied per-row by default) |
| `NotesTitle` | `bold` | the title text of each note row (after the date prefix) |
| `NotesActive` | `CursorLine` | the currently open note |
| `NotesCut` | `Visual` | the note or folder marked for moving (`x`) |
| `NotesConflict` | undercurl, `sp` from `DiagnosticError` | wavy error underline on a note in a merge conflict, and on its folder |

`NotesActive` uses a low-priority (0), full-width (`hl_eol`) highlight over the row, so `NotesCut` (priority 200) and `NotesConflict` (priority 300) are never hidden by it even when both land on the same row — a marked-for-move or conflicted note/folder stays visibly highlighted even while it's also the currently open one. The explorer window has native `cursorline` enabled (also full width) for the row under the cursor; the terminal block cursor itself is hidden while the explorer is focused, so `cursorline` — not the cursor glyph — is what shows your position. (Cursor hiding relies on your terminal/GUI rendering Neovim's cursor color; most modern terminals do, some plain ones will just show their own default cursor instead.)

### Statusline plugins

The explorer and editor windows use fixed per-window statuslines. The explorer shows ` Explorer`, and the editor shows ` folder/title [+]` when a note is open (e.g. ` Notes/Shopping list` or ` Work/Project idea`), falling back to ` Editor` when no note is selected. If you use a statusline plugin (lualine, etc.) that overrides per-window statuslines, add the filetype `NotesExplorer` to its exclusion list, and exclude the editor window by filetype (`markdown`) or by checking the buffer path.

The notes tab is labelled `notes.nvim` plus a sync status indicator (e.g. `notes.nvim ✓`, or a spinning `notes.nvim ⠋` while syncing). The label is pinned in the tab-local variable `t:title`, so tabline plugins that read it show the right name regardless of which inner window is focused. Only if you have **no** `tabline` set does the plugin install its own (restored on close). See `config.sync_icons` to customize or disable the icon.

### File structure

```
~/.notes/                  ← config.dir
  20260626223010.md        ← a note: opaque ID file (.md); title = first line
  Work/                    ← a folder (any depth is supported)
    20260625101500.md      ← a note inside the folder
    Projects/               ← a subfolder, expanded with `o`
      20260701090000.md
    .gitkeep               ← hidden marker so an empty folder still commits
  Personal/
    .gitkeep
```

Each note is an ID-named `.md` file; its title in the tree is read from the first non-blank line of its content. Notes with no folder sit directly under the `Notes/` root row. Folders can nest to any depth and expand/collapse in place with `o`, same as `Notes/` itself. Create a note with `a`, a folder with `A` (both inside the context folder); rename a folder with `r`, delete with `d`; move a note or a whole folder (with its contents) between folders with `x` (mark) then `p` (paste into the context folder, or onto `Notes/` for the root) — a folder can't be moved into itself, one of its own subfolders, or (being the root) moved at all.

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

The conflicted note title — and the row of the folder that contains it (any ancestor, recursively) — get a wavy underline in the error color (`NotesConflict`), so you can see exactly which notes need attention even while their folder is collapsed. To resolve: open the note, edit the markers out, and save (`:w`). That completes the merge and pushes. A half-resolved note (markers still present) is never committed.

While a note is in conflict, **move / rename / delete** of it (or its folder) is blocked with a `Resolve the conflict first` message — moving a file mid-merge would corrupt git's index. A modify/delete conflict (one side edited, the other deleted) auto-resolves by keeping the surviving file, so sync never deadlocks.

Multiple rapid CRUD actions are serialised: at most one git chain runs at a time, with one queued follow-up that captures everything that accumulated while the first chain was in flight.

Set `repo = ''` to disable all git operations.

## Donate

If you find this plugin useful, you can support development with a Bitcoin donation:

<img width="200" height="200" alt="Image" src="https://github.com/user-attachments/assets/c2109efa-5116-42cc-925b-231dafc3c483" />

`bc1q0fnakv2jean57p3rjqzhq826jklygpj6gc7evu`

## License

MIT
