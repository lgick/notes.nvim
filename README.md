# notes.nvim

A lightweight Neovim plugin for managing Markdown notes in floating windows, with optional GitHub synchronization via Git (SSH).

```
╭─ Notes ──────────╮╭─ /ideas/startup.md ────────────────────────╮
│▸ work/           ││# Meeting Notes                              │
│▾ ideas/          ││                                             │
│    startup.md    ││Discussed Q3 roadmap. Action items:          │
│    travel.md     ││- [ ] Send proposal by Friday                │
│  journal.md      ││- [ ] Schedule follow-up                     │
╰──────────────────╯╰─────────────────────────────────────────────╯
```

## Features

- **Floating UI** — two side-by-side floats (tree + editor), sized as a percentage of the screen, open on top of any buffer without disrupting your layout. The editor float's title shows the path of the open file (`/folder/name.md`); empty when no file is open.
- **File tree** — one level of folder nesting. Folders and `.md` files in the root; `.md` files inside subdirectories.
- **Full file management** — create a file (`a`, default name `new.md`, `new1.md`, …), create a folder (`A`), delete (`d`), move (`x` → `p`) directly from the tree.
- **Configurable keymaps** — every tree action, the close key, and panel-focus keys are remappable via `config.keys`.
- **Git sync** — on first open: `git clone` (if the directory doesn't exist) then `git pull --rebase --autostash`. On `:w` and on close: `git add -A && git commit && git push` if there are changes.
- **Crash-safe** — on every open, tracked files deleted outside the plugin (e.g. an accidental `rm`) are restored from the last commit before anything is pushed, so an empty working tree never propagates to the remote.
- **Focus stays inside notes** — the cursor cannot leave the two floats while notes is open.
- **Highlight groups** — `NotesDir`, `NotesFile`, `NotesCut` for folders, files, and the file staged for moving.
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

  -- Keymaps (override individually; unset keys keep their defaults).
  keys = {
    toggle_dir  = 'o',       -- expand / collapse folder
    open_file   = '<CR>',    -- open file
    create_file = 'a',       -- create file (prompts, default new.md/new1.md/…)
    create_dir  = 'A',       -- create folder (root only)
    delete      = 'd',       -- delete file or folder (confirmation)
    cut         = 'x',       -- stage file for move
    paste       = 'p',       -- paste staged file
    refresh     = 'r',       -- refresh tree
    open_github = 'O',       -- open the notes repository in the browser
    close       = '<C-[>',   -- close notes (works from any notes window)
    window_nav  = '<C-w>',   -- prefix; then h/k → tree, l/j → editor
  },
})
```

> **Note:** `<C-[>` is byte-identical to `<Esc>` in the terminal — with the default
> `close` binding, pressing `<Esc>` in normal mode also closes notes.

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
| `o` | Expand / collapse folder | tree |
| `<CR>` | Open file | tree |
| `a` | Create file (default `new.md`, `new1.md`, …) | tree |
| `A` | Create folder (root only) | tree |
| `d` | Delete file or folder (confirmation) | tree |
| `x` | Cut file (stage for move) | tree |
| `p` | Paste cut file into the folder under cursor | tree |
| `r` | Refresh tree | tree |
| `O` | Open the notes repository in the browser | tree |
| `<C-w>` then `h`/`k` | Focus tree panel | both |
| `<C-w>` then `l`/`j` | Focus editor panel | both |
| `<C-[>` | Close notes | both |

Window navigation reads the direction key right after `<C-w>` (via `getcharstr`), so it is not affected by `timeoutlen`.

The cursor cannot leave the two notes floats while they are open.

### Highlight groups

Override these to customize tree colors (they link to sensible defaults):

| Group | Default link | Applies to |
|-------|--------------|------------|
| `NotesDir` | `Directory` | folders |
| `NotesFile` | `Normal` | files |
| `NotesCut` | `WarningMsg` | file staged for moving (`x`) |

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
| Every open | Restore tracked files deleted outside the plugin (`git checkout -- <deleted>`) |
| First `:Notes` per session | `git clone` if missing, then `git pull --rebase --autostash` |
| Subsequent `:Notes` | Restore only; no network call (already synced) |
| Saving a file (`:w`) | `git add -A` → `git commit -m "notes: YYYY-MM-DD HH:MM"` → `git push` (only if dirty) |
| Closing notes (`<C-[>`) | Saves the open buffer, then `git add -A` → `git commit` → `git push` (only if dirty) |

Set `repo = ''` to disable all git operations.

## License

MIT
