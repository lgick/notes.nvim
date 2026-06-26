-- Headless picker tests: recursive scan, substring filter, and the
-- delete/rename-of-open-file fallback to the placeholder buffer.
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

local function list_lines()
  return api.nvim_buf_get_lines(notes.state.list_buf, 0, -1, false)
end

local function contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

-- ── scan + filter ────────────────────────────────────────────────────────────
do
  io.write('scan + filter\n')
  local dir = tmpdir()
  writefile(dir .. '/a.txt', { 'alpha' })
  writefile(dir .. '/work/b.md', { 'beta' })
  writefile(dir .. '/work/deep/c.log', { 'gamma' })

  fresh_open(dir)
  local lines = list_lines()
  check('scan finds root file', contains(lines, 'a.txt'))
  check('scan recurses one level', contains(lines, 'work/b.md'))
  check('scan recurses deep / any extension', contains(lines, 'work/deep/c.log'))

  -- live filter via the input buffer
  api.nvim_buf_set_lines(notes.state.input_buf, 0, -1, false, { 'work/deep' })
  picker.filter('work/deep')
  picker.render_list()
  local f = list_lines()
  check('filter narrows to match', contains(f, 'work/deep/c.log') and #f == 1, table.concat(f, '|'))

  notes.close()
end

-- ── delete the open file → placeholder, no E211 ──────────────────────────────
do
  io.write('delete open file\n')
  local dir = tmpdir()
  writefile(dir .. '/only.txt', { 'the only note' })

  fresh_open(dir)
  -- select line 1 and open it in the editor
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  check('file is open in editor', notes.state.current_file == dir .. '/only.txt')

  -- force the delete confirm() to "Yes"
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete()
  vim.fn.confirm = orig_confirm

  check('file removed from disk', fn.filereadable(dir .. '/only.txt') == 0)
  check('current_file cleared', notes.state.current_file == nil)
  local edit_lines = api.nvim_buf_get_lines(notes.state.edit_buf, 0, -1, false)
  check(
    'editor shows placeholder',
    edit_lines[1] == 'Select a file above or create a new one (a).',
    table.concat(edit_lines, '|')
  )
  check('editor buffer is scratch (no E211 backing file)', vim.bo[notes.state.edit_buf].buftype == 'nofile')
  check('list shows (no matches)', list_lines()[1] == '(no matches)')

  notes.close()
end

-- ── deleting a non-open file leaves the editor alone ─────────────────────────
do
  io.write('delete non-open file keeps editor\n')
  local dir = tmpdir()
  writefile(dir .. '/open.txt', { 'open me' })
  writefile(dir .. '/other.txt', { 'delete me' })

  fresh_open(dir)
  -- open open.txt
  for i, l in ipairs(list_lines()) do
    if l == 'open.txt' then
      api.nvim_win_set_cursor(notes.state.list_win, { i, 0 })
      break
    end
  end
  picker.open_selected()
  check('open.txt open', notes.state.current_file == dir .. '/open.txt')

  -- select other.txt and delete it
  for i, l in ipairs(list_lines()) do
    if l == 'other.txt' then
      api.nvim_win_set_cursor(notes.state.list_win, { i, 0 })
      break
    end
  end
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete()
  vim.fn.confirm = orig_confirm

  check('other.txt deleted', fn.filereadable(dir .. '/other.txt') == 0)
  check('editor still on open.txt', notes.state.current_file == dir .. '/open.txt')

  notes.close()
end

-- ── rename the open file → editor follows, no stale buffer ───────────────────
do
  io.write('rename open file\n')
  local dir = tmpdir()
  writefile(dir .. '/foo.txt', { 'rename me' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  local old_buf = notes.state.edit_buf
  check('foo open', notes.state.current_file == dir .. '/foo.txt')

  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb) cb('bar.txt') end
  picker.rename()
  vim.ui.input = orig_input

  check('renamed on disk', fn.filereadable(dir .. '/bar.txt') == 1 and fn.filereadable(dir .. '/foo.txt') == 0)
  check('editor follows to new path', notes.state.current_file == dir .. '/bar.txt')
  check('stale old buffer wiped', not api.nvim_buf_is_valid(old_buf))

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
