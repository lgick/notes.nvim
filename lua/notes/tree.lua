-- File tree: scan, render, keymaps (a / d / x / p / CR / R)

local M = {}

local api = vim.api
local fn = vim.fn

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
  api.nvim_set_current_win(st.edit_win)
end

function M.on_enter()
  local node = current_node()
  if not node then
    return
  end

  if node.type == 'dir' then
    local st = state()
    st.expanded[node.path] = not st.expanded[node.path] or nil
    M.render()
  else
    M.open_file(node)
  end
end

function M.create()
  local node = current_node()
  local root = cfg().dir
  local base = target_dir(node)

  vim.ui.input({ prompt = 'Create (name/ for folder, name for .md file): ' }, function(input)
    if not input or input == '' then
      return
    end

    if input:sub(-1) == '/' then
      -- directories only at the root level (one level of nesting)
      local name = input:sub(1, -2)
      fn.mkdir(root .. '/' .. name, 'p')
    else
      local name = input
      if not name:match('%.md$') then
        name = name .. '.md'
      end
      fn.writefile({}, base .. '/' .. name)
    end

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
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('<CR>', M.on_enter, 'Open / expand')
  map('a', M.create, 'Create')
  map('d', M.delete, 'Delete')
  map('x', M.cut, 'Cut')
  map('p', M.paste, 'Paste')
  map('R', M.render, 'Refresh')
  map('q', function()
    require('notes').close()
  end, 'Close')
  map('<Esc>', function()
    require('notes').close()
  end, 'Close')
end

return M
