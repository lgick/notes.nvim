-- notes.nvim — Markdown notes in floating windows with GitHub sync

local M = {}

local api = vim.api

M.config = {
  dir = vim.fn.expand('~/notes'), -- local notes directory (git worktree)
  repo = '', -- SSH remote, e.g. 'git@github.com:user/notes.git'
  width = 0.8, -- float width as fraction of screen
  height = 0.8, -- float height as fraction of screen
  tree_ratio = 0.28, -- fraction of the float width reserved for the tree panel
}

M.state = {
  synced = false, -- whether pull has run this session
  closing = false, -- re-entrancy guard
  tree_win = nil,
  tree_buf = nil,
  edit_win = nil,
  edit_buf = nil,
  cut_node = nil, -- file node staged for move (x → p)
  nodes = nil, -- line-number → node map for the tree buffer
  expanded = {}, -- path → true for expanded directories
}

function M.is_open()
  return M.state.tree_win ~= nil and api.nvim_win_is_valid(M.state.tree_win)
end

function M.open()
  if M.is_open() then
    api.nvim_set_current_win(M.state.tree_win)
    return
  end

  local git = require('notes.git')
  local ui = require('notes.ui')
  local tree = require('notes.tree')

  -- open immediately; tree refreshes after sync completes
  ui.open()
  tree.render()

  git.ensure_repo(function()
    if not M.state.synced and M.config.repo ~= '' then
      git.pull(function()
        M.state.synced = true
        if M.is_open() then
          tree.render()
        end
      end)
    else
      M.state.synced = true
    end
  end)
end

function M.close()
  if not (M.state.tree_win or M.state.edit_win) then
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
