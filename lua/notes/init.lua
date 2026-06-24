-- notes.nvim — notes in floating windows (search + flat list + editor) with GitHub sync

local M = {}

local api = vim.api

M.config = {
  dir = vim.fn.expand('~/notes'), -- local notes directory (git worktree)
  repo = '', -- SSH remote, e.g. 'git@github.com:user/notes.git'
  width = 0.8, -- float width as fraction of screen
  height = 0.8, -- float height as fraction of screen
  list_height = 20, -- height of the list window (content rows)
  keys = {
    open_file = '<CR>', -- search: jump to list; list: open selected file in editor
    next = '<C-j>', -- move selection down + open file (from search)
    prev = '<C-k>', -- move selection up + open file (from search)
    create_file = 'a', -- create file or folder (trailing / = folder; no ext = .txt)
    delete = 'd', -- delete file/folder
    rename = 'r', -- rename / move file (accepts relative path)
    refresh = 'R', -- refresh the list
    open_github = 'O', -- open the notes repo in the browser
    scroll_down = '<C-n>', -- search: move selection down + open; list: scroll editor down
    scroll_up = '<C-p>', -- search: move selection up + open; list: scroll editor up
    close = '<C-[>', -- close notes (≡ <Esc> in terminal)
    window_nav = '<C-w>', -- prefix: j → window down, k → up (search → list → editor)
  },
}

M.state = {
  synced = false, -- whether pull has run this session
  closing = false, -- re-entrancy guard
  input_win = nil,
  input_buf = nil,
  list_win = nil,
  list_buf = nil,
  edit_win = nil,
  edit_buf = nil,
  current_file = nil, -- path of the file currently open in the editor
  all_items = nil, -- full scan: array of { file, rel, mtime }
  items = nil, -- filtered array
}

function M.is_open()
  local st = M.state
  for _, win in ipairs({ st.input_win, st.list_win, st.edit_win }) do
    if win and api.nvim_win_is_valid(win) then
      return true
    end
  end
  return false
end

function M.open()
  if M.is_open() then
    if M.state.input_win and api.nvim_win_is_valid(M.state.input_win) then
      api.nvim_set_current_win(M.state.input_win)
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

function M.toggle()
  if M.is_open() then
    M.close()
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
