# notes.nvim

A lightweight Neovim plugin for managing notes in a dedicated tab, with optional GitHub synchronization via Git (SSH).

```
 Search                                           ← statusline
 todo▌                                            ← search input
─────────────────────────────────────────────────
 Notes                                            ← statusline
 work/todo.md
 ideas/startup.md
 journal.md
─────────────────────────────────────────────────
 work/todo.md  [+]  utf-8  markdown  12:4        ← statusline
 # Meeting Notes

 Discussed Q3 roadmap. Action items:
 - [ ] Send proposal by Friday
```

## Features

- **Tab-based UI** — opens in a new full-screen tab with three split windows stacked vertically: search (top), file list (middle), editor (bottom). Closing notes closes the tab.
- **Live search** — type in the top window to filter the list by substring of the relative path. Matched characters are highlighted in the list. Moving the selection with `<C-n>`/`<C-p>` (or `<C-j>`/`<C-k>`, `↓`/`↑`) instantly opens the file in the editor without leaving the search box. After any create/delete/rename the search field is cleared automatically.
- **Flat list, any format** — files of any extension are listed recursively (`folder/name.ext`), sorted by modification time (most recent first). Opening a file applies its native filetype highlighting. The currently open file is highlighted in the list.
- **Native editing** — the editor window behaves like a normal file window (`number`, `cursorline`, `signcolumn`, statusline), so global `InsertEnter`/`InsertLeave` styling and statusline plugins work inside it.
- **Full file management** — create (`a`), delete (`d`), rename/move (`r`), refresh (`R`) directly from the list. `a` makes a folder when the name ends with `/`, otherwise a file (a missing extension defaults to `.txt`); an existing file is opened, not overwritten. `r` and `a` accept a relative path, so a file can be moved into any folder — including back to the root. **Every create/delete/rename immediately commits and pushes to GitHub.**
- **Configurable keymaps** — every action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull --rebase --autostash`. On `:w`: commit+push. On CRUD actions (create/delete/rename): immediate commit+push. On close (`<C-[>`): commit+push of any remaining changes.
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

  -- Height of the list window in rows (content rows, excluding statusline).
  list_height = 20,

  -- Keymaps (override individually; unset keys keep their defaults).
  keys = {
    open_file   = '<CR>',    -- open the selected file (focus stays in search/list)
    next        = '<C-j>',   -- move selection down + open file (from the search box)
    prev        = '<C-k>',   -- move selection up + open file (from the search box)
    create_file = 'a',       -- create file/folder (trailing / = folder; no ext = .txt)
    delete      = 'd',       -- delete file (confirmation)
    rename      = 'r',       -- rename / move file (accepts a relative path)
    refresh     = 'R',       -- refresh the list
    open_github = 'O',       -- open the notes repository in the browser
    scroll_down = '<C-n>',   -- move selection down + open file (from search); scroll editor down (from list)
    scroll_up   = '<C-p>',   -- move selection up + open file (from search); scroll editor up (from list)
    close       = '<C-[>',   -- close notes (works from any notes window)
    window_nav  = '<C-w>',   -- prefix; then j → next window down, k → up (in order)
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
| type | Filter the list by substring; matched characters are highlighted | search |
| `<C-j>` / `<C-k>`, `↓` / `↑` | Move selection + open file instantly | search |
| `<C-n>` / `<C-p>` | Move selection + open file instantly | search |
| `<CR>` | Focus the list window | search |
| `<CR>` | Focus the editor window | list |
| `j` / `k` | Move cursor + open file instantly | list |
| `<C-n>` / `<C-p>` | Scroll the open file down / up | list |
| `a` | Create file or folder (`/` = folder, no ext = `.txt`) | list |
| `d` | Delete file (confirmation) | list |
| `r` | Rename / move file (accepts a relative path) | list |
| `R` | Refresh the list | list |
| `O` | Open the notes repository in the browser | list |
| `<C-w>` then `j` | Focus next window down (in order) | any |
| `<C-w>` then `k` | Focus next window up (in order) | any |
| `<C-[>` / `<Esc>` | Close notes (prompts if editor has unsaved changes) | any |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`. It steps one window at a time through search → list → editor — only `j` (down) and `k` (up); no skipping.

### Highlight groups

Override these to customize colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folders |
| `NotesFile` | `Normal` | file rows in the list |
| `NotesMatch` | `Search` | matched characters from the search query |
| `NotesActive` | `Visual` | the line of the currently open file |
| `NotesCut` | `WarningMsg` | (reserved) |

The current cursor position in the list is shown by the window's `cursorline`; `NotesActive` is a separate highlight that marks the file currently open in the editor (stays visible when focus is elsewhere).

### Statusline plugins

The search and list windows have `filetype` set to `NotesSearch` and `NotesList` respectively, with a fixed per-window `statusline` of ` Search` and ` Notes`. If you use a statusline plugin (lualine, etc.) that overrides per-window statuslines, add those filetypes to its exclusion list.

### File structure

```
~/notes/          ← config.dir
  folder-a/
    note.md
    deep/
      nested.txt  ← any depth, any extension
  inbox.md        ← files can also live at the root
```

Files are listed recursively as `folder/name.ext`. Create or rename with a relative path to place a file at any level (`r` on `work/todo.md` → `todo.md` moves it to the root).

### Git sync behaviour

| Event | Action |
|-------|--------|
| Every open | Restore tracked files deleted outside the plugin (`git checkout -- <deleted>`) |
| First `:Notes` per session | `git clone` if missing, then `git pull --rebase --autostash` |
| Subsequent `:Notes` | Restore only; no network call (already synced) |
| Saving a file (`:w`) | `git add -A` → `git commit -m "notes: YYYY-MM-DD HH:MM"` → `git push` (only if dirty) |
| Create / delete / rename | Immediate `git add -A` → `git commit` → `git push` |
| Closing notes (`<C-[>`) | Optionally saves the open buffer, then `git add -A` → `git commit` → `git push` (only if dirty) |

Set `repo = ''` to disable all git operations.

## License

MIT
