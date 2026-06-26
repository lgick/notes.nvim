-- Two-pane model (macOS Notes style): folders column + notes column.
-- Notes are ID-named files; the title is the first non-blank line of their content.

local M = {}

local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('notes_list')
local ns_active = api.nvim_create_namespace('notes_active')
local ns_folders = api.nvim_create_namespace('notes_folders')

local EMPTY_TITLE = 'New Note'
local ROOT_LABEL = 'Notes' -- virtual folder for notes that live at the repo root

local function cfg()
  return require('notes').config
end

local function state()
  return require('notes').state
end

local function sync()
  if cfg().repo ~= '' then
    require('notes.git').sync_on_exit()
  end
end

-- Title = first non-blank line of the file; empty note → EMPTY_TITLE.
-- Reads only the first lines, not the whole file.
function M.title_of(file)
  local ok, lines = pcall(fn.readfile, file, '', 20)
  if ok then
    for _, l in ipairs(lines) do
      local t = vim.trim(l)
      if t ~= '' then
        return t, false
      end
    end
  end
  return EMPTY_TITLE, true
end

-- Scan builds two structures: the folders column (one level deep) and the flat
-- notes list. Hidden entries (.git, .gitkeep) are skipped.
function M.scan()
  local dir = cfg().dir
  local real = {} -- real top-level folder names
  local notes = {}

  local function add_file(abs, folder)
    local fstat = vim.uv.fs_stat(abs)
    local title, empty = M.title_of(abs)
    notes[#notes + 1] = {
      file = abs,
      folder = folder,
      title = title,
      empty = empty,
      mtime = fstat and fstat.mtime.sec or 0,
    }
  end

  if fn.isdirectory(dir) == 1 then
    for name, ftype in vim.fs.dir(dir) do
      if name:sub(1, 1) ~= '.' then
        local abs = dir .. '/' .. name
        if ftype == 'directory' then
          real[#real + 1] = name
          for sub, subtype in vim.fs.dir(abs) do
            if sub:sub(1, 1) ~= '.' and subtype == 'file' then
              add_file(abs .. '/' .. sub, name)
            end
          end
        elseif ftype == 'file' then
          add_file(abs, '')
        end
      end
    end
  end

  table.sort(notes, function(a, b)
    if a.empty ~= b.empty then
      return a.empty -- empty notes always pinned to the top
    end
    return a.mtime > b.mtime
  end)

  -- folder recency = mtime of its most recently modified note
  local fm = {}
  for _, n in ipairs(notes) do
    if n.folder ~= '' then
      fm[n.folder] = math.max(fm[n.folder] or 0, n.mtime)
    end
  end
  table.sort(real, function(a, b)
    return (fm[a] or 0) > (fm[b] or 0)
  end)

  -- root "Notes" pinned first, then real folders by recency
  local folders = { { name = ROOT_LABEL, folder = nil } }
  for _, name in ipairs(real) do
    folders[#folders + 1] = { name = name, folder = name }
  end

  state().folders = folders
  state().notes_all = notes
end

-- If the selected folder vanished (deleted/renamed), fall back to the root "Notes".
local function validate_folder()
  local st = state()
  if st.current_folder == nil then
    return
  end
  for _, f in ipairs(st.folders or {}) do
    if f.folder == st.current_folder then
      return
    end
  end
  st.current_folder = nil
end

-- current_folder nil = root "Notes" → notes with folder == ''; otherwise that folder.
function M.filter()
  local st = state()
  local target = st.current_folder or ''
  local out = {}
  for _, n in ipairs(st.notes_all or {}) do
    if n.folder == target then
      out[#out + 1] = n
    end
  end
  st.items = out
end

function M.render_folders()
  local st = state()
  if not (st.folders_buf and api.nvim_buf_is_valid(st.folders_buf)) then
    return
  end

  local lines = {}
  for _, f in ipairs(st.folders or {}) do
    lines[#lines + 1] = f.name
  end

  vim.bo[st.folders_buf].modifiable = true
  api.nvim_buf_set_lines(st.folders_buf, 0, -1, false, lines)
  vim.bo[st.folders_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.folders_buf, ns_folders, 0, -1)
  for i, f in ipairs(st.folders or {}) do
    local hl = f.folder == st.current_folder and 'NotesActive' or 'NotesDir'
    api.nvim_buf_set_extmark(st.folders_buf, ns_folders, i - 1, 0, { line_hl_group = hl })
  end
end

function M.highlight_active()
  local st = state()
  if not (st.list_buf and api.nvim_buf_is_valid(st.list_buf)) then
    return
  end
  api.nvim_buf_clear_namespace(st.list_buf, ns_active, 0, -1)
  if st.current_file then
    for i, it in ipairs(st.items or {}) do
      if it.file == st.current_file then
        api.nvim_buf_set_extmark(st.list_buf, ns_active, i - 1, 0, { line_hl_group = 'NotesActive' })
        break
      end
    end
  end
end

function M.render_notes()
  local st = state()
  if not (st.list_buf and api.nvim_buf_is_valid(st.list_buf)) then
    return
  end

  local lines = {}
  for _, it in ipairs(st.items or {}) do
    lines[#lines + 1] = os.date('%d.%m.%Y', it.mtime) .. ' - ' .. it.title
  end
  local empty = #lines == 0
  if empty then
    lines = { '(no notes)' }
  end

  vim.bo[st.list_buf].modifiable = true
  api.nvim_buf_set_lines(st.list_buf, 0, -1, false, lines)
  vim.bo[st.list_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.list_buf, ns, 0, -1)
  if not empty then
    for i, it in ipairs(st.items) do
      if it.file == st.cut then
        -- priority > NotesActive (0) so NotesCut is never hidden by the active-note highlight
        api.nvim_buf_set_extmark(st.list_buf, ns, i - 1, 0, { line_hl_group = 'NotesCut', priority = 200 })
      end
    end
  end

  if st.list_win and api.nvim_win_is_valid(st.list_win) and not empty then
    api.nvim_win_set_cursor(st.list_win, { 1, 0 })
  end

  M.highlight_active()
end

-- Update the title of the currently open note in-memory from the buffer content
-- (without a disk read), then re-render only the notes column. Called on every
-- TextChanged/TextChangedI in the editor buffer so the list stays in sync while typing.
function M.update_live_title(buf, file)
  local lines = api.nvim_buf_get_lines(buf, 0, 50, false)
  local title, empty = EMPTY_TITLE, true
  for _, l in ipairs(lines) do
    local t = vim.trim(l)
    if t ~= '' then
      title, empty = t, false
      break
    end
  end
  local st = state()
  for _, tbl in ipairs({ st.notes_all, st.items }) do
    for _, n in ipairs(tbl or {}) do
      if n.file == file then
        n.title = title
        n.empty = empty
      end
    end
  end
  M.render_notes()
end

function M.populate()
  M.scan()
  validate_folder()
  M.filter()
  M.render_folders()
  M.render_notes()
end

M.refresh = M.populate

local function selected_note()
  local st = state()
  if not (st.list_win and api.nvim_win_is_valid(st.list_win)) then
    return nil
  end
  local l = api.nvim_win_get_cursor(st.list_win)[1]
  return (st.items or {})[l]
end

local function selected_folder()
  local st = state()
  if not (st.folders_win and api.nvim_win_is_valid(st.folders_win)) then
    return nil
  end
  local l = api.nvim_win_get_cursor(st.folders_win)[1]
  return (st.folders or {})[l]
end

function M.open_selected()
  local it = selected_note()
  if it then
    require('notes.ui').open_in_edit(it.file)
    M.highlight_active()
  end
end

-- Folder column cursor moved → switch the notes column to that folder.
function M.select_folder()
  local f = selected_folder()
  if not f then
    return
  end
  state().current_folder = f.folder
  M.filter()
  M.render_folders()
  M.render_notes()
end

-- Unique ID filename (timestamp, no extension) inside target_dir.
local function new_id(target_dir)
  local base = os.date('%Y%m%d%H%M%S')
  local name = base
  local i = 1
  while
    fn.filereadable(target_dir .. '/' .. name) == 1
    or fn.isdirectory(target_dir .. '/' .. name) == 1
  do
    name = base .. '-' .. i
    i = i + 1
  end
  return name
end

-- New note in the current folder (or root when "Notes" is selected). Opens it in the
-- editor but keeps focus in the notes column. Only one empty note may exist per folder:
-- an existing one is reopened instead.
function M.create_note()
  local dir = cfg().dir
  local cf = state().current_folder
  local folder = cf or ''
  local target_dir = cf and (dir .. '/' .. cf) or dir

  for _, n in ipairs(state().notes_all or {}) do
    if n.empty and n.folder == folder then
      require('notes.ui').open_in_edit(n.file)
      M.populate()
      return
    end
  end

  fn.mkdir(target_dir, 'p')
  local target = target_dir .. '/' .. new_id(target_dir)
  fn.writefile({}, target)
  M.populate()
  require('notes.ui').open_in_edit(target)
  sync()
end

-- Folders are one level deep: a name with '/' is rejected.
function M.create_folder()
  vim.ui.input({ prompt = 'New folder: ' }, function(input)
    if not input or input == '' then
      return
    end
    if input:find('/') then
      vim.notify('[notes.nvim] Nested folders are not supported', vim.log.levels.WARN)
      return
    end
    local path = cfg().dir .. '/' .. input
    fn.mkdir(path, 'p')
    -- .gitkeep lets an otherwise empty folder be committed and synced
    fn.writefile({}, path .. '/.gitkeep')
    M.populate()
    sync()
  end)
end

function M.rename_folder()
  local f = selected_folder()
  if not f or f.folder == nil then
    vim.notify('[notes.nvim] Select a folder to rename', vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = 'Rename folder: ', default = f.folder }, function(input)
    if not input or input == '' or input == f.folder then
      return
    end
    if input:find('/') then
      vim.notify('[notes.nvim] Nested folders are not supported', vim.log.levels.WARN)
      return
    end
    local dir = cfg().dir
    local oldp = dir .. '/' .. f.folder
    local newp = dir .. '/' .. input
    local st = state()
    local cur = st.current_file
    local inside = cur and cur:sub(1, #oldp + 1) == oldp .. '/'

    fn.rename(oldp, newp)

    if inside then
      local old_buf = st.edit_buf
      require('notes.ui').open_in_edit(newp .. cur:sub(#oldp + 1))
      if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
        pcall(api.nvim_buf_delete, old_buf, { force = true })
      end
    end
    if st.current_folder == f.folder then
      st.current_folder = input
    end
    M.populate()
    sync()
  end)
end

function M.delete_note()
  local it = selected_note()
  if not it then
    return
  end

  local choice = fn.confirm('Delete "' .. it.title .. '"?', '&Yes\n&No', 2)
  if choice ~= 1 then
    return
  end
  if state().current_file == it.file then
    require('notes.ui').show_placeholder()
  end
  fn.delete(it.file)
  M.populate()
  sync()
end

function M.delete_folder()
  local f = selected_folder()
  if not f or f.folder == nil then
    vim.notify('[notes.nvim] Select a folder to delete', vim.log.levels.WARN)
    return
  end

  local prompt = 'Delete folder "' .. f.folder .. '" and all its notes?'
  if fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
    return
  end
  local path = cfg().dir .. '/' .. f.folder
  local cur = state().current_file
  if cur and (cur == path or cur:sub(1, #path + 1) == path .. '/') then
    require('notes.ui').show_placeholder()
  end
  fn.delete(path, 'rf')
  if state().current_folder == f.folder then
    state().current_folder = nil
  end
  M.populate()
  sync()
end

-- Mark the selected note for moving and hand focus to the folders column.
function M.cut_note()
  local it = selected_note()
  if not it then
    return
  end
  state().cut = it.file
  M.render_notes()
  vim.notify('[notes.nvim] Navigate to a folder and press ' .. cfg().keys.paste)
  local st = state()
  if st.folders_win and api.nvim_win_is_valid(st.folders_win) then
    api.nvim_set_current_win(st.folders_win)
  end
end

-- <CR> in the folders column: focus the notes column.
function M.folder_enter()
  local st = state()
  if st.list_win and api.nvim_win_is_valid(st.list_win) then
    api.nvim_set_current_win(st.list_win)
  end
end

-- p in the folders column: drop the marked note into the selected folder.
function M.paste_note()
  local st = state()
  if not st.cut then
    return
  end

  local f = selected_folder()
  if not f then
    return
  end
  local dir = cfg().dir
  local target_dir = f.folder and (dir .. '/' .. f.folder) or dir
  local src = st.cut
  local target = target_dir .. '/' .. fn.fnamemodify(src, ':t')
  st.cut = nil

  if src == target then
    M.render_notes()
    return
  end

  fn.mkdir(target_dir, 'p')
  fn.rename(src, target)

  if st.current_file == src then
    local old_buf = st.edit_buf
    require('notes.ui').open_in_edit(target)
    if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
      pcall(api.nvim_buf_delete, old_buf, { force = true })
    end
  end
  M.populate()
  sync()
end

function M.attach_folders(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('h', '<Nop>', 'Notes: no horizontal move')
  map('l', '<Nop>', 'Notes: no horizontal move')
  map(keys.open_file, M.folder_enter, 'Notes: focus notes column')
  map(keys.paste, M.paste_note, 'Notes: paste note into folder')
  map(keys.create, M.create_folder, 'Notes: create folder')
  map(keys.rename, M.rename_folder, 'Notes: rename folder')
  map(keys.delete, M.delete_folder, 'Notes: delete folder')
  map(keys.refresh, M.refresh, 'Notes: refresh')
  map(keys.open_github, function()
    require('notes.git').open_github()
  end, 'Notes: open GitHub')
  map(keys.close, function()
    require('notes').close_interactive()
  end, 'Notes: close')
end

function M.attach_notes(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('h', '<Nop>', 'Notes: no horizontal move')
  map('l', '<Nop>', 'Notes: no horizontal move')
  map(keys.open_file, function()
    local st = state()
    if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
      api.nvim_set_current_win(st.edit_win)
    end
  end, 'Notes: focus editor')
  map(keys.create, M.create_note, 'Notes: create note')
  map(keys.delete, M.delete_note, 'Notes: delete note')
  map(keys.move, M.cut_note, 'Notes: move note')
  map(keys.refresh, M.refresh, 'Notes: refresh')
  map(keys.open_github, function()
    require('notes.git').open_github()
  end, 'Notes: open GitHub')
  map(keys.scroll_down, function()
    require('notes.ui').scroll_edit(1)
  end, 'Notes: scroll editor down')
  map(keys.scroll_up, function()
    require('notes.ui').scroll_edit(-1)
  end, 'Notes: scroll editor up')
  map(keys.close, function()
    require('notes').close_interactive()
  end, 'Notes: close')
end

return M
