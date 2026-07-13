-- Tab-based layout: filetree explorer (top) + editor (bottom)

local M = {}

local api = vim.api
local fn = vim.fn

-- saved value of `tabline` before we override it; nil means we didn't override
local _old_tabline = nil

-- Sync status icons shown in the tab title when a remote repo is configured.
-- Nerd Font glyphs are used when nvim-web-devicons is already loaded in the session
-- (a reliable proxy for Nerd Fonts being present), otherwise plain Unicode fallback.
local SYNC_ICONS = {
  idle     = { plain = '\xe2\x9c\x93', nf = '\xef\x80\x8c' }, -- ✓ / nf-fa-check
  conflict = { plain = '!', nf = '\xee\xa9\xac' }, -- ! / nf-cod-warning
}

local SPIN_FRAMES = { '\xe2\xa0\x8b', '\xe2\xa0\x99', '\xe2\xa0\xb9', '\xe2\xa0\xb8',
                      '\xe2\xa0\xbc', '\xe2\xa0\xb4', '\xe2\xa0\xa6', '\xe2\xa0\xa7',
                      '\xe2\xa0\x87', '\xe2\xa0\x8f' } -- ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏

-- Tree icons shown on folder rows (closed/open). No default note icon: notes are
-- distinguished by indent + date, not an icon (see FILETREE_EXPLORER_VISUAL.md).
local TREE_ICONS = {
  folder      = { plain = '\xe2\x96\xb6', nf = '\xf3\xb0\x89\x8b' }, -- ▶ / nf-md-folder
  folder_open = { plain = '\xe2\x96\xbc', nf = '\xf3\xb0\x9d\xb0' }, -- ▼ / nf-md-folder_open
}

local _sync_timer = nil
local _sync_frame = 0

local function stop_spin()
  if _sync_timer then
    _sync_timer:stop()
    _sync_timer:close()
    _sync_timer = nil
  end
end

local function has_nerd_fonts()
  return package.loaded['nvim-web-devicons'] ~= nil
    or pcall(require, 'nvim-web-devicons')
end

-- Resolved tree icons for the current session: user override (config.tree_icons)
-- wins per key, otherwise Nerd Font glyph (if available) or the plain fallback.
function M.tree_icons()
  local custom = require('notes').config.tree_icons
  local nf = has_nerd_fonts()
  local function pick(key)
    if custom and custom[key] then
      return custom[key]
    end
    local row = TREE_ICONS[key]
    return row and (nf and row.nf or row.plain) or ''
  end
  return {
    folder = pick('folder'),
    folder_open = pick('folder_open'),
    note = (custom and custom.note) or '',
  }
end

