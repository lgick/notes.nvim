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
    open_file = '<CR>', -- открыть выделенный файл в редакторе
    next = '<C-j>', -- следующий в списке (из окна поиска)
    prev = '<C-k>', -- предыдущий в списке (из окна поиска)
    create_file = 'a', -- создать файл (или папку, если имя оканчивается на /)
    delete = 'd', -- удалить файл/папку
    rename = 'r', -- переименовать/переместить файл
    refresh = 'R', -- обновить список
    open_github = 'O', -- открыть репозиторий заметок в браузере
    scroll_down = '<C-n>', -- прокрутить открытый файл вниз (из поиска/списка)
    scroll_up = '<C-p>', -- прокрутить открытый файл вверх (из поиска/списка)
    close = '<C-[>', -- закрыть заметки (≡ <Esc>)
    window_nav = '<C-w>', -- префикс навигации по окнам по порядку: j → ниже, k → выше
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
  all_items = nil, -- полный скан: массив { file, rel, mtime }
  items = nil, -- отфильтрованный массив
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
    -- восстановить случайно удалённые файлы (на каждом открытии), затем синк
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
