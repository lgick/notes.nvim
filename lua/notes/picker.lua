-- Flat list: recursive scan (any format), substring filter, live render, CRUD actions

local M = {}

local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('notes_list')
local ns_active = api.nvim_create_namespace('notes_active')

local function cfg()
  return require('notes').config
end

local function state()
  return require('notes').state
end

local function current_input_text()
  local st = state()
  if not (st.input_buf and api.nvim_buf_is_valid(st.input_buf)) then
    return ''
  end
  return api.nvim_buf_get_lines(st.input_buf, 0, 1, false)[1] or ''
end

local function clear_input()
  local st = state()
  if st.input_buf and api.nvim_buf_is_valid(st.input_buf) then
    api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { '' })
  end
end

function M.scan()
  local dir = cfg().dir
  local items = {}

  local function walk(d, prefix)
    for name, ftype in vim.fs.dir(d) do
      if name:sub(1, 1) ~= '.' then -- skip hidden entries (.git included)
        local abs = d .. '/' .. name
        local rel = prefix == '' and name or prefix .. '/' .. name
        if ftype == 'directory' then
          walk(abs, rel)
        elseif ftype == 'file' then
          local fstat = vim.uv.fs_stat(abs)
          items[#items + 1] = { file = abs, rel = rel, mtime = fstat and fstat.mtime.sec or 0 }
        end
      end
    end
  end

  if fn.isdirectory(dir) == 1 then
    walk(dir, '')
  end
  table.sort(items, function(a, b)
    return a.mtime > b.mtime -- most recent first
  end)
  state().all_items = items
end

function M.filter(query)
  query = (query or ''):lower()
  local out = {}
  for _, it in ipairs(state().all_items or {}) do
    if query == '' or it.rel:lower():find(query, 1, true) then
      out[#out + 1] = it
    end
  end
  state().items = out
end

function M.highlight_active()
  local st = state()
  if not (st.list_buf and api.nvim_buf_is_valid(st.list_buf)) then
    return
  end
  api.nvim_buf_clear_namespace(st.list_buf, ns_active, 0, -1)
  local current_file = st.current_file
  if current_file then
    for i, it in ipairs(st.items or {}) do
      if it.file == current_file then
        api.nvim_buf_add_highlight(st.list_buf, ns_active, 'NotesActive', i - 1, 0, -1)
        break
      end
    end
  end
end

function M.render_list()
  local st = state()
  if not (st.list_buf and api.nvim_buf_is_valid(st.list_buf)) then
    return
  end

  local lines = {}
  for _, it in ipairs(st.items or {}) do
    lines[#lines + 1] = it.rel
  end
  local empty = #lines == 0
  if empty then
    lines = { '(no matches)' }
  end

  vim.bo[st.list_buf].modifiable = true
  api.nvim_buf_set_lines(st.list_buf, 0, -1, false, lines)
  vim.bo[st.list_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.list_buf, ns, 0, -1)
  if not empty then
    local query = current_input_text():lower()
    for i = 1, #st.items do
      api.nvim_buf_add_highlight(st.list_buf, ns, 'NotesFile', i - 1, 0, -1)
      if query ~= '' then
        local rel_lower = st.items[i].rel:lower()
        local s, e = rel_lower:find(query, 1, true)
        if s then
          api.nvim_buf_add_highlight(st.list_buf, ns, 'NotesMatch', i - 1, s - 1, e)
        end
      end
    end
  end

  -- reset to line 1: ensures visibility and clears selection after filter change
  if st.list_win and api.nvim_win_is_valid(st.list_win) and not empty then
    api.nvim_win_set_cursor(st.list_win, { 1, 0 })
  end

  M.highlight_active()
end

function M.populate()
  M.scan()
  M.filter('')
  M.render_list()
end

function M.refresh()
  local q = current_input_text()
  M.scan()
  M.filter(q)
  M.render_list()
end

local function selected()
  local st = state()
  if not (st.list_win and api.nvim_win_is_valid(st.list_win)) then
    return nil
  end
  local l = api.nvim_win_get_cursor(st.list_win)[1]
  return (st.items or {})[l]
end

function M.open_selected()
  local it = selected()
  if it then
    require('notes.ui').open_in_edit(it.file)
    M.highlight_active()
  end
end

function M.move(delta)
  local st = state()
  if not (st.list_win and api.nvim_win_is_valid(st.list_win)) then
    return
  end
  local n = #(st.items or {})
  if n == 0 then
    return
  end
  local l = api.nvim_win_get_cursor(st.list_win)[1]
  api.nvim_win_set_cursor(st.list_win, { math.max(1, math.min(n, l + delta)), 0 })
end

-- new, new1, new2… — first free name in the base directory
local function default_name(base)
  if fn.filereadable(base .. '/new.txt') ~= 1 then
    return 'new.txt'
  end
  local i = 1
  while fn.filereadable(base .. '/new' .. i .. '.txt') == 1 do
    i = i + 1
  end
  return 'new' .. i .. '.txt'
end

-- unified create: trailing '/' → folder; no extension → .txt; otherwise as-is.
-- Relative paths accepted; missing parent directories are created automatically.
function M.create_file()
  local dir = cfg().dir
  vim.ui.input({ prompt = 'New (end with / for folder): ', default = default_name(dir) }, function(input)
    if not input or input == '' then
      return
    end

    if input:sub(-1) == '/' then
      fn.mkdir(dir .. '/' .. input, 'p')
      clear_input()
      M.populate()
      if cfg().repo ~= '' then
        require('notes.git').sync_on_exit()
      end
      return
    end

    local target = dir .. '/' .. input
    if fn.fnamemodify(target, ':e') == '' then
      target = target .. '.txt'
    end
    fn.mkdir(fn.fnamemodify(target, ':h'), 'p')
    -- do not truncate an existing file, just open it
    if fn.filereadable(target) ~= 1 then
      fn.writefile({}, target)
    end
    clear_input()
    M.populate()
    require('notes.ui').open_in_edit(target)
    if cfg().repo ~= '' then
      require('notes.git').sync_on_exit()
    end
  end)
end

function M.delete()
  local it = selected()
  if not it then
    return
  end

  local choice = fn.confirm('Delete "' .. it.rel .. '"?', '&Yes\n&No', 2)
  if choice == 1 then
    fn.delete(it.file, 'rf')
    clear_input()
    M.populate()
    if cfg().repo ~= '' then
      require('notes.git').sync_on_exit()
    end
  end
end

-- a new relative path moves the file to any directory (including root)
function M.rename()
  local it = selected()
  if not it then
    return
  end

  vim.ui.input({ prompt = 'Rename: ', default = it.rel }, function(input)
    if not input or input == '' or input == it.rel then
      return
    end
    local target = cfg().dir .. '/' .. input
    fn.mkdir(fn.fnamemodify(target, ':h'), 'p')
    fn.rename(it.file, target)
    clear_input()
    M.populate()
    if cfg().repo ~= '' then
      require('notes.git').sync_on_exit()
    end
  end)
end

function M.attach_input(buf)
  local keys = cfg().keys
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  local function move_and_open(delta)
    M.move(delta)
    M.open_selected()
  end
  map({ 'i', 'n' }, keys.next, function() move_and_open(1) end, 'Notes: next')
  map({ 'i', 'n' }, keys.prev, function() move_and_open(-1) end, 'Notes: prev')
  map({ 'i', 'n' }, '<Down>', function() move_and_open(1) end, 'Notes: next')
  map({ 'i', 'n' }, '<Up>', function() move_and_open(-1) end, 'Notes: prev')
  -- <CR> in search jumps to the list window instead of opening the file directly
  map({ 'i', 'n' }, keys.open_file, function()
    local st = state()
    if st.list_win and api.nvim_win_is_valid(st.list_win) then
      vim.cmd('stopinsert')
      api.nvim_set_current_win(st.list_win)
    end
  end, 'Notes: focus list')
  -- <C-n>/<C-p> in search: cycle selection + auto-open
  map({ 'i', 'n' }, keys.scroll_down, function() move_and_open(1) end, 'Notes: next file')
  map({ 'i', 'n' }, keys.scroll_up, function() move_and_open(-1) end, 'Notes: prev file')
  map({ 'i', 'n' }, keys.close, function()
    require('notes').close_interactive()
  end, 'Notes: close')
end

function M.attach_list(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map(keys.open_file, function()
    local st = state()
    if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
      api.nvim_set_current_win(st.edit_win)
    end
  end, 'Notes: focus editor')
  map(keys.create_file, M.create_file, 'Notes: create')
  map(keys.delete, M.delete, 'Notes: delete')
  map(keys.rename, M.rename, 'Notes: rename')
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