function M.set_sync_status(status)
  stop_spin()
  local st = require('notes').state
  local c = require('notes').config
  if not (st.tab and api.nvim_tabpage_is_valid(st.tab)) then
    return
  end

  if status == 'syncing' and c.repo ~= '' then
    local custom = c.sync_icons and c.sync_icons.syncing
    if custom then
      api.nvim_tabpage_set_var(st.tab, 'title', 'notes.nvim ' .. custom)
    else
      _sync_frame = 1
      api.nvim_tabpage_set_var(st.tab, 'title', 'notes.nvim ' .. SPIN_FRAMES[1])
      _sync_timer = vim.uv.new_timer()
      _sync_timer:start(100, 100, function()
        vim.schedule(function()
          local s = require('notes').state
          if not (s.tab and api.nvim_tabpage_is_valid(s.tab)) then
            stop_spin()
            return
          end
          _sync_frame = (_sync_frame % #SPIN_FRAMES) + 1
          api.nvim_tabpage_set_var(s.tab, 'title', 'notes.nvim ' .. SPIN_FRAMES[_sync_frame])
          vim.cmd('redrawtabline')
        end)
      end)
    end
    return
  end

  local label = 'notes.nvim'
  if c.repo ~= '' then
    local row = SYNC_ICONS[status]
    if row then
      local custom = c.sync_icons and c.sync_icons[status]
      local icon = custom or (has_nerd_fonts() and row.nf or row.plain)
      label = label .. ' ' .. icon
    end
  end
  api.nvim_tabpage_set_var(st.tab, 'title', label)
end

-- live-title autocmd group; cleared per editor buffer so revisiting a note does
-- not stack duplicate TextChanged handlers
local live_title_group = api.nvim_create_augroup('NotesEditLiveTitle', { clear = true })

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
  -- wavy underline (undercurl) in the error color over the note/folder name.
  -- sp drives the curl color; take it from DiagnosticError (fall back to ErrorMsg),
  -- so we get a *wavy* line regardless of whether the colorscheme's diagnostic
  -- underline groups use plain underline.
  local err = api.nvim_get_hl(0, { name = 'DiagnosticError', link = false })
  if not (err and err.fg) then
    err = api.nvim_get_hl(0, { name = 'ErrorMsg', link = false })
  end
  api.nvim_set_hl(0, 'NotesConflict', {
    default = true,
    undercurl = true,
    sp = err and err.fg or nil,
    cterm = { undercurl = true },
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
  vim.keymap.set('n', cfg().keys.toggle_panels, function()
    M.toggle_panels()
  end, { buffer = buf, silent = true, desc = 'Notes: toggle panels' })

  -- wipe the previous real-file buffer so its deleted backing file can't raise E211
  if old ~= buf and api.nvim_buf_is_valid(old) and vim.bo[old].buftype == '' then
    pcall(api.nvim_buf_delete, old, { force = true })
  end
end

-- Scroll the open file from the explorer: sends <C-e>/<C-y> inside edit_win
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
  -- h/j/k/l move spatially between the two windows via wincmd.
  -- Exception: k from the editor always goes to the explorer window, because
  -- wincmd k lands wherever the cursor happens to be above.
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
      if st.explorer_win and api.nvim_win_is_valid(st.explorer_win) then
        api.nvim_set_current_win(st.explorer_win)
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

-- CursorMoved handler for the explorer buffer. Kept in a separate augroup so it
-- can be re-registered after toggle_panels recreates the buffer.
local function setup_panel_autocmds(st)
  local group = api.nvim_create_augroup('NotesPanels', { clear = true })

  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = st.explorer_buf,
    callback = function()
      if api.nvim_get_current_win() ~= st.explorer_win then
        return
      end
      require('notes.picker').open_selected()
    end,
  })
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
      if closed == st.explorer_win or closed == st.edit_win then
        vim.schedule(function()
          require('notes').close()
        end)
      end
    end,
  })

  setup_panel_autocmds(st)

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

  -- pin the tab label with initial sync status; updated by git.lua during sync
  M.set_sync_status('syncing')
  if vim.o.tabline == '' then
    _old_tabline = ''
    vim.o.tabline = '%!v:lua.require("notes.ui").tabline()'
  end

  -- wipe the empty buffer that tabnew created
  vim.bo[api.nvim_get_current_buf()].bufhidden = 'wipe'

  -- editor: base window starts with the placeholder scratch buffer
  st.edit_win = base_win
  M.show_placeholder()

  -- explorer: full-width split above the editor
  st.explorer_buf = api.nvim_create_buf(false, true)
  vim.bo[st.explorer_buf].buftype = 'nofile'
  vim.bo[st.explorer_buf].bufhidden = 'wipe'
  vim.bo[st.explorer_buf].swapfile = false
  vim.bo[st.explorer_buf].filetype = 'NotesExplorer'
  vim.bo[st.explorer_buf].modifiable = false
  st.explorer_win = api.nvim_open_win(st.explorer_buf, true, {
    split = 'above',
    win = base_win,
    height = cfg().list_height,
  })
  list_win_opts(st.explorer_win)
  vim.wo[st.explorer_win].statusline = ' Explorer'

  local picker = require('notes.picker')
  picker.attach_explorer(st.explorer_buf)
  M.set_nav_keymaps(st.explorer_buf)
  M.set_nav_keymaps(st.edit_buf)

  setup_autocmds(st)

  -- focus the explorer on open
  api.nvim_set_current_win(st.explorer_win)
