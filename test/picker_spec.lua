-- Headless picker tests for the two-pane (macOS Notes) model:
-- folder/notes scan, title-from-first-line, empty-note rules, folder filter,
-- create/move/rename/delete, and the delete-of-open-note placeholder fallback.
--
-- Run: nvim --headless -l test/picker_spec.lua

package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local api = vim.api
local fn = vim.fn

local failures = 0
local function check(name, ok, detail)
  if ok then
    io.write('  ok   - ' .. name .. '\n')
  else
    failures = failures + 1
    io.write('  FAIL - ' .. name .. (detail and ('  (' .. detail .. ')') or '') .. '\n')
  end
end

local function tmpdir()
  local d = fn.tempname()
  fn.mkdir(d, 'p')
  return d
end

local function writefile(path, lines)
  fn.mkdir(fn.fnamemodify(path, ':h'), 'p')
  fn.writefile(lines, path)
end

local notes = require('notes')
local picker = require('notes.picker')

local function fresh_open(dir)
  -- repo='' keeps open() fully synchronous (no git, no async pull)
  notes.state.synced = false
  notes.state.tab = nil
  notes.setup({ dir = dir, repo = '' })
  notes.open()
end

local function titles()
  local out = {}
  for _, it in ipairs(notes.state.items or {}) do
    out[#out + 1] = it.title
  end
  return out
end

local function all_titles()
  local out = {}
  for _, n in ipairs(notes.state.notes_all or {}) do
    out[#out + 1] = n.title
  end
  return out
end

local function folder_names()
  local out = {}
  for _, f in ipairs(notes.state.folders or {}) do
    out[#out + 1] = f.name
  end
  return out
end

local function contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

-- ── scan: folders, titles, empty pinned top ──────────────────────────────────
do
  io.write('scan + titles\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'alpha note', 'second line' })
  writefile(dir .. '/n2', { '', '  beta note' }) -- title = first non-blank line
  writefile(dir .. '/Work/n3', { 'gamma note' })
  writefile(dir .. '/blank', {}) -- empty note

  fresh_open(dir)

  check('root folder named "Notes"', notes.state.folders[1].name == 'Notes')
  check('folders include "Work"', contains(folder_names(), 'Work'))
  check('title from first line', contains(all_titles(), 'alpha note'))
  check('title skips blank lines', contains(all_titles(), 'beta note'))
  check('nested note scanned', contains(all_titles(), 'gamma note'))
  check('empty note titled "New Note"', contains(all_titles(), 'New Note'))
  -- root view ("Notes") shows only root notes, not the nested one
  check('root view excludes nested note', not contains(titles(), 'gamma note'))
  check('empty note pinned to top', notes.state.items[1].empty == true, notes.state.items[1].title)

  notes.close()
end

-- ── root view is root-only; folder filter narrows ────────────────────────────
do
  io.write('root view + folder filter\n')
  local dir = tmpdir()
  writefile(dir .. '/root_note', { 'at root' })
  writefile(dir .. '/Work/work_note', { 'in work' })

  fresh_open(dir)
  check('root view shows only root notes', #notes.state.items == 1 and notes.state.items[1].title == 'at root')

  notes.state.current_folder = 'Work'
  picker.filter()
  check('folder filter narrows to one', #notes.state.items == 1 and notes.state.items[1].title == 'in work')

  notes.close()
end

-- ── folders sorted by recency of their newest note ───────────────────────────
do
  io.write('folder recency sort\n')
  local dir = tmpdir()
  writefile(dir .. '/Old/o1', { 'old' })
  writefile(dir .. '/Fresh/f1', { 'fresh' })
  -- make Old stale, Fresh recent
  fn.system({ 'touch', '-t', '202001010000', dir .. '/Old/o1' })
  fn.system({ 'touch', dir .. '/Fresh/f1' })

  fresh_open(dir)
  local names = folder_names()
  check('root "Notes" first', names[1] == 'Notes')
  check('fresher folder before staler', names[2] == 'Fresh' and names[3] == 'Old', table.concat(names, ','))

  notes.close()
end

-- ── notes row format: "dd.mm.yyyy - title" ───────────────────────────────────
do
  io.write('row format\n')
  local dir = tmpdir()
  writefile(dir .. '/n', { 'hello' })

  fresh_open(dir)
  local row = api.nvim_buf_get_lines(notes.state.list_buf, 0, -1, false)[1]
  check('row uses " - " separator', row:match('^%d%d%.%d%d%.%d%d%d%d %- hello$') ~= nil, row)

  notes.close()
end

-- ── create_folder writes .gitkeep ────────────────────────────────────────────
do
  io.write('create folder\n')
  local dir = tmpdir()
  writefile(dir .. '/a', { 'a' })

  fresh_open(dir)
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Personal') end
  picker.create_folder()
  vim.ui.input = orig

  check('folder created on disk', fn.isdirectory(dir .. '/Personal') == 1)
  check('.gitkeep written', fn.filereadable(dir .. '/Personal/.gitkeep') == 1)
  check('folder appears in column', contains(folder_names(), 'Personal'))

  notes.close()
end

-- ── create_note: only one empty note per folder ──────────────────────────────
do
  io.write('create note dedupe\n')
  local dir = tmpdir()
  fresh_open(dir)

  notes.state.current_folder = nil -- "all" => create at root
  picker.create_note()
  local first = notes.state.current_file
  picker.populate()
  check('first note created', first ~= nil and fn.filereadable(first) == 1)

  picker.create_note() -- should reuse the empty note, not create a second
  check('second create reuses empty note', notes.state.current_file == first)
  local n = 0
  for name in vim.fs.dir(dir) do
    if name:sub(1, 1) ~= '.' then n = n + 1 end
  end
  check('only one file on disk', n == 1, 'count=' .. n)

  notes.close()
end

-- ── move note: cut + drop on a folder ────────────────────────────────────────
do
  io.write('move note\n')
  local dir = tmpdir()
  writefile(dir .. '/movable', { 'move me' })
  fn.mkdir(dir .. '/Target', 'p')
  fn.writefile({}, dir .. '/Target/.gitkeep')

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  local note = notes.state.items[1]
  picker.cut_note()
  check('cut marks the note', notes.state.cut == note.file)

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Target' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()

  check('note moved into folder', fn.filereadable(dir .. '/Target/movable') == 1)
  check('old path gone', fn.filereadable(dir .. '/movable') == 0)
  check('cut cleared', notes.state.cut == nil)

  notes.close()
end

-- ── rename folder (moves all its notes) ──────────────────────────────────────
do
  io.write('rename folder\n')
  local dir = tmpdir()
  writefile(dir .. '/Old/note', { 'content' })

  fresh_open(dir)
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Old' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('New') end
  picker.rename_folder()
  vim.ui.input = orig

  check('folder renamed on disk', fn.isdirectory(dir .. '/New') == 1 and fn.isdirectory(dir .. '/Old') == 0)
  check('note moved with folder', fn.filereadable(dir .. '/New/note') == 1)

  notes.close()
end

-- ── delete the open note → placeholder, no E211 ──────────────────────────────
do
  io.write('delete open note\n')
  local dir = tmpdir()
  writefile(dir .. '/only', { 'the only note' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  check('note is open in editor', notes.state.current_file == dir .. '/only')

  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_note()
  vim.fn.confirm = orig_confirm

  check('note removed from disk', fn.filereadable(dir .. '/only') == 0)
  check('current_file cleared', notes.state.current_file == nil)
  local edit_lines = api.nvim_buf_get_lines(notes.state.edit_buf, 0, -1, false)
  check(
    'editor shows placeholder',
    edit_lines[1] == 'Select a note or create a new one (a).',
    table.concat(edit_lines, '|')
  )
  check('editor buffer is scratch (no E211 backing file)', vim.bo[notes.state.edit_buf].buftype == 'nofile')
  check('notes column shows empty marker', api.nvim_buf_get_lines(notes.state.list_buf, 0, -1, false)[1] == '(no notes)')

  notes.close()
end

io.write('\n')
if failures > 0 then
  io.write(failures .. ' check(s) FAILED\n')
  vim.cmd('cquit 1')
else
  io.write('all picker checks passed\n')
  vim.cmd('quit')
end
