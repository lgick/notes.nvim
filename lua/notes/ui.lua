-- Floating windows: three stacked floats (search + list + editor), geometry, autocmds

local M = {}

local api = vim.api
local fn = vim.fn

local function cfg()
  return require('notes').config
end

local function setup_highlights()
  api.nvim_set_hl(0, 'NotesDir', { default = true, link = 'Directory' })
  api.nvim_set_hl(0, 'NotesFile', { default = true, link = 'Normal' })
  api.nvim_set_hl(0, 'NotesCut', { default = true, link = 'WarningMsg' })
  api.nvim_set_hl(0, 'NotesMatch', { default = true, link = 'Search' })
  api.nvim_set_hl(0, 'NotesActive', { default = true, link = 'Visual' })
end

-- Geometry of three stacked floats. Each float's footprint includes the border
-- ('rounded' adds +1 row top/bottom and +1 col each side);
-- width/height in nvim_open_win are content dimensions; the border is drawn outside.
local function layout()
  local c = cfg()
  local W = math.floor(vim.o.columns * c.width)
  local H = math.floor(vim.o.lines * c.height)
  local top = math.floor((vim.o.lines - H) / 2)
  local left = math.floor((vim.o.columns - W) / 2)

  local cw = W - 2 -- content width (1 col border each side)
  local col = left + 1 -- content col

  local input_h = 1
  local fp_input = input_h + 2 -- total rows including border

  -- keep ≥1 row for edit: H - fp_input - fp_edit_min(=3)
  local list_h = math.min(c.list_height, H - fp_input - 3 - 2)
  list_h = math.max(list_h, 1)
  local fp_list = list_h + 2

  local edit_h = H - fp_input - fp_list - 2
  edit_h = math.max(edit_h, 1)

  return {
    input = {
      relative = 'editor',
      width = cw,
      height = input_h,
      col = col,
      row = top + 1,
      border = 'rounded',
      title = ' Search ',
      title_pos = 'left',
    },
    list = {
      relative = 'editor',
      width = cw,
      height = list_h,
      col = col,
      row = top + fp_input + 1,
      border = 'rounded',
      title = ' Notes ',
      title_pos = 'left',
    },
    edit = {
      relative = 'editor',
      width = cw,
      height = edit_h,
      col = col,
      row = top + fp_input + fp_list + 1,
      border = 'rounded',
    }, -- title is set in open_in_edit (file path)
  }
end

function M.set_edit_title(path)
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  if path then
    local title = path:gsub('^' .. vim.pesc(cfg().dir), '')
    api.nvim_win_set_config(st.edit_win, { title = title, title_pos = 'left' })
  else
    api.nvim_win_set_config(st.edit_win, { title = '' })
  end
end

-- Scroll the open file from search/list: sends <C-e>/<C-y> inside edit_win
function M.scroll_edit(delta)
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end
  local key = delta > 0 and '\5' or '\25' -- <C-e> / <C-y>
  api.nvim_win_call(st.edit_win, function()
    vim.cmd('normal! ' .. key)
  end)
end

function M.set_nav_keymaps(buf)
  local st = require('notes').state
  local keys = cfg().keys

  -- single prefix + synchronous getcharstr: no timeoutlen delay.
  -- Ordered navigation only (search → list → editor); j down, k up; no skipping.
  local function nav()
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok then
      return
    end
    local key = vim.fn.keytrans(char):lower()
    local delta = key == 'j' and 1 or key == 'k' and -1 or nil
    if not delta then
      return
    end

    local order = { st.input_win, st.list_win, st.edit_win }
    local cur = api.nvim_get_current_win()
    local idx
    for i, w in ipairs(order) do
      if w == cur then
        idx = i
        break
      end
    end
    if not idx then
      return
    end

    local target = order[idx + delta]
    if target and api.nvim_win_is_valid(target) then
      api.nvim_set_current_win(target)
      if target == st.input_win then
        vim.cmd('startinsert')
      end
    end
  end

  vim.keymap.set({ 'n', 'i' }, keys.window_nav, function()
    -- leave insert first so the prefix key is not typed into the buffer
    if api.nvim_get_mode().mode:sub(1, 1) == 'i' then
      vim.cmd('stopinsert')
    end
    nav()
  end, { buffer = buf, silent = true, desc = 'Notes: window nav' })
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
      if closed == st.input_win or closed == st.list_win or closed == st.edit_win then
        vim.schedule(function()
          require('notes').close()
        end)
      end
    end,
  })

  -- auto-open file when navigating the list window
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = st.list_buf,
    callback = function()
      if api.nvim_get_current_win() ~= st.list_win then
        return
      end
      require('notes.picker').open_selected()
    end,
  })

  -- live filter: update list on every keystroke in the search box
  api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = group,
    buffer = st.input_buf,
    callback = function()
      local picker = require('notes.picker')
      local text = api.nvim_buf_get_lines(st.input_buf, 0, 1, false)[1] or ''
      picker.filter(text)
      picker.render_list()
    end,
  })

  -- git sync on :w for files inside the notes directory (* also matches subdirs)
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = cfg().dir .. '/*',
    callback = function()
      -- close() already writes and syncs once; guard prevents a second concurrent chain
      if st.closing then
        return
      end
      -- skip push until initial restore/pull finishes: an early :w could commit a dirty tree
      if not st.synced then
        return
      end
      if cfg().repo ~= '' then
        require('notes.git').sync_on_exit()
      end
    end,
  })

  -- terminal resize: recompute geometry of all three floats
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if not require('notes').is_open() then
        return
      end
      local L = layout()
      for name, win in pairs({
        input = st.input_win,
        list = st.list_win,
        edit = st.edit_win,
      }) do
        if win and api.nvim_win_is_valid(win) then
          api.nvim_win_set_config(win, L[name])
        end
      end
      -- L.edit has no title field; re-apply the open file path
      if st.current_file then
        M.set_edit_title(st.current_file)
      end
    end,
  })

  -- keep cursor inside the notes floats at all times
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      if st.closing or not require('notes').is_open() then
        return
      end
      local win = api.nvim_get_current_win()
      if win == st.input_win or win == st.list_win or win == st.edit_win then
        return
      end
      -- don't steal focus from other floats (vim.ui.input, notifications);
      -- only redirect from regular (non-floating) windows outside notes
      if api.nvim_win_get_config(win).relative ~= '' then
        return
      end
      vim.schedule(function()
        local target = (st.edit_win and api.nvim_win_is_valid(st.edit_win)) and st.edit_win
          or st.input_win
        if target and api.nvim_win_is_valid(target) then
          api.nvim_set_current_win(target)
        end
      end)
    end,
  })