end

local function editor_path_label(path)
  local notes = require('notes')
  local dir = notes.config.dir
  local rel = path:sub(#dir + 2)
  local folder = rel:match('^(.+)/[^/]+$') or 'Notes'
  local title = 'New Note'
  for _, n in ipairs(notes.state.notes_all or {}) do
    if n.file == path then
      title = n.title
      break
    end
  end
  return folder:gsub('%%', '%%%%') .. '/' .. title:gsub('%%', '%%%%')
end

function M.refresh_editor_statusline()
  local st = require('notes').state
  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then return end
  if not st.current_file then return end
  vim.wo[st.edit_win].statusline = ' ' .. editor_path_label(st.current_file) .. ' %m'
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
  vim.wo[st.edit_win].statusline = ' ' .. editor_path_label(path) .. ' %m'

  M.set_nav_keymaps(buf)
  vim.keymap.set('n', cfg().keys.close, function()
    require('notes').close_interactive()
  end, { buffer = buf, silent = true, desc = 'Notes: close' })
  vim.keymap.set('n', cfg().keys.toggle_panels, function()
    M.toggle_panels()
  end, { buffer = buf, silent = true, desc = 'Notes: toggle panels' })

  -- live title update: update the tree while typing, without a disk read.
  -- clear any previous handler on this buffer first so revisiting a note does not
  -- stack duplicate autocmds (each would re-run update_live_title per keystroke)
  api.nvim_clear_autocmds({ group = live_title_group, buffer = buf })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = live_title_group,
    buffer = buf,
    callback = function()
      require('notes.picker').update_live_title(buf, path)
    end,
  })
  -- focus is NOT moved: opening a note leaves the cursor in the explorer window
end

-- Toggle the explorer window. Hidden by closing the window; the buffer is wiped
-- (bufhidden=wipe). On restore the window and buffer are recreated and
-- re-populated. State is nil'd BEFORE closing so WinClosed doesn't mistake the
-- controlled close for an external one and call notes.close().
function M.toggle_panels()
  local notes = require('notes')
  local st = notes.state
  if not notes.is_open() then
    return
  end

  if st.panels_hidden then
    if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
      return
    end

    st.explorer_buf = api.nvim_create_buf(false, true)
    vim.bo[st.explorer_buf].buftype = 'nofile'
    vim.bo[st.explorer_buf].bufhidden = 'wipe'
    vim.bo[st.explorer_buf].swapfile = false
    vim.bo[st.explorer_buf].filetype = 'NotesExplorer'
    vim.bo[st.explorer_buf].modifiable = false
    st.explorer_win = api.nvim_open_win(st.explorer_buf, false, {
      split = 'above',
      win = st.edit_win,
      height = cfg().list_height,
    })
    list_win_opts(st.explorer_win)
    vim.wo[st.explorer_win].statusline = ' Explorer'

    local picker = require('notes.picker')
    picker.attach_explorer(st.explorer_buf)
    M.set_nav_keymaps(st.explorer_buf)

    setup_panel_autocmds(st)
    picker.populate()
    st.panels_hidden = false
  else
    local ew = st.explorer_win
    -- nil state before close: WinClosed compares against st.explorer_win, which
    -- is now nil, so notes.close() is not triggered
    st.explorer_win = nil
    st.explorer_buf = nil
    st.panels_hidden = true
    if ew and api.nvim_win_is_valid(ew) then
      api.nvim_win_close(ew, true)
    end
    if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
      api.nvim_set_current_win(st.edit_win)
    end
  end
end

function M.close()
  stop_spin()
  local st = require('notes').state
  if st.closing then
    return
  end

  st.closing = true

  local tab = st.tab
  st.tab = nil
  st.explorer_win = nil
  st.explorer_buf = nil
  st.edit_win = nil
  st.edit_buf = nil
  st.current_file = nil
  st.cut = nil
  st.cut_folder = nil
  st.expanded_folders = nil
  st.tree_items = nil
  st.notes_all = nil
  st.conflicts = nil
  st.panels_hidden = false

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
