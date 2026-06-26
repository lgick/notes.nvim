-- Tab-based layout: three split windows stacked vertically (search + list + editor)

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

-- Replace the editor with the placeholder scratch buffer (no file open).
-- Used on first open and after the open file is deleted/its folder removed:
-- the orphaned buffer must be wiped or checktime raises E211 ("no longer available").
function M.show_placeholder()
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  local old = api.nvim_win_get_buf(st.edit_win)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    'Select a file above or create a new one (a).',
  })
  api.nvim_win_set_buf(st.edit_win, buf)
  st.edit_buf = buf
  st.current_file = nil

  vim.wo[st.edit_win].number = false
  vim.wo[st.edit_win].relativenumber = false
  vim.wo[st.edit_win].cursorline = false
  vim.wo[st.edit_win].signcolumn = 'no'

  M.set_nav_keymaps(buf)
  vim.keymap.set('n', cfg().keys.close, function()
    require('notes').close_interactive()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })

  -- wipe the previous real-file buffer so its deleted backing file can't raise E211
  if old ~= buf and api.nvim_buf_is_valid(old) and vim.bo[old].buftype == '' then
    pcall(api.nvim_buf_delete, old, { force = true })
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
end

function M.open()
  local st = require('notes').state

  setup_highlights()

  -- open in a new tab; the base window (from tabnew) becomes the editor
  vim.cmd('tabnew')
  st.tab = api.nvim_get_current_tabpage()
  local base_win = api.nvim_get_current_win()

  -- wipe the empty buffer that tabnew created
  local tabnew_buf = api.nvim_get_current_buf()
  vim.bo[tabnew_buf].bufhidden = 'wipe'

  -- editor: base window starts with the placeholder scratch buffer
  st.edit_win = base_win
  M.show_placeholder()

  -- list: split above editor
  st.list_buf = api.nvim_create_buf(false, true)
  vim.bo[st.list_buf].buftype = 'nofile'
  vim.bo[st.list_buf].bufhidden = 'wipe'
  vim.bo[st.list_buf].swapfile = false
  vim.bo[st.list_buf].filetype = 'NotesList'
  vim.bo[st.list_buf].modifiable = false
  st.list_win = api.nvim_open_win(st.list_buf, false, {
    split = 'above',
    win = base_win,
    height = cfg().list_height,
  })
  vim.wo[st.list_win].number = false
  vim.wo[st.list_win].relativenumber = false
  vim.wo[st.list_win].cursorline = true
  vim.wo[st.list_win].signcolumn = 'no'
  vim.wo[st.list_win].statuscolumn = ''
  vim.wo[st.list_win].winfixheight = true
  vim.wo[st.list_win].statusline = ' Notes'

  -- search: split above list
  st.input_buf = api.nvim_create_buf(false, true)
  vim.bo[st.input_buf].buftype = 'nofile'
  vim.bo[st.input_buf].bufhidden = 'wipe'
  vim.bo[st.input_buf].swapfile = false
  vim.bo[st.input_buf].filetype = 'NotesSearch'
  vim.b[st.input_buf].completion = false -- disable blink.cmp in search
  vim.bo[st.input_buf].complete = '' -- disable native keyword completion
  st.input_win = api.nvim_open_win(st.input_buf, true, {
    split = 'above',
    win = st.list_win,
    height = 1,
  })
  vim.wo[st.input_win].number = false
  vim.wo[st.input_win].relativenumber = false
  vim.wo[st.input_win].cursorline = false
  vim.wo[st.input_win].signcolumn = 'no'
  vim.wo[st.input_win].statuscolumn = ''
  vim.wo[st.input_win].winfixheight = true
  vim.wo[st.input_win].statusline = ' Search'

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
    require('notes').close_interactive()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })
  -- focus is NOT moved: opening a file leaves the cursor in the search/list window
end

function M.close()
  local st = require('notes').state
  if st.closing then
    return
  end

  st.closing = true

  local tab = st.tab
  st.tab = nil
  st.input_win = nil
  st.input_buf = nil
  st.list_win = nil
  st.list_buf = nil
  st.edit_win = nil
  st.edit_buf = nil
  st.current_file = nil
  st.items = nil
  st.all_items = nil

  if tab and api.nvim_tabpage_is_valid(tab) then
    pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(tab))
  end

  st.closing = false
end

return M