end

function M.open()
  local st = require('notes').state

  setup_highlights()
  local L = layout()

  -- input (search)
  st.input_buf = api.nvim_create_buf(false, true)
  vim.bo[st.input_buf].buftype = 'nofile'
  vim.bo[st.input_buf].bufhidden = 'wipe'
  vim.bo[st.input_buf].swapfile = false
  vim.bo[st.input_buf].filetype = 'NotesSearch'
  vim.b[st.input_buf].completion = false -- disable blink.cmp in search
  vim.bo[st.input_buf].complete = '' -- disable native keyword completion
  st.input_win = api.nvim_open_win(st.input_buf, true, L.input)
  vim.wo[st.input_win].number = false
  vim.wo[st.input_win].relativenumber = false
  vim.wo[st.input_win].cursorline = false
  vim.wo[st.input_win].signcolumn = 'no'
  vim.wo[st.input_win].statuscolumn = ''

  -- list
  st.list_buf = api.nvim_create_buf(false, true)
  vim.bo[st.list_buf].buftype = 'nofile'
  vim.bo[st.list_buf].bufhidden = 'wipe'
  vim.bo[st.list_buf].swapfile = false
  vim.bo[st.list_buf].filetype = 'NotesList'
  vim.bo[st.list_buf].modifiable = false
  st.list_win = api.nvim_open_win(st.list_buf, false, L.list)
  vim.wo[st.list_win].number = false
  vim.wo[st.list_win].relativenumber = false
  vim.wo[st.list_win].cursorline = true -- highlights current line
  vim.wo[st.list_win].signcolumn = 'no'
  vim.wo[st.list_win].statuscolumn = ''

  -- edit
  st.edit_buf = api.nvim_create_buf(false, true)
  vim.bo[st.edit_buf].buftype = 'nofile'
  api.nvim_buf_set_lines(st.edit_buf, 0, -1, false, {
    'Select a file above or create a new one (a).',
  })
  st.edit_win = api.nvim_open_win(st.edit_buf, false, L.edit)
  st.current_file = nil

  local picker = require('notes.picker')
  picker.attach_input(st.input_buf)
  picker.attach_list(st.list_buf)
  M.set_nav_keymaps(st.input_buf)
  M.set_nav_keymaps(st.list_buf)
  M.set_nav_keymaps(st.edit_buf)

  setup_autocmds(st)

  vim.cmd('startinsert')
end

function M.open_in_edit(path)
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  -- write current file before switching: :edit on a modified buffer raises E37,
  -- and unsaved edits would be lost when close() runs
  local cur = api.nvim_win_get_buf(st.edit_win)
  if vim.bo[cur].buftype == '' and vim.bo[cur].modified then
    api.nvim_buf_call(cur, function()
      vim.cmd('silent write')
    end)
  end

  api.nvim_win_call(st.edit_win, function()
    vim.cmd('edit ' .. fn.fnameescape(path))
  end)

  local buf = api.nvim_win_get_buf(st.edit_win)
  st.edit_buf = buf
  st.current_file = path

  -- set window options like a normal file; do NOT pin StatusLine/CursorLineNr in
  -- winhighlight — the user's global UpdateInsertModeColor (InsertEnter/Leave) must work
  vim.wo[st.edit_win].number = true
  vim.wo[st.edit_win].relativenumber = true
  vim.wo[st.edit_win].cursorline = true
  vim.wo[st.edit_win].signcolumn = 'yes'

  M.set_nav_keymaps(buf)
  vim.keymap.set('n', cfg().keys.close, function()
    require('notes').close()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })
  M.set_edit_title(path)
  -- focus is NOT moved: opening a file leaves the cursor in the search/list window
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

  for _, win in ipairs({ st.input_win, st.list_win, st.edit_win }) do
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

  st.input_win = nil
  st.input_buf = nil
  st.list_win = nil
  st.list_buf = nil
  st.edit_win = nil
  st.edit_buf = nil
  st.current_file = nil
  st.items = nil
  st.all_items = nil
  st.closing = false
end

return M
