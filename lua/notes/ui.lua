-- Tab-based layout: search (top) + folders | notes (middle) + editor (bottom)

local M = {}

local api = vim.api
local fn = vim.fn

-- saved value of `tabline` before we override it; nil means we didn't override
local _old_tabline = nil

local function cfg()
  return require('notes').config
end

-- Called by the `tabline` option expression. Builds the full tabline string so
-- the notes tab always shows 'notes.nvim' regardless of the focused window inside it.
-- Other tabs fall back to the buffer name of their focused window.
function M.tabline()
  local parts = {}
  local current = api.nvim_get_current_tabpage()
  for _, tp in ipairs(api.nvim_list_tabpages()) do
    local hl = tp == current and '%#TabLineSel#' or '%#TabLine#'
    local ok, title = pcall(api.nvim_tabpage_get_var, tp, 'title')
    if not ok then
      local win = api.nvim_tabpage_get_win(tp)
      local buf = api.nvim_win_get_buf(win)
      local name = api.nvim_buf_get_name(buf)
      title = name ~= '' and fn.fnamemodify(name, ':t') or '[No Name]'
    end
    parts[#parts + 1] = hl .. ' ' .. title .. ' '
  end
  parts[#parts + 1] = '%#TabLineFill#'
  return table.concat(parts)
end

local function setup_highlights()
  api.nvim_set_hl(0, 'NotesDir', { default = true, link = 'Directory' })
  api.nvim_set_hl(0, 'NotesFile', { default = true, link = 'Normal' })
  api.nvim_set_hl(0, 'NotesCut', { default = true, link = 'Visual' })
  api.nvim_set_hl(0, 'NotesActive', { default = true, link = 'CursorLine' })
  api.nvim_set_hl(0, 'NotesTitle', { default = true, bold = true })
  -- NotesDirActive: Directory fg (blue) on CursorLine bg — for the selected folder row.
  -- No standard group combines both, so we compute it from the resolved colors.
  local dir = api.nvim_get_hl(0, { name = 'Directory', link = false })
  local cursor = api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  api.nvim_set_hl(0, 'NotesDirActive', {
    fg = dir.fg,
    bg = cursor.bg,
    bold = dir.bold or false,
    ctermfg = dir.ctermfg,
    ctermbg = cursor.ctermbg,
  })
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
    'Select a note or create a new one (a).',
  })
  api.nvim_win_set_buf(st.edit_win, buf)
  st.edit_buf = buf
  st.current_file = nil

  vim.wo[st.edit_win].number = false
  vim.wo[st.edit_win].relativenumber = false
  vim.wo[st.edit_win].cursorline = false
  vim.wo[st.edit_win].signcolumn = 'no'
  vim.wo[st.edit_win].statusline = ' Editor'
  vim.wo[st.edit_win].wrap = false
  vim.wo[st.edit_win].linebreak = false
  vim.wo[st.edit_win].breakindent = false
  vim.wo[st.edit_win].spell = false
  vim.wo[st.edit_win].conceallevel = 0
  vim.wo[st.edit_win].concealcursor = ''

  M.set_nav_keymaps(buf)
  vim.keymap.set('n', cfg().keys.close, function()
    require('notes').close_interactive()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })

  -- wipe the previous real-file buffer so its deleted backing file can't raise E211
  if old ~= buf and api.nvim_buf_is_valid(old) and vim.bo[old].buftype == '' then
    pcall(api.nvim_buf_delete, old, { force = true })
  end
end

-- Scroll the open file from search/notes: sends <C-e>/<C-y> inside edit_win
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
  -- h/j/k/l move spatially between the three windows via wincmd.
  -- Exception: k from the editor always goes to the notes column (not folders),
  -- because wincmd k lands in whichever of the two top windows is above the cursor.
  local function nav()
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok then
      return
    end
    local key = vim.fn.keytrans(char):lower()
    if not key:match('^[hjkl]$') then
      return
    end
    if key == 'k' and api.nvim_get_current_win() == st.edit_win then
      if st.list_win and api.nvim_win_is_valid(st.list_win) then
        api.nvim_set_current_win(st.list_win)
        return
      end
    end
    vim.cmd('wincmd ' .. key)
  end

  vim.keymap.set({ 'n', 'i' }, keys.window_nav, function()
    -- leave insert first (editor may be in insert) so the prefix isn't typed
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
      if closed == st.folders_win or closed == st.list_win or closed == st.edit_win then
        vim.schedule(function()
          require('notes').close()
        end)
      end
    end,
  })

  -- auto-open note when navigating the notes column
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

  -- switch the notes column when navigating the folders column
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = st.folders_buf,
    callback = function()
      if api.nvim_get_current_win() ~= st.folders_win then
        return
      end
      require('notes.picker').select_folder()
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
      -- refresh immediately: mtime and title are already on disk after :w
      require('notes.picker').refresh()
      if cfg().repo ~= '' then
        require('notes.git').sync_on_exit()
      end
    end,
  })
