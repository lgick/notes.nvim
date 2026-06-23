# notes.nvim

A lightweight Neovim plugin for managing Markdown notes in floating windows, with optional GitHub synchronization via Git (SSH).

```
╭─ Notes ──────────╮╭─ Markdown ─────────────────────────────────╮
│▸ work/           ││# Meeting Notes                              │
│▾ ideas/          ││                                             │
│    startup.md    ││Discussed Q3 roadmap. Action items:          │
│    travel.md     ││- [ ] Send proposal by Friday                │
│  journal.md      ││- [ ] Schedule follow-up                     │
╰──────────────────╯╰─────────────────────────────────────────────╯
```

## Features

- **Floating UI** — two side-by-side floats (tree + editor), sized as a percentage of the screen, open on top of any buffer without disrupting your layout.
- **File tree** — one level of folder nesting. Folders and `.md` files in the root; `.md` files inside subdirectories.
- **Full file management** — create (`a`), delete (`d`), move (`x` → `p`) files and folders directly from the tree.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull --rebase`. On close: `git add -A && git commit && git push` if there are changes.
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

  -- Fraction of the float width given to the tree panel.
  tree_ratio = 0.28,
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
| `:Notes` | Open the notes window |

### Tree keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Open file / expand-collapse folder |
| `a` | Create file or folder (prompt) |
| `d` | Delete file or folder (confirmation) |
| `x` | Cut file (stage for move) |
| `p` | Paste cut file into the folder under cursor |
| `R` | Refresh tree |
| `q` / `<Esc>` | Close notes |
| `<C-h>` | Focus tree panel |
| `<C-l>` | Focus editor panel |

### File structure

```
~/notes/          ← config.dir
  folder-a/
    note.md
    another.md
  folder-b/
    idea.md
  inbox.md        ← files can also live at the root
```

Folders are **one level deep only**. Subfolders inside subfolders are not displayed.

### Git sync behaviour

| Event | Action |
|-------|--------|
| First `:Notes` per session | `git clone` if missing, then `git pull --rebase` |
| Subsequent `:Notes` | No network call (already synced) |
| Closing notes | `git add -A` → `git commit -m "notes: YYYY-MM-DD HH:MM"` → `git push` (only if dirty) |

Set `repo = ''` to disable all git operations.

## License

MIT
