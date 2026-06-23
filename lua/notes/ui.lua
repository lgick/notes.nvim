-- Floating windows: geometry, open, close

local M = {}

local api = vim.api

local function cfg()
  return require('notes').config
end

local function setup_highlights()
  api.nvim_set_hl(0, 'NotesDir', { default = true, link = 'Directory' })
  api.nvim_set_hl(0, 'NotesFile', { default = true, link = 'Normal' })
  api.nvim_set_hl(0, 'NotesCut', { default = true, link = 'WarningMsg' })
end

function M.set_edit_title(path)
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  if path then
    local title = path:gsub('^' .. vim.pesc(cfg().dir), '')
    api.nvim_win_set_config(st.edit_win, { title = title, title_pos = 'center' })
  else
    api.nvim_win_set_config(st.edit_win, { title = '' })
  end
end

local function focus_win(win)
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  end
end

function M.set_nav_keymaps(buf)
  local st = require('notes').state
  local keys = cfg().keys

  -- один префикс <C-w> + синхронное чтение h/j/k/l: без timeoutlen-задержки,
  -- которую давали отдельные маппинги <C-w>h / <C-w>l
  vim.keymap.set('n', keys.window_nav, function()
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok then
      return
    end
    local key = vim.fn.keytrans(char):lower()
    if key == 'h' or key == 'k' then
      focus_win(st.tree_win)
    elseif key == 'l' or key == 'j' then
      focus_win(st.edit_win)
    end
  end, { buffer = buf, silent = true, desc = 'Notes: window nav' })

  vim.keymap.set('n', keys.close, function()
    require('notes').close()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })
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

  -- sync на :w для файлов внутри каталога заметок
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = cfg().dir .. '/*',
    callback = function()
      -- при закрытии запись делает ui.close(); sync вызовет notes.close() один раз
      if st.closing then
        return
      end
      -- не пушить, пока не завершился стартовый restore/pull: иначе ранний :w
      -- мог бы закоммитить «грязное» состояние каталога
      if not st.synced then
        return
      end
      if cfg().repo ~= '' then
        require('notes.git').sync_on_exit()
      end
    end,
  })

  -- курсор не должен покидать окна notes
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      if st.closing or not require('notes').is_open() then
        return
      end
      local win = api.nvim_get_current_win()
      if win == st.tree_win or win == st.edit_win then
        return
      end
      -- не перехватываем фокус у плавающих окон (vim.ui.input, уведомления);
      -- возвращаем курсор только из обычных окон за пределами notes
      if api.nvim_win_get_config(win).relative ~= '' then
        return
      end
      vim.schedule(function()
        local target = (st.edit_win and api.nvim_win_is_valid(st.edit_win)) and st.edit_win
          or st.tree_win
        if target and api.nvim_win_is_valid(target) then
          api.nvim_set_current_win(target)
        end
      end)
    end,
  })
end

function M.open()
  local st = require('notes').state
  local c = cfg()

  setup_highlights()

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
