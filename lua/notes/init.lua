-- notes.nvim — notes in a filetree explorer + editor tab, with GitHub sync

local M = {}

local api = vim.api

M.config = {
  dir = vim.fn.expand('~/.notes'), -- local notes directory (git worktree)
  repo = '', -- SSH remote, e.g. 'git@github.com:user/notes.git'
  list_height = 10, -- height of the explorer window (content rows)
  keys = {
    open_file = '<CR>', -- explorer: folder → expand/collapse; note → focus editor
    create = 'a', -- explorer: create a note in the context folder
    create_folder = 'A', -- explorer: create a folder in the context folder
    delete = 'd', -- explorer: delete the note/folder under the cursor
    rename = 'r', -- explorer: rename the folder under the cursor
    move = 'x', -- explorer: mark the note/folder under the cursor for moving
    paste = 'p', -- explorer: drop the marked note/folder into the context folder
    refresh = 'R', -- refresh the tree
    open_github = 'O', -- open the notes repo in the browser
    scroll_down = '<C-n>', -- scroll the open note down
    scroll_up = '<C-p>', -- scroll the open note up
    close = 'q', -- close notes (works from any notes window)
    window_nav = '<C-w>', -- prefix: h/j/k/l → move between windows (wincmd)
    toggle_panels = '<C-t>', -- hide/show the explorer
    change_folder = 'o', -- explorer: folder → expand/collapse; note → focus editor
  },
  -- Override sync status icons; nil = auto (Nerd Font glyph if nvim-web-devicons loaded, else Unicode)
  sync_icons = nil,
  -- Override tree icons; nil = auto (Nerd Font folder glyphs if nvim-web-devicons loaded,
  -- else Unicode arrows). Table: { folder = '…', folder_open = '…', note = '…' }.
  tree_icons = nil,
}

M.state = {
  synced = false, -- whether pull has run this session
  closing = false, -- re-entrancy guard
  tab = nil, -- tabpage handle for the notes tab
  explorer_win = nil, -- window id of the explorer (tree) window
  explorer_buf = nil, -- buffer id of the explorer (tree) window
  edit_win = nil,
  edit_buf = nil,
  current_file = nil, -- path of the file currently open in the editor
  cut = nil, -- path of the note marked for moving (set by `x`)
  cut_folder = nil, -- relative path of the folder marked for moving (set by `x`)
  expanded_folders = nil, -- set { [rel folder path] = true } of expanded folders; nil = none
  notes_all = nil, -- full scan: array of { file, folder, title, mtime, empty }
  tree_items = nil, -- flat tree rows; buffer line n → tree_items[n]
  conflicts = nil, -- set { [abs path] = true } of unmerged (conflicted) notes; nil = none
  panels_hidden = false, -- true while the explorer is toggled off
}

function M.is_open()
  local st = M.state
  if st.tab ~= nil then
    if api.nvim_tabpage_is_valid(st.tab) then
      return true
    end
    -- tab was externally closed; wipe stale state so old window IDs can't trigger autocmds
    st.tab = nil
    st.explorer_win = nil
    st.explorer_buf = nil
    st.edit_win = nil
    st.edit_buf = nil
    st.current_file = nil
    st.cut = nil
    st.cut_folder = nil
    st.expanded_folders = nil
    st.notes_all = nil
    st.tree_items = nil
    st.conflicts = nil
    st.panels_hidden = false
  end
  return false
end

function M.open()
  if M.is_open() then
    if M.state.explorer_win and api.nvim_win_is_valid(M.state.explorer_win) then
      api.nvim_set_current_win(M.state.explorer_win)
    end
    return
  end

  local git = require('notes.git')
  local ui = require('notes.ui')
  local picker = require('notes.picker')

  -- open immediately; tree refreshes after sync completes
  ui.open()
  picker.populate()

  git.ensure_repo(function()
    -- restore accidentally deleted tracked files before each pull
    git.restore(function()
      if M.is_open() then
        picker.populate()
      end

      if not M.state.synced and M.config.repo ~= '' then
        git.pull(function()
          M.state.synced = true
          if M.is_open() then
            picker.populate()
          end
          -- push any local commits accumulated while offline; skip if pull left a
          -- merge conflict to resolve (sync_on_exit would just re-warn about it)
          if vim.uv.fs_stat(M.config.dir .. '/.git/MERGE_HEAD') == nil then
            git.sync_on_exit()
          end
        end)
      else
        M.state.synced = true
      end
    end)
  end)
end

function M.close()
  if not M.is_open() then
    return
  end

  require('notes.ui').close()

  if M.config.repo ~= '' then
    require('notes.git').sync_on_exit()
  end
end

-- close with unsaved-changes prompt; bound to the close key in all windows
function M.close_interactive()
  if not M.is_open() then
    return
  end

  local st = M.state
  if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
    local buf = api.nvim_win_get_buf(st.edit_win)
    if vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      local choice = vim.fn.confirm('Notes: save changes?', '&Save\n&Discard\n&Cancel', 1)
      if choice == 3 or choice == 0 then
        return
      end
      if choice == 1 then
        api.nvim_buf_call(buf, function()
          vim.cmd('silent write')
        end)
      elseif choice == 2 then
        -- reload from disk so the discarded edits don't linger in the hidden
        -- buffer and reappear when the same note is reopened
        api.nvim_buf_call(buf, function()
          vim.cmd('silent edit!')
        end)
      end
    end
  end

  M.close()
end

function M.toggle()
  if M.is_open() then
    M.close_interactive()
  else
    M.open()
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})

  api.nvim_create_user_command('Notes', function()
    M.open()
  end, { desc = 'Open notes' })
end

return M
