# notes.nvim

A lightweight Neovim plugin for managing notes in floating windows, with optional GitHub synchronization via Git (SSH).

```
╭─ Search ─────────────────────────────────────────╮
│ todo                                              │
╰───────────────────────────────────────────────────╯
╭─ Notes ──────────────────────────────────────────╮
│ work/todo.md                                      │
│ ideas/startup.md                                  │
│ journal.md                                        │
╰───────────────────────────────────────────────────╯
╭─ /work/todo.md ──────────────────────────────────╮
│ # Meeting Notes                                   │
│                                                   │
│ Discussed Q3 roadmap. Action items:               │
│ - [ ] Send proposal by Friday                     │
╰───────────────────────────────────────────────────╯
```

## Features

- **Floating UI** — three stacked floats (search + flat list + editor), sized as a percentage of the screen, open on top of any buffer without disrupting your layout. They re-center automatically on terminal resize. The editor float's title shows the path of the open file (`/folder/name.md`).
- **Live search** — type in the top window to filter the list by substring of the relative path. Move the selection with `<C-j>`/`<C-k>` (or `↓`/`↑`) without leaving the search box.
- **Flat list, any format** — files of any extension are listed recursively (`folder/name.ext`), sorted by modification time (most recent first). Opening a file applies its native filetype highlighting.
- **Native editing** — the editor float behaves like a normal file window (`number`, `cursorline`, `signcolumn`, statusline), so global `InsertEnter`/`InsertLeave` styling works inside it.
- **Full file management** — create (`a`), delete (`d`), rename/move (`r`), refresh (`R`) directly from the list. `a` makes a folder when the name ends with `/`, otherwise a file (a missing extension defaults to `.txt`); an existing file is opened, not overwritten. `r` and `a` accept a relative path, so a file can be moved into any folder — including back to the root.
- **Configurable keymaps** — every action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull --rebase --autostash`. On `:w` and on close: `git add -A && git commit && git push` if there are changes.
- **Crash-safe** — on every open, tracked files deleted outside the plugin (e.g. an accidental `rm`) are restored from the last commit before anything is pushed, so an empty working tree never propagates to the remote.
- **Focus stays inside notes** — the cursor cannot leave the three floats while notes is open.
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

  -- Float size as a fraction of the screen (0.0–1.0).
  width  = 0.8,
  height = 0.8,

  -- Height of the list window in rows (content, excluding border).
  list_height = 20,

  -- Keymaps (override individually; unset keys keep their defaults).
  keys = {
    open_file   = '<CR>',    -- open the selected file (focus stays in search/list)
    next        = '<C-j>',   -- move selection down (from the search box)
    prev        = '<C-k>',   -- move selection up (from the search box)
    create_file = 'a',       -- create file/folder (trailing / = folder; no ext = .txt)
    delete      = 'd',       -- delete file (confirmation)
    rename      = 'r',       -- rename / move file (accepts a relative path)
    refresh     = 'R',       -- refresh the list
    open_github = 'O',       -- open the notes repository in the browser
    scroll_down = '<C-n>',   -- scroll the open file down (from search/list)
    scroll_up   = '<C-p>',   -- scroll the open file up (from search/list)
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
| `:Notes` | Open the notes window |

### Default keymaps

All keys are configurable via `config.keys` (see above).

| Key | Action | Where |
|-----|--------|-------|
| type | Filter the list by substring | search |
| `<C-j>` / `<C-k>`, `↓` / `↑` | Move selection | search |
| `j` / `k` | Move selection (native) | list |
| `<CR>` | Open the selected file (focus stays) | search / list |
| `<C-n>` / `<C-p>` | Scroll the open file down / up | search / list |
| `a` | Create file or folder (`/` = folder, no ext = `.txt`) | list |
| `d` | Delete file (confirmation) | list |
| `r` | Rename / move file (accepts a relative path) | list |
| `R` | Refresh the list | list |
| `O` | Open the notes repository in the browser | list |
| `<C-w>` then `j` | Focus next window down (in order) | any |
| `<C-w>` then `k` | Focus next window up (in order) | any |
| `<C-[>` / `<Esc>` | Close notes | any |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`. It steps one window at a time through search → list → editor — only `j` (down) and `k` (up); no skipping.

The cursor cannot leave the three notes floats while they are open.

### Highlight groups

Override these to customize colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folders |
| `NotesFile` | `Normal` | files (list rows) |
| `NotesCut` | `WarningMsg` | (reserved) |

The current selection is shown by the list window's `cursorline`, not a dedicated highlight group.

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
| Closing notes (`<C-[>`) | Saves the open buffer, then `git add -A` → `git commit` → `git push` (only if dirty) |

Set `repo = ''` to disable all git operations.

## License

MIT
