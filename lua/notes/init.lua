-- notes.nvim — notes in floating windows (search + flat list + editor) with GitHub sync

local M = {}

local api = vim.api

M.config = {
  dir = vim.fn.expand('~/.notes'), -- local notes directory (git worktree)
  repo = '', -- SSH remote, e.g. 'git@github.com:user/notes.git'
  list_height = 10, -- height of the folders/notes row (content rows)
  folders_width = 25, -- width of the folders column
  keys = {
    open_file = '<CR>', -- folders: select folder / drop a moved note; notes: focus editor
    create = 'a', -- folders: create a folder; notes: create a note (in the current folder)
    delete = 'd', -- folders: delete the folder; notes: delete the note
    rename = 'r', -- folders: rename the selected folder
    move = 'x', -- notes: mark note for moving
    paste = 'p', -- folders: drop the marked note into the selected folder
    refresh = 'R', -- refresh the list
    open_github = 'O', -- open the notes repo in the browser
    scroll_down = '<C-n>', -- notes: scroll the open note down
    scroll_up = '<C-p>', -- notes: scroll the open note up
    close = 'q', -- close notes (works from any notes window)
    window_nav = '<C-w>', -- prefix: h/j/k/l → move between windows (wincmd)
  },
}

M.state = {
  synced = false, -- whether pull has run this session
  closing = false, -- re-entrancy guard
  tab = nil, -- tabpage handle for the notes tab
  folders_win = nil,
  folders_buf = nil,
  list_win = nil, -- notes column window
  list_buf = nil,
  edit_win = nil,
  edit_buf = nil,
  current_file = nil, -- path of the file currently open in the editor
  current_folder = nil, -- selected folder name; nil = "Notes" (root notes)
  cut = nil, -- path of the note marked for moving (set by `x`)
  folders = nil, -- array of { name, folder }; folder nil = the virtual root "Notes" entry
  notes_all = nil, -- full scan: array of { file, folder, title, mtime, empty }
  items = nil, -- filtered notes for the current folder
}

function M.is_open()
  local st = M.state
  if st.tab ~= nil then
    if api.nvim_tabpage_is_valid(st.tab) then
      return true
    end
    -- tab was externally closed; wipe stale state so old window IDs can't trigger autocmds
    st.tab = nil
    st.folders_win = nil
    st.folders_buf = nil
    st.list_win = nil
    st.list_buf = nil
    st.edit_win = nil
    st.edit_buf = nil
    st.current_file = nil
    st.current_folder = nil
    st.cut = nil
    st.items = nil
    st.notes_all = nil
    st.folders = nil
  end
  return false
end

function M.open()
  if M.is_open() then
    if M.state.list_win and api.nvim_win_is_valid(M.state.list_win) then
      api.nvim_set_current_win(M.state.list_win)
    end
    return
  end

  local git = require('notes.git')
  local ui = require('notes.ui')
  local picker = require('notes.picker')

  -- open immediately; list refreshes after sync completes
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