end

local function list_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].statuscolumn = ''
  vim.wo[win].winfixheight = true
end

function M.open()
  local st = require('notes').state

  setup_highlights()

  -- open in a new tab; the base window (from tabnew) becomes the editor
  vim.cmd('tabnew')
  st.tab = api.nvim_get_current_tabpage()
  local base_win = api.nvim_get_current_win()

  -- pin the tab label; tabline plugins can read t:title, built-in tabline uses M.tabline()
  api.nvim_tabpage_set_var(st.tab, 'title', 'notes.nvim')
  if vim.o.tabline == '' then
    _old_tabline = ''
    vim.o.tabline = '%!v:lua.require("notes.ui").tabline()'
  end

  -- wipe the empty buffer that tabnew created
  vim.bo[api.nvim_get_current_buf()].bufhidden = 'wipe'

  -- editor: base window starts with the placeholder scratch buffer
  st.edit_win = base_win
  M.show_placeholder()

  -- notes column: full-width split above editor (split into two columns below)
  st.list_buf = api.nvim_create_buf(false, true)
  vim.bo[st.list_buf].buftype = 'nofile'
  vim.bo[st.list_buf].bufhidden = 'wipe'
  vim.bo[st.list_buf].swapfile = false
  vim.bo[st.list_buf].filetype = 'NotesList'
  vim.bo[st.list_buf].modifiable = false
  st.list_win = api.nvim_open_win(st.list_buf, true, {
    split = 'above',
    win = base_win,
    height = cfg().list_height,
  })
  list_win_opts(st.list_win)
  vim.wo[st.list_win].statusline = ' Notes'

  -- folders column: split off the left of the notes column
  st.folders_buf = api.nvim_create_buf(false, true)
  vim.bo[st.folders_buf].buftype = 'nofile'
  vim.bo[st.folders_buf].bufhidden = 'wipe'
  vim.bo[st.folders_buf].swapfile = false
  vim.bo[st.folders_buf].filetype = 'NotesFolders'
  vim.bo[st.folders_buf].modifiable = false
  st.folders_win = api.nvim_open_win(st.folders_buf, false, {
    split = 'left',
    win = st.list_win,
    width = cfg().folders_width,
  })
  list_win_opts(st.folders_win)
  vim.wo[st.folders_win].winfixwidth = true
  vim.wo[st.folders_win].statusline = ' Folders'

  local picker = require('notes.picker')
  picker.attach_folders(st.folders_buf)
  picker.attach_notes(st.list_buf)
  M.set_nav_keymaps(st.folders_buf)
  M.set_nav_keymaps(st.list_buf)
  M.set_nav_keymaps(st.edit_buf)

  setup_autocmds(st)

  -- focus the folders column on open
  api.nvim_set_current_win(st.folders_win)
end

function M.open_in_edit(path)
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  if st.current_file == path then
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
  vim.bo[buf].filetype = 'markdown'

  -- set window options like a normal file; do NOT pin StatusLine/CursorLineNr in
  -- winhighlight — the user's global UpdateInsertModeColor (InsertEnter/Leave) must work
  vim.wo[st.edit_win].number = true
  vim.wo[st.edit_win].relativenumber = true
  vim.wo[st.edit_win].cursorline = true
  vim.wo[st.edit_win].signcolumn = 'no'
  vim.wo[st.edit_win].wrap = true
  vim.wo[st.edit_win].linebreak = true
  vim.wo[st.edit_win].breakindent = true
  vim.wo[st.edit_win].spell = false
  vim.wo[st.edit_win].conceallevel = 2
  vim.wo[st.edit_win].concealcursor = 'nc'
  -- %m shows [+] while the note has unsaved changes, nothing once written
  vim.wo[st.edit_win].statusline = ' Editor %m'

  M.set_nav_keymaps(buf)
  vim.keymap.set('n', cfg().keys.close, function()
    require('notes').close_interactive()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })

  -- live title update: update the notes column while typing, without a disk read
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      require('notes.picker').update_live_title(buf, path)
    end,
  })
  -- focus is NOT moved: opening a note leaves the cursor in the notes/folders window
end

function M.close()
  local st = require('notes').state
  if st.closing then
    return
  end

  st.closing = true

  local tab = st.tab
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

  if _old_tabline ~= nil then
    vim.o.tabline = _old_tabline
    _old_tabline = nil
  end

  if tab and api.nvim_tabpage_is_valid(tab) then
    pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(tab))
  end

  st.closing = false
end

return M
