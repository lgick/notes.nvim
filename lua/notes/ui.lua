-- Floating windows: geometry, open, close

local M = {}

local api = vim.api

local function cfg()
  return require('notes').config
end

function M.set_nav_keymaps(buf)
  local st = require('notes').state

  vim.keymap.set('n', '<C-h>', function()
    if st.tree_win and api.nvim_win_is_valid(st.tree_win) then
      api.nvim_set_current_win(st.tree_win)
    end
  end, { buffer = buf, silent = true, desc = 'Notes: go to tree' })

  vim.keymap.set('n', '<C-l>', function()
    if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
      api.nvim_set_current_win(st.edit_win)
    end
  end, { buffer = buf, silent = true, desc = 'Notes: go to editor' })
end

local function setup_autocmds(st)
  local group = api.nvim_create_augroup('NotesWin', { clear = true })

  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      if st.closing then
        return
      end
      local closed = tonumber(args.match)
      if closed == st.tree_win or closed == st.edit_win then
        vim.schedule(function()
          require('notes').close()
        end)
      end
    end,
  })
end

function M.open()
  local st = require('notes').state
  local c = cfg()

  local W = math.floor(vim.o.columns * c.width)
  local H = math.floor(vim.o.lines * c.height)
  local row = math.floor((vim.o.lines - H) / 2)
  local col = math.floor((vim.o.columns - W) / 2)

  local tree_w = math.floor(W * c.tree_ratio)
  local edit_w = W - tree_w - 4 -- subtract borders

  -- tree panel (left float)
  st.tree_buf = api.nvim_create_buf(false, true)
  vim.bo[st.tree_buf].buftype = 'nofile'
  vim.bo[st.tree_buf].bufhidden = 'wipe'
  vim.bo[st.tree_buf].swapfile = false
  vim.bo[st.tree_buf].filetype = 'NotesTree'

  st.tree_win = api.nvim_open_win(st.tree_buf, true, {
    relative = 'editor',
    width = tree_w,
    height = H,
    row = row,
    col = col,
    border = 'rounded',
    title = ' Notes ',
    title_pos = 'center',
  })
  vim.wo[st.tree_win].number = false
  vim.wo[st.tree_win].relativenumber = false
  vim.wo[st.tree_win].statuscolumn = ''
  vim.wo[st.tree_win].cursorline = true
  vim.wo[st.tree_win].list = false

  -- editor panel (right float)
  st.edit_buf = api.nvim_create_buf(false, true)
  vim.bo[st.edit_buf].buftype = 'nofile'
  api.nvim_buf_set_lines(st.edit_buf, 0, -1, false, {
    '# Notes',
    '',
    'Select a file on the left (Enter) or create one (a).',
  })

  st.edit_win = api.nvim_open_win(st.edit_buf, false, {
    relative = 'editor',
    width = edit_w,
    height = H,
    row = row,
    col = col + tree_w + 2,
    border = 'rounded',
    title = ' Markdown ',
    title_pos = 'center',
  })

  require('notes.tree').attach(st.tree_buf)
  M.set_nav_keymaps(st.tree_buf)
  M.set_nav_keymaps(st.edit_buf)
  setup_autocmds(st)
end

function M.close()
  local st = require('notes').state

  st.closing = true

  if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
    local buf = api.nvim_win_get_buf(st.edit_win)
    if vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      api.nvim_buf_call(buf, function()
        vim.cmd('silent write')
      end)
    end
  end

  for _, win in ipairs({ st.tree_win, st.edit_win }) do
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

  st.tree_win = nil
  st.edit_win = nil
  st.tree_buf = nil
  st.edit_buf = nil
  st.cut_node = nil
  st.nodes = nil
  st.closing = false
end

return M
