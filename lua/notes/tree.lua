-- File tree: scan, render, keymaps (a / d / x / p / CR / R)

local M = {}

local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('notes_tree')

local function cfg()
  return require('notes').config
end

local function state()
  return require('notes').state
end

local function list_md(dir)
  local files = {}
  for name, ftype in vim.fs.dir(dir) do
    if ftype == 'file' and name:sub(1, 1) ~= '.' and name:match('%.md$') then
      table.insert(files, name)
    end
  end
  table.sort(files)
  return files
end

local function scan()
  local dir = cfg().dir
  local st = state()
  local nodes = {}

  if fn.isdirectory(dir) ~= 1 then
    return nodes
  end

  local dirs, files = {}, {}
  for name, ftype in vim.fs.dir(dir) do
    if name:sub(1, 1) ~= '.' then
      if ftype == 'directory' then
        table.insert(dirs, name)
      elseif ftype == 'file' and name:match('%.md$') then
        table.insert(files, name)
      end
    end
  end
  table.sort(dirs)
  table.sort(files)

  for _, name in ipairs(dirs) do
    local path = dir .. '/' .. name
    table.insert(nodes, { type = 'dir', name = name, path = path, depth = 0 })

    if st.expanded[path] then
      for _, sname in ipairs(list_md(path)) do
        table.insert(nodes, {
          type = 'file',
          name = sname,
          path = path .. '/' .. sname,
          depth = 1,
          parent = path,
        })
      end
    end
  end

  for _, name in ipairs(files) do
    table.insert(nodes, {
      type = 'file',
      name = name,
      path = dir .. '/' .. name,
      depth = 0,
      parent = dir,
    })
  end

  return nodes
end

function M.render()
  local st = state()

  if not (st.tree_buf and api.nvim_buf_is_valid(st.tree_buf)) then
    return
  end

  local nodes = scan()
  st.nodes = nodes

  local lines = {}
  for _, node in ipairs(nodes) do
    local indent = string.rep('  ', node.depth)
    if node.type == 'dir' then
      local arrow = st.expanded[node.path] and '▾' or '▸'
      table.insert(lines, indent .. arrow .. ' ' .. node.name .. '/')
    else
      table.insert(lines, indent .. '  ' .. node.name)
    end
  end

  if #lines == 0 then
    lines = { '(empty — press a to create)' }
    st.nodes = {}
  end

  vim.bo[st.tree_buf].modifiable = true
  api.nvim_buf_set_lines(st.tree_buf, 0, -1, false, lines)
  vim.bo[st.tree_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.tree_buf, ns, 0, -1)
  for i, node in ipairs(st.nodes) do
    local group
    if st.cut_node and node.path == st.cut_node.path then
      group = 'NotesCut'
    elseif node.type == 'dir' then
      group = 'NotesDir'
    else
      group = 'NotesFile'
    end
    api.nvim_buf_add_highlight(st.tree_buf, ns, group, i - 1, 0, -1)
  end
end

local function current_node()
  local st = state()
  if not (st.nodes and st.tree_win and api.nvim_win_is_valid(st.tree_win)) then
    return nil
  end
  local lnum = api.nvim_win_get_cursor(st.tree_win)[1]
  return st.nodes[lnum]
end

local function target_dir(node)
  local root = cfg().dir
  if node then
    if node.type == 'dir' then
      return node.path
    elseif node.parent then
      return node.parent
    end
  end
  return root
end

function M.open_file(node)
  local st = state()

  if not (st.edit_win and api.nvim_win_is_valid(st.edit_win)) then
    return
  end

  api.nvim_win_call(st.edit_win, function()
    vim.cmd('edit ' .. fn.fnameescape(node.path))
  end)

  require('notes.ui').set_nav_keymaps(api.nvim_win_get_buf(st.edit_win))
  require('notes.ui').set_edit_title(node.path)
  api.nvim_set_current_win(st.edit_win)
end

function M.toggle_dir()
  local node = current_node()
  if not node or node.type ~= 'dir' then
    return
  end

  local st = state()
  st.expanded[node.path] = not st.expanded[node.path] or nil
  M.render()
end

function M.open_selected()
  local node = current_node()
  if not node or node.type ~= 'file' then
    return
  end
  M.open_file(node)
end

-- new.md, new1.md, new2.md… — первое свободное имя в каталоге base
local function default_name(base)
  if fn.filereadable(base .. '/new.md') ~= 1 then
    return 'new.md'
  end
  local i = 1
  while fn.filereadable(base .. '/new' .. i .. '.md') == 1 do
    i = i + 1
  end
  return 'new' .. i .. '.md'
end

function M.create_file()
  local node = current_node()
  local base = target_dir(node)

  vim.ui.input({ prompt = 'New file: ', default = default_name(base) }, function(input)
    if not input or input == '' then
      return
    end

    local name = input
    if not name:match('%.md$') then
      name = name .. '.md'
    end
    fn.writefile({}, base .. '/' .. name)
    M.render()
  end)
end

function M.create_dir()
  local root = cfg().dir

  vim.ui.input({ prompt = 'New folder: ' }, function(input)
    if not input or input == '' then
      return
    end
    -- directories only at the root level (one level of nesting)
    fn.mkdir(root .. '/' .. input, 'p')
    M.render()
  end)
end

function M.delete()
  local node = current_node()
  if not node then
    return
  end

  local choice = fn.confirm('Delete "' .. node.name .. '"?', '&Yes\n&No', 2)
  if choice == 1 then
    fn.delete(node.path, 'rf')
    state().expanded[node.path] = nil
    M.render()
  end
end

function M.cut()
  local node = current_node()
  if not node or node.type ~= 'file' then
    vim.notify('[notes.nvim] Only files can be moved', vim.log.levels.WARN)
    return
  end

  state().cut_node = node
  M.render()
  vim.notify('[notes.nvim] Cut: ' .. node.name)
end

function M.paste()
  local st = state()
  local src = st.cut_node
  if not src then
    return
  end

  local node = current_node()
  local dest = target_dir(node) .. '/' .. src.name

  if dest == src.path then
    st.cut_node = nil
    return
  end

  if fn.filereadable(dest) == 1 then
    vim.notify('[notes.nvim] File already exists: ' .. src.name, vim.log.levels.WARN)
    return
  end

  fn.rename(src.path, dest)
  st.cut_node = nil
  M.render()
end

function M.attach(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map(keys.toggle_dir, M.toggle_dir, 'Notes: toggle folder')
  map(keys.open_file, M.open_selected, 'Notes: open file')
  map(keys.create_file, M.create_file, 'Notes: create file')
  map(keys.create_dir, M.create_dir, 'Notes: create folder')
  map(keys.delete, M.delete, 'Notes: delete')
  map(keys.cut, M.cut, 'Notes: cut')
  map(keys.paste, M.paste, 'Notes: paste')
  map(keys.refresh, M.render, 'Notes: refresh')
  map(keys.open_github, function()
    require('notes.git').open_github()
  end, 'Notes: open GitHub')
end

return M
