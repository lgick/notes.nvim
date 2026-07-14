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

-- ── setup normalizes a trailing slash in config.dir ───────────────────────────
do
  io.write('setup normalizes trailing slash in dir\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/n1', { 'trailing slash note' })

  fresh_open(dir .. '/')

  check('config.dir has no trailing slash', notes.config.dir:sub(-1) ~= '/', notes.config.dir)
  check('root folder named "Notes"', notes.state.folders[1].name == 'Notes')
  check('folders include "Work"', contains(folder_names(), 'Work'))
  check(
    'nested note scanned with correct folder',
    (function()
      for _, n in ipairs(notes.state.notes_all or {}) do
        if n.title == 'trailing slash note' then
          return n.folder == 'Work'
        end
      end
      return false
    end)()
  )

  notes.close()
end

-- ── open_file key removed; change_folder ('o') untouched ─────────────────────
do
  io.write('open_file key removed from config\n')
  local dir = tmpdir()
  fresh_open(dir)

  check('config.keys.open_file is gone', notes.config.keys.open_file == nil)
  check('config.keys.change_folder is still "o"', notes.config.keys.change_folder == 'o')
  check('config.keys.select default is <CR>', notes.config.keys.select == '<CR>')

  local function has_cr_map(buf)
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == '<CR>' then
        return true
      end
    end
    return false
  end

  check('<CR> keymap present in folders_buf (select_folder)', has_cr_map(notes.state.folders_buf))
  check('<CR> keymap present in list_buf (select_note)', has_cr_map(notes.state.list_buf))

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

-- ── NotesTitle highlight covers the title text only (after the date prefix) ────
do
  io.write('title highlight\n')
  local dir = tmpdir()
  writefile(dir .. '/n', { 'hello' })

  fresh_open(dir)
  local ns_title = api.nvim_create_namespace('notes_title')
  local marks = api.nvim_buf_get_extmarks(notes.state.list_buf, ns_title, 0, -1, { details = true })
  check('one title mark rendered', #marks == 1, 'count=' .. #marks)
  -- prefix "dd.mm.yyyy - " is 13 bytes; the mark must start there, not at col 0
  check('title mark starts after date prefix', marks[1] and marks[1][3] == 13, marks[1] and marks[1][3])
  check('title mark uses NotesTitle', marks[1] and marks[1][4].hl_group == 'NotesTitle')

  notes.close()
end

-- ── conflict highlight: conflicted note row + its folder row get NotesConflict ─
do
  io.write('conflict highlight\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/c1', { 'conflicted note' })

  fresh_open(dir)
  -- find the note inside Work and mark it conflicted
  local cfile
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'Work' then
      cfile = n.file
    end
  end
  notes.state.conflicts = { [cfile] = true }
  notes.state.current_folder = 'Work'
  picker.filter()
  picker.render_notes()
  picker.render_folders()

  local ns_conflict = api.nvim_create_namespace('notes_conflict')
  local note_marks = api.nvim_buf_get_extmarks(notes.state.list_buf, ns_conflict, 0, -1, { details = true })
  check('note row highlighted', #note_marks == 1, 'count=' .. #note_marks)
  check('note row uses NotesConflict', note_marks[1] and note_marks[1][4].hl_group == 'NotesConflict')

  -- the Work folder row must be highlighted too
  local folder_row
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Work' then
      folder_row = i - 1
    end
  end
  local fmarks = api.nvim_buf_get_extmarks(notes.state.folders_buf, ns_conflict, 0, -1, { details = true })
  local found = false
  for _, m in ipairs(fmarks) do
    if m[2] == folder_row and m[4].hl_group == 'NotesConflict' then
      found = true
    end
  end
  check('conflicted folder row highlighted', found)

  notes.close()
end

-- ── conflicted notes/folders block destructive ops ───────────────────────────
do
  io.write('block ops on conflict\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/c1', { 'conflicted note' })
  fn.mkdir(dir .. '/Dest', 'p')
  fn.writefile({}, dir .. '/Dest/.gitkeep')

  fresh_open(dir)
  local cfile
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'Work' then
      cfile = n.file
    end
  end
  notes.state.conflicts = { [cfile] = true }
  notes.state.current_folder = 'Work'
  picker.filter()
  picker.render_notes()

  -- delete_note must refuse (would otherwise prompt confirm=Yes and delete)
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.delete_note()
  check('delete_note blocked', fn.filereadable(cfile) == 1)

  -- cut + paste must refuse
  picker.cut_note()
  check('cut_note blocked (nothing marked)', notes.state.cut == nil)
  notes.state.cut = cfile -- force a marked conflicted note
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Dest' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()
  check('paste_note blocked', fn.filereadable(cfile) == 1 and fn.filereadable(dir .. '/Dest/c1') == 0)
  notes.state.cut = nil

  -- rename_folder / delete_folder on the conflicted folder must refuse
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Work' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig_input
  check('rename_folder blocked', fn.isdirectory(dir .. '/Work') == 1 and fn.isdirectory(dir .. '/Renamed') == 0)

  picker.delete_folder()
  check('delete_folder blocked', fn.isdirectory(dir .. '/Work') == 1)
  vim.fn.confirm = orig_confirm

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

-- ── create_note moves the cursor onto the new note ───────────────────────────
do
  io.write('create moves cursor to new note\n')
  local dir = tmpdir()
  writefile(dir .. '/f/a', { 'aaa' })
  writefile(dir .. '/f/b', { 'bbb' })

  fresh_open(dir)
  notes.state.current_folder = 'f'
  picker.filter()
  picker.render_notes()
  -- cursor somewhere other than the top before creating
  api.nvim_win_set_cursor(notes.state.list_win, { 2, 0 })

  picker.create_note()

  -- the new empty note is pinned to the top (row 1); the cursor must land on it
  check('cursor moved to row 1', api.nvim_win_get_cursor(notes.state.list_win)[1] == 1,
    tostring(api.nvim_win_get_cursor(notes.state.list_win)[1]))
  check('row-1 note is the new active note', notes.state.current_file == notes.state.items[1].file)
  check('new note is empty', notes.state.items[1].empty == true)

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
  check('target folder selected', notes.state.current_folder == 'Target')
  check('drilled into target folder', notes.state.main_folder == 'Target')
  check(
    'notes column shows target folder note',
    #notes.state.items == 1 and notes.state.items[1].title == 'move me',
    table.concat(titles(), ',')
  )

  notes.close()
end

-- ── move note: editor statusline shows the real title, not "New Note" ─────────
do
  io.write('move note updates editor statusline\n')
  local dir = tmpdir()
  writefile(dir .. '/movable', { 'move me statusline' })
  fn.mkdir(dir .. '/Target', 'p')
  fn.writefile({}, dir .. '/Target/.gitkeep')

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  local note = notes.state.items[1]
  require('notes.ui').open_in_edit(note.file)
  picker.cut_note()

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Target' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()

  local statusline = vim.wo[notes.state.edit_win].statusline
  check(
    'statusline shows real title after move',
    statusline:find('move me statusline', 1, true) ~= nil,
    statusline
  )
  check('statusline does not fall back to New Note', not statusline:find('New Note', 1, true), statusline)

  notes.close()
end

-- ── move floats destination deterministically even on an mtime-second tie ─────
-- Repro of the "sometimes the destination folder is not first" bug: moving a note
-- out of a_src empties it, bumping a_src's *directory* mtime to now — the same
-- second as the moved note in z_dst. Without the note-bearing/name tie-break the
-- unstable table.sort could order a_src first. z_dst must always come first.
do
  io.write('move floats destination on mtime tie\n')
  local dir = tmpdir()
  writefile(dir .. '/a_src/note', { 'move me' })
  fn.mkdir(dir .. '/z_dst', 'p')
  fn.writefile({}, dir .. '/z_dst/.gitkeep')

  fresh_open(dir)
  notes.state.current_folder = 'a_src'
  picker.filter()
  picker.render_notes()
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'z_dst' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()

  -- force the exact collision: a_src dir mtime == z_dst note mtime (same second)
  fn.system({ 'touch', '-t', '202601011200', dir .. '/a_src' })
  fn.system({ 'touch', '-t', '202601011200', dir .. '/z_dst/note' })

  -- paste_note drills into the destination; go back to root to compare a_src/z_dst
  -- as siblings again
  notes.state.main_folder = nil
  notes.state.current_folder = nil

  -- re-scan multiple times: order must be stable and put the destination first
  for _ = 1, 5 do
    picker.populate()
    check(
      'destination z_dst is first real folder',
      notes.state.folders[2] and notes.state.folders[2].folder == 'z_dst',
      notes.state.folders[2] and notes.state.folders[2].folder
    )
  end

  notes.close()
end

-- ── cut keeps the cursor on the selected note (not reset to the top) ──────────
do
  io.write('cut keeps cursor on selected note\n')
  local dir = tmpdir()
  writefile(dir .. '/f/a', { 'aaa' })
  writefile(dir .. '/f/b', { 'bbb' })
  writefile(dir .. '/f/c', { 'ccc' })
  -- mtimes: c newest, b middle, a oldest → rows: c(1), b(2), a(3)
  fn.system({ 'touch', '-t', '202601010003', dir .. '/f/c' })
  fn.system({ 'touch', '-t', '202601010002', dir .. '/f/b' })
  fn.system({ 'touch', '-t', '202601010001', dir .. '/f/a' })

  fresh_open(dir)
  notes.state.current_folder = 'f'
  picker.filter()
  picker.render_notes()

  api.nvim_win_set_cursor(notes.state.list_win, { 2, 0 }) -- select row 2 (b)
  local want = notes.state.items[2]
  picker.cut_note()
  check('cursor stays on row 2 after cut', api.nvim_win_get_cursor(notes.state.list_win)[1] == 2,
    tostring(api.nvim_win_get_cursor(notes.state.list_win)[1]))
  check('marked note is the row-2 note', notes.state.cut == want.file)

  picker.cut_note() -- cancel on the same row
  check('cursor stays on row 2 after cancel', api.nvim_win_get_cursor(notes.state.list_win)[1] == 2)
  check('mark cleared', notes.state.cut == nil)

  notes.close()
end

-- ── background refresh keeps the cursor on the active note (not reset to top) ──
do
  io.write('refresh keeps cursor on active note\n')
  local dir = tmpdir()
  writefile(dir .. '/f/a', { 'aaa' })
  writefile(dir .. '/f/b', { 'bbb' })
  writefile(dir .. '/f/c', { 'ccc' })
  fn.system({ 'touch', '-t', '202601010003', dir .. '/f/c' })
  fn.system({ 'touch', '-t', '202601010002', dir .. '/f/b' })
  fn.system({ 'touch', '-t', '202601010001', dir .. '/f/a' })

  fresh_open(dir)
  notes.state.current_folder = 'f'
  picker.filter()
  picker.render_notes()

  -- open the note on row 2 (b), as auto-open would on cursor move
  api.nvim_win_set_cursor(notes.state.list_win, { 2, 0 })
  picker.open_selected()
  local active = notes.state.current_file
  check('note on row 2 is open', active == notes.state.items[2].file)

  -- a background sync would call refresh(); cursor must stay on the active note
  picker.refresh()
  check(
    'cursor stays on active note after refresh',
    api.nvim_win_get_cursor(notes.state.list_win)[1] == 2,
    tostring(api.nvim_win_get_cursor(notes.state.list_win)[1])
  )

  vim.bo[notes.state.edit_buf].modified = false
  notes.close()
end

-- ── cancel move: second `x` on the marked note clears the mark ────────────────
do
  io.write('cancel move (toggle x)\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  local note = notes.state.items[1]
  picker.cut_note()
  check('cut marks the note', notes.state.cut == note.file)
  picker.cut_note() -- second press on the same note cancels
  check('second x cancels move', notes.state.cut == nil)

  notes.close()
end

-- ── move a note with UNSAVED edits: no duplicate at old path, edits preserved ──
do
  io.write('move note with unsaved edits\n')
  local dir = tmpdir()
  writefile(dir .. '/movable', { 'move me' })
  fn.mkdir(dir .. '/Target', 'p')
  fn.writefile({}, dir .. '/Target/.gitkeep')

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  -- modify the open note without saving, then move it
  api.nvim_buf_set_lines(notes.state.edit_buf, 0, -1, false, { 'move me', 'UNSAVED EDIT' })
  picker.cut_note()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Target' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()

  check('no duplicate left at old path', fn.filereadable(dir .. '/movable') == 0)
  check('note present at new path', fn.filereadable(dir .. '/Target/movable') == 1)
  check(
    'unsaved edits persisted on move',
    table.concat(fn.readfile(dir .. '/Target/movable'), '|') == 'move me|UNSAVED EDIT'
  )
  local n = 0
  for name in vim.fs.dir(dir) do
    if name:sub(1, 1) ~= '.' and name ~= 'Target' then
      n = n + 1
    end
  end
  check('no stray note at root', n == 0, 'count=' .. n)

  vim.bo[notes.state.edit_buf].modified = false
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

-- ── title_of: unit tests ──────────────────────────────────────────────────────
do
  io.write('title_of\n')
  local dir = tmpdir()
  writefile(dir .. '/t1', { 'First line', 'second line' })
  writefile(dir .. '/t2', { '', '  ', 'actual title' })
  writefile(dir .. '/t3', {})

  local t1, e1 = picker.title_of(dir .. '/t1')
  local t2, e2 = picker.title_of(dir .. '/t2')
  local t3, e3 = picker.title_of(dir .. '/t3')
  local t4, e4 = picker.title_of(dir .. '/nonexistent')

  check('title from first line', t1 == 'First line' and e1 == false, t1)
  check('title skips blank lines', t2 == 'actual title' and e2 == false, t2)
  check('empty file → New Note', t3 == 'New Note' and e3 == true, t3)
  check('missing file → New Note', t4 == 'New Note' and e4 == true, t4)
end

-- ── update_live_title: in-memory update without disk read ─────────────────────
do
  io.write('update_live_title\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'original title' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  check('note open in editor', notes.state.current_file ~= nil)

  local buf = notes.state.edit_buf
  api.nvim_buf_set_lines(buf, 0, -1, false, { '', 'updated title', 'body' })
  picker.update_live_title(buf, notes.state.current_file)

  check('items title updated', notes.state.items[1].title == 'updated title', notes.state.items[1].title)
  local row = api.nvim_buf_get_lines(notes.state.list_buf, 0, -1, false)[1]
  check('rendered row shows updated title', row:find('updated title') ~= nil, row)
  check('empty flag cleared after update', notes.state.items[1].empty == false)

  -- reset modified flag so tabclose in notes.close() doesn't raise E37
  vim.bo[buf].modified = false
  notes.close()
end

-- ── create_note in a subfolder ────────────────────────────────────────────────
do
  io.write('create note in subfolder\n')
  local dir = tmpdir()
  fn.mkdir(dir .. '/Work', 'p')
  fn.writefile({}, dir .. '/Work/.gitkeep')

  fresh_open(dir)
  notes.state.current_folder = 'Work'
  picker.create_note()

  local f = notes.state.current_file
  check('note created', f ~= nil and fn.filereadable(f) == 1)
  check('note is inside Work/', f ~= nil and f:find('/Work/') ~= nil, tostring(f))

  notes.close()
end

-- ── move note to root (paste back to Notes) ───────────────────────────────────
do
  io.write('move note to root\n')
  local dir = tmpdir()
  writefile(dir .. '/Inbox/n1', { 'inbox note' })

  fresh_open(dir)
  notes.state.current_folder = 'Inbox'
  picker.filter()
  picker.render_notes()

  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  check('cut set', notes.state.cut ~= nil)

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- row 1 = Notes (root)
  picker.paste_note()

  check('note moved to root dir', fn.filereadable(dir .. '/n1') == 1, dir .. '/n1')
  check('old path gone', fn.filereadable(dir .. '/Inbox/n1') == 0)
  check('cut cleared', notes.state.cut == nil)

  notes.close()
end

-- ── delete folder resets current_folder ──────────────────────────────────────
do
  io.write('delete folder resets current_folder\n')
  local dir = tmpdir()
  writefile(dir .. '/Gone/n1', { 'orphan note' })

  fresh_open(dir)
  notes.state.current_folder = 'Gone'
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Gone' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
      break
    end
  end

  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('folder deleted from disk', fn.isdirectory(dir .. '/Gone') == 0)
  check('current_folder reset to nil', notes.state.current_folder == nil)
  check('root view is active after delete', notes.state.items ~= nil)

  notes.close()
end

-- ── paste_note no-op when nothing is cut ──────────────────────────────────────
do
  io.write('paste no-op without cut\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'test' })
  fn.mkdir(dir .. '/Dest', 'p')
  fn.writefile({}, dir .. '/Dest/.gitkeep')

  fresh_open(dir)
  notes.state.cut = nil

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Dest' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
      break
    end
  end
  picker.paste_note()

  check('note not moved (no cut)', fn.filereadable(dir .. '/note') == 1)
  check('dest folder still empty', fn.filereadable(dir .. '/Dest/note') == 0)

  notes.close()
end

-- ── close_interactive Discard reloads from disk (no lingering edits) ──────────
do
  io.write('discard reloads from disk\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'saved content' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  local buf = notes.state.edit_buf
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved edit' }) -- modify without saving
  check('buffer marked modified', vim.bo[buf].modified == true)

  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 2 end -- Discard
  notes.close_interactive()
  vim.fn.confirm = orig_confirm

  check('disk content untouched', table.concat(fn.readfile(dir .. '/note'), '') == 'saved content')

  -- reopen: the discarded edit must not reappear from a lingering hidden buffer
  notes.state.tab = nil
  notes.open()
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  local buf2 = notes.state.edit_buf
  local content = table.concat(api.nvim_buf_get_lines(buf2, 0, -1, false), '')
  check('reopened note shows saved content', content == 'saved content', content)
  check('reopened buffer not modified', vim.bo[buf2].modified == false)

  notes.close()
end

-- ── close_interactive: Save writes the buffer and closes ──────────────────────
do
  io.write('close_interactive Save writes and closes\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'saved content' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  local buf = notes.state.edit_buf
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'edited then saved' })
  check('buffer marked modified', vim.bo[buf].modified == true)

  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end -- Save
  notes.close_interactive()
  vim.fn.confirm = orig_confirm

  check('notes closed after Save', not notes.is_open())
  check(
    'disk content updated',
    table.concat(fn.readfile(dir .. '/note'), '') == 'edited then saved'
  )
end

-- ── close_interactive: Cancel leaves notes open and the buffer untouched ──────
do
  io.write('close_interactive Cancel keeps notes open\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'saved content' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  local buf = notes.state.edit_buf
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved edit' })

  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 3 end -- Cancel
  notes.close_interactive()
  vim.fn.confirm = orig_confirm

  check('notes still open after Cancel', notes.is_open())
  check('buffer still modified (edit not discarded)', vim.bo[buf].modified == true)
  check('disk content untouched', table.concat(fn.readfile(dir .. '/note'), '') == 'saved content')

  vim.bo[buf].modified = false
  notes.close()
end

-- ── paste_note no-op when the note is dropped into its current folder ─────────
do
  io.write('paste note into its own current folder is a no-op\n')
  local dir = tmpdir()
  writefile(dir .. '/root note', { 'root note' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  check('note marked', notes.state.cut ~= nil)

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- row 1 = Notes (root, its current folder)
  picker.paste_note()

  check('cut cleared', notes.state.cut == nil)
  check('note stays at the same path', fn.filereadable(dir .. '/root note') == 1)

  notes.close()
end

-- ── paste_folder no-op when dropped onto its own current parent ───────────────
do
  io.write('paste folder into its own current parent is a no-op\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('A marked', notes.state.cut_folder == 'A')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- row 1 = Notes (root, A's current parent)
  picker.paste_note() -- dispatches to paste_folder

  check('cut_folder cleared', notes.state.cut_folder == nil)
  check('folder stays at the same path', fn.isdirectory(dir .. '/A') == 1)
  check('note stays with it', fn.filereadable(dir .. '/A/note') == 1)

  notes.close()
end

-- ── notes.toggle(): open when closed, close_interactive when open ─────────────
do
  io.write('notes.toggle round-trip\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  notes.state.synced = false
  notes.state.tab = nil
  notes.setup({ dir = dir, repo = '' })
  check('starts closed', not notes.is_open())

  notes.toggle()
  check('toggle opens when closed', notes.is_open())

  notes.toggle()
  check('toggle closes when open (no unsaved changes, no prompt)', not notes.is_open())
end

-- ── notes.is_open(): self-heals after an external :tabclose ───────────────────
do
  io.write('is_open self-heals after external tabclose\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local tab = notes.state.tab
  check('tab open before external close', api.nvim_tabpage_is_valid(tab))

  -- emulate the user closing the tab directly (e.g. :tabclose), bypassing notes.close()
  vim.cmd('tabclose ' .. api.nvim_tabpage_get_number(tab))

  check('is_open reports false after external close', not notes.is_open())
  check('state.tab wiped', notes.state.tab == nil)
  check('state.folders_win wiped', notes.state.folders_win == nil)
  check('state.list_win wiped', notes.state.list_win == nil)
  check('state.edit_win wiped', notes.state.edit_win == nil)
  check('state.current_file wiped', notes.state.current_file == nil)
end

-- ── setup(): partial config.keys override keeps unspecified defaults ──────────
do
  io.write('setup partial keys override keeps defaults\n')
  local dir = tmpdir()

  notes.state.synced = false
  notes.state.tab = nil
  notes.setup({ dir = dir, repo = '', keys = { create = 'c' } })

  check('overridden key applied', notes.config.keys.create == 'c')
  check('unspecified key keeps default (delete)', notes.config.keys.delete == 'd')
  check('unspecified key keeps default (paste)', notes.config.keys.paste == 'p')
  check('unspecified key keeps default (window_nav)', notes.config.keys.window_nav == '<C-w>')
end

-- ── revisiting a note does not stack duplicate live-title autocmds ────────────
do
  io.write('live-title autocmd dedupe\n')
  local dir = tmpdir()
  writefile(dir .. '/a', { 'note A' })
  writefile(dir .. '/b', { 'note B' })

  fresh_open(dir)
  local ui = require('notes.ui')
  for _ = 1, 4 do
    ui.open_in_edit(dir .. '/a')
    ui.open_in_edit(dir .. '/b')
  end
  ui.open_in_edit(dir .. '/a')

  local cmds = api.nvim_get_autocmds({
    event = { 'TextChanged', 'TextChangedI' },
    buffer = notes.state.edit_buf,
  })
  check('exactly one handler per event after revisits', #cmds == 2, 'count=' .. #cmds)

  notes.close()
end

-- ── git.conflict_label: folder/title format ──────────────────────────────────
do
  io.write('conflict_label\n')
  local dir = tmpdir()
  notes.setup({ dir = dir })
  local git = require('notes.git')

  local root_note = dir .. '/20260101000000.md'
  fn.writefile({ '# My Title', 'body text' }, root_note)
  check('root note: Notes/title', git.conflict_label(root_note) == 'Notes/# My Title')

  fn.mkdir(dir .. '/work', 'p')
  local sub_note = dir .. '/work/20260102000000.md'
  fn.writefile({ 'Task note', 'details' }, sub_note)
  check('subfolder note: work/title', git.conflict_label(sub_note) == 'work/Task note')

  -- first real line after conflict markers
  fn.writefile({ '<<<<<<< HEAD', 'local version', '=======', 'remote', '>>>>>>> abc' }, root_note)
  check('markers: skips to first real line', git.conflict_label(root_note) == 'Notes/local version')

  -- all markers, no real content → falls back to filename
  fn.writefile({ '<<<<<<< HEAD', '=======', '>>>>>>> abc' }, root_note)
  check('all markers: falls back to filename', git.conflict_label(root_note) == 'Notes/20260101000000.md')

  -- empty file → falls back to filename
  fn.writefile({}, root_note)
  check('empty file: falls back to filename', git.conflict_label(root_note) == 'Notes/20260101000000.md')
end

-- ── git.repo_url: ssh/scp/https → browsable https URL ─────────────────────────
do
  io.write('repo_url conversion\n')
  local git = require('notes.git')
  check(
    'scp-style git@host:user/repo.git',
    git.repo_url('git@github.com:lgick/notes.git') == 'https://github.com/lgick/notes'
  )
  check(
    'ssh://git@host/user/repo.git',
    git.repo_url('ssh://git@github.com/lgick/notes.git') == 'https://github.com/lgick/notes'
  )
  check(
    'https://host/user/repo.git',
    git.repo_url('https://github.com/lgick/notes.git') == 'https://github.com/lgick/notes'
  )
end

-- ── set_sync_status: tab title reflects sync state and config ─────────────────
do
  io.write('set_sync_status\n')
  local dir = tmpdir()
  local ui = require('notes.ui')

  -- Open without repo (synchronous, no git), then patch config to test icons.
  -- In headless mode nvim-web-devicons is not loaded → plain Unicode fallback.
  notes.state.tab = nil
  notes.state.synced = false
  notes.setup({ dir = dir, repo = '' })
  notes.open()

  notes.config.repo = 'git@github.com:user/notes.git'
  notes.config.sync_icons = nil

  ui.set_sync_status('syncing')
  local ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  -- ⠋ = U+280B = \xe2\xa0\x8b (first braille spinner frame)
  check('syncing icon is spinner frame', ok and t == 'notes.nvim \xe2\xa0\x8b', ok and t or '')

  ui.set_sync_status('idle')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  -- ✓ = U+2713 = \xe2\x9c\x93
  check('idle icon is checkmark', ok and t == 'notes.nvim \xe2\x9c\x93', ok and t or '')

  ui.set_sync_status('conflict')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  -- plain fallback = '!'
  check('conflict icon is !', ok and t == 'notes.nvim !', ok and t or '')

  -- no repo → no icon
  notes.config.repo = ''
  ui.set_sync_status('idle')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  check('no repo → label without icon', ok and t == 'notes.nvim', ok and t or '')

  -- custom icons override auto-detect
  notes.config.repo = 'git@github.com:user/notes.git'
  notes.config.sync_icons = { idle = 'OK', syncing = '...', conflict = '!!' }

  ui.set_sync_status('idle')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  check('custom idle icon', ok and t == 'notes.nvim OK', ok and t or '')

  ui.set_sync_status('syncing')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  check('custom syncing icon', ok and t == 'notes.nvim ...', ok and t or '')

  ui.set_sync_status('conflict')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  check('custom conflict icon', ok and t == 'notes.nvim !!', ok and t or '')

  -- invalid status → label unchanged (no crash)
  notes.config.sync_icons = nil
  ui.set_sync_status('unknown_status')
  ok, t = pcall(api.nvim_tabpage_get_var, notes.state.tab, 'title')
  check('unknown status: no crash', ok)

  notes.config.repo = ''
  notes.close()
end

-- ── toggle_panels: hide and restore Folders + Notes columns ───────────────────
do
  io.write('toggle_panels\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })
  writefile(dir .. '/Work/n2', { 'note two' })

  fresh_open(dir)
  local ui = require('notes.ui')

  -- initial state: panels visible
  check('initial: panels_hidden false', notes.state.panels_hidden == false)
  check('initial: folders_win valid',
    notes.state.folders_win ~= nil and api.nvim_win_is_valid(notes.state.folders_win))
  check('initial: list_win valid',
    notes.state.list_win ~= nil and api.nvim_win_is_valid(notes.state.list_win))

  -- hide panels
  ui.toggle_panels()
  check('hidden: panels_hidden true', notes.state.panels_hidden == true)
  check('hidden: folders_win nil', notes.state.folders_win == nil)
  check('hidden: list_win nil', notes.state.list_win == nil)
  check('hidden: edit_win still valid',
    notes.state.edit_win ~= nil and api.nvim_win_is_valid(notes.state.edit_win))
  check('hidden: plugin still open', notes.is_open())

  -- show panels again
  ui.toggle_panels()
  check('shown: panels_hidden false', notes.state.panels_hidden == false)
  check('shown: folders_win valid',
    notes.state.folders_win ~= nil and api.nvim_win_is_valid(notes.state.folders_win))
  check('shown: list_win valid',
    notes.state.list_win ~= nil and api.nvim_win_is_valid(notes.state.list_win))

  -- panels are populated after restore
  local lines = api.nvim_buf_get_lines(notes.state.list_buf, 0, -1, false)
  check('shown: notes column populated',
    #lines > 0 and lines[1] ~= '(no notes)',
    (#lines > 0 and lines[1]) or 'empty')

  local flines = api.nvim_buf_get_lines(notes.state.folders_buf, 0, -1, false)
  check('shown: folders column populated', #flines > 0, tostring(#flines))

  -- CursorMoved still works: moving in the notes column opens the note
  api.nvim_set_current_win(notes.state.list_win)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.open_selected()
  check('cursor-move opens note after restore', notes.state.current_file ~= nil)

  if notes.state.edit_buf and api.nvim_buf_is_valid(notes.state.edit_buf) then
    vim.bo[notes.state.edit_buf].modified = false
  end
  notes.close()
end

-- ── toggle_panels: closing works correctly while panels are hidden ─────────────
do
  io.write('close with hidden panels\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local ui = require('notes.ui')

  ui.toggle_panels()
  check('panels hidden before close', notes.state.panels_hidden == true)

  local ok = pcall(notes.close)
  check('close does not error', ok)
  check('plugin closed', not notes.is_open())
end

-- ── recursive scan: notes at arbitrary depth get full relative folder path ────
do
  io.write('recursive scan\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  local found
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'deep note' then
      found = n
    end
  end
  check('note folder is full relative path', found and found.folder == 'A/B', found and found.folder)

  notes.close()
end

-- ── drill-down: root shows only top-level children, not grandchildren ─────────
do
  io.write('build_folders drill-down\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  check('root main row is Notes', notes.state.folders[1].is_main and notes.state.folders[1].folder == nil)
  check(
    'root shows only A, not B',
    #notes.state.folders == 2 and notes.state.folders[2].folder == 'A',
    folder_names()[2]
  )

  notes.state.main_folder = 'A'
  notes.state.current_folder = 'A'
  picker.build_folders()
  check('drilled main row is A', notes.state.folders[1].is_main and notes.state.folders[1].folder == 'A')
  check(
    'A shows only its own child B',
    #notes.state.folders == 2 and notes.state.folders[2].folder == 'A/B',
    notes.state.folders[2] and notes.state.folders[2].folder
  )

  notes.close()
end

-- ── recursive note count badge on child folder rows ────────────────────────────
do
  io.write('folder note count badge\n')
  local dir = tmpdir()
  writefile(dir .. '/A/n1', { 'a one' })
  writefile(dir .. '/A/n2', { 'a two' })
  writefile(dir .. '/A/B/n3', { 'a b three' })
  writefile(dir .. '/A/empty', {}) -- empty note, must still count
  fn.mkdir(dir .. '/C', 'p')
  fn.writefile({}, dir .. '/C/.gitkeep') -- empty folder, no notes

  fresh_open(dir)

  local a_row, c_row
  for _, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      a_row = f
    elseif f.folder == 'C' then
      c_row = f
    end
  end
  check('A count is recursive incl. empty note', a_row and a_row.count == 4, a_row and a_row.count)
  check('C (no notes) count is 0', c_row and c_row.count == 0, c_row and c_row.count)
  check('main row has no count field', notes.state.folders[1].count == nil)

  picker.render_folders()
  local flines = api.nvim_buf_get_lines(notes.state.folders_buf, 0, -1, false)
  local a_line
  for _, l in ipairs(flines) do
    if l:find('A%[') then
      a_line = l
    end
  end
  check('rendered child row shows "A[4]/"', a_line ~= nil and a_line:find('A%[4%]/') ~= nil, a_line)

  notes.close()
end

-- ── deep path on the main row is truncated from the left, not the right ───────
do
  io.write('main row left-truncation at narrow width\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/Projects/Q3/Reports/note', { 'deep note' })

  notes.state.synced = false
  notes.state.tab = nil
  notes.setup({ dir = dir, repo = '', folders_width = 20 })
  notes.open()

  notes.state.main_folder = 'Work/Projects/Q3/Reports'
  notes.state.current_folder = 'Work/Projects/Q3/Reports'
  picker.populate()

  local line = api.nvim_buf_get_lines(notes.state.folders_buf, 0, 1, false)[1]
  check('main row starts with ellipsis', line:sub(1, 3) == '\226\128\166', line)
  check('main row ends with the up hint', line:sub(-4) == '/ ..', line)
  check('current folder name is fully visible', line:find('Reports', 1, true) ~= nil, line)
  check('main row fits within the folders column width', fn.strdisplaywidth(line) <= 20, line)

  notes.close()
end

-- ── change_folder: drill in / go up via `o` ────────────────────────────────────
do
  io.write('change_folder navigation\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A
  picker.change_folder()
  check('drilled into A', notes.state.main_folder == 'A' and notes.state.current_folder == 'A')
  check('cursor reset to row 1', api.nvim_win_get_cursor(notes.state.folders_win)[1] == 1)
  check(
    'B is now a child row',
    notes.state.folders[2] and notes.state.folders[2].folder == 'A/B',
    notes.state.folders[2] and notes.state.folders[2].folder
  )

  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A/B
  picker.change_folder()
  check('drilled into A/B', notes.state.main_folder == 'A/B')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A/B
  picker.change_folder()
  check('went up to A', notes.state.main_folder == 'A' and notes.state.current_folder == 'A')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A
  picker.change_folder()
  check('went up to root', notes.state.main_folder == nil and notes.state.current_folder == nil)

  picker.change_folder() -- cursor already on row 1 (true root main row)
  check('no-op at true root', notes.state.main_folder == nil)

  notes.close()
end

-- ── select_folder / select_note: `<CR>` forward navigation ────────────────────
do
  io.write('select_folder / select_note\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)

  -- child row → drill in AND move focus to the notes column
  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A
  picker.select_folder()
  check(
    'select_folder on child drilled into A',
    notes.state.main_folder == 'A' and notes.state.current_folder == 'A'
  )
  check(
    'select_folder on child moved focus to list_win',
    api.nvim_get_current_win() == notes.state.list_win
  )

  -- main row → level unchanged, focus moves to notes column
  api.nvim_set_current_win(notes.state.folders_win)
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A
  picker.select_folder()
  check('select_folder on main row keeps level', notes.state.main_folder == 'A')
  check(
    'select_folder on main row moved focus to list_win',
    api.nvim_get_current_win() == notes.state.list_win
  )

  -- notes column → open note under cursor and move focus to the editor
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  local it = notes.state.items[1]
  picker.select_note()
  check('select_note opened the note under cursor', notes.state.current_file == it.file)
  check(
    'select_note moved focus to edit_win',
    api.nvim_get_current_win() == notes.state.edit_win
  )

  notes.close()
end

-- ── recursive freshness: a note in a grandchild bumps its ancestor folder ─────
do
  io.write('recursive folder freshness\n')
  local dir = tmpdir()
  writefile(dir .. '/Old/o1', { 'old' })
  writefile(dir .. '/Fresh/Sub/f1', { 'fresh, deeply nested' })
  fn.system({ 'touch', '-t', '202001010000', dir .. '/Old/o1' })
  fn.system({ 'touch', dir .. '/Fresh/Sub/f1' })

  fresh_open(dir)
  local names = folder_names()
  check(
    'Fresh (via nested note) sorts before Old',
    names[2] == 'Fresh' and names[3] == 'Old',
    table.concat(names, ',')
  )

  notes.close()
end

-- ── create_folder creates inside the current drill-down level ─────────────────
do
  io.write('create folder inside current level\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  notes.state.main_folder = 'A'
  notes.state.current_folder = 'A'
  picker.build_folders()

  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Sub') end
  picker.create_folder()
  vim.ui.input = orig

  check('subfolder created on disk', fn.isdirectory(dir .. '/A/Sub') == 1)
  check('.gitkeep written', fn.filereadable(dir .. '/A/Sub/.gitkeep') == 1)

  notes.close()
end

-- ── rename a nested folder rewrites current_folder/main_folder prefixes ───────
do
  io.write('rename nested folder rewrites prefixes\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  notes.state.main_folder = 'A/B'
  notes.state.current_folder = 'A/B'
  picker.build_folders()
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A/B itself

  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig

  check('folder renamed on disk', fn.isdirectory(dir .. '/A/Renamed') == 1 and fn.isdirectory(dir .. '/A/B') == 0)
  check('note moved with folder', fn.filereadable(dir .. '/A/Renamed/note') == 1)
  check('main_folder prefix rewritten', notes.state.main_folder == 'A/Renamed', notes.state.main_folder)
  check('current_folder prefix rewritten', notes.state.current_folder == 'A/Renamed', notes.state.current_folder)

  notes.close()
end

-- ── delete a nested folder: current_folder/main_folder fall back correctly ────
do
  io.write('delete nested folder navigation fallback\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  notes.state.main_folder = 'A'
  notes.state.current_folder = 'A/B'
  picker.build_folders()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A/B' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end

  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('B deleted from disk', fn.isdirectory(dir .. '/A/B') == 0)
  check('main_folder unaffected (A still exists)', notes.state.main_folder == 'A')
  check('current_folder falls back to main_folder', notes.state.current_folder == 'A')

  notes.close()
end

-- ── deleting the drilled-into folder itself goes up to its parent ─────────────
do
  io.write('delete main-row folder goes up\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  notes.state.main_folder = 'A/B'
  notes.state.current_folder = 'A/B'
  picker.build_folders()
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row itself (A/B)

  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('A/B deleted from disk', fn.isdirectory(dir .. '/A/B') == 0)
  check('main_folder goes up to A', notes.state.main_folder == 'A', notes.state.main_folder)
  check('current_folder goes up to A', notes.state.current_folder == 'A', notes.state.current_folder)

  notes.close()
end

-- ── recursive conflict highlight: a deeply nested conflict highlights ancestors ─
do
  io.write('recursive conflict highlight\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/c1', { 'conflicted deep note' })

  fresh_open(dir)
  local cfile
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'A/B' then
      cfile = n.file
    end
  end
  notes.state.conflicts = { [cfile] = true }
  picker.populate() -- root level: ancestor A must show as conflicted

  local ns_conflict = api.nvim_create_namespace('notes_conflict')
  local a_row
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      a_row = i - 1
    end
  end
  local fmarks = api.nvim_buf_get_extmarks(notes.state.folders_buf, ns_conflict, 0, -1, { details = true })
  local found = false
  for _, m in ipairs(fmarks) do
    if m[2] == a_row and m[4].hl_group == 'NotesConflict' then
      found = true
    end
  end
  check('ancestor folder A highlighted for a deeply nested conflict', found)

  notes.close()
end

-- ── validate_folder: disk-missing current_folder falls back to main_folder ────
do
  io.write('validate_folder disk check\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  notes.state.main_folder = nil
  notes.state.current_folder = 'Ghost' -- never existed on disk
  picker.populate()
  check('current_folder reset (never existed on disk)', notes.state.current_folder == nil)

  notes.close()
end

-- ── cut highlight outranks the base folder-row highlight ───────────────────────
do
  io.write('cut_folder highlight outranks base NotesDir\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  local a_row
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      a_row = i
    end
  end
  api.nvim_win_set_cursor(notes.state.folders_win, { a_row, 0 })
  picker.cut_folder() -- A is now marked for moving

  local ns_cut = api.nvim_create_namespace('notes_list')
  local marks = api.nvim_buf_get_extmarks(
    notes.state.folders_buf,
    ns_cut,
    0,
    -1,
    { details = true }
  )
  local cut_priority
  for _, m in ipairs(marks) do
    if m[2] == a_row - 1 and m[4].hl_group == 'NotesCut' then
      cut_priority = m[4].priority
    end
  end
  check('NotesCut extmark present on the marked row', cut_priority ~= nil)

  local ns_folders = api.nvim_create_namespace('notes_folders')
  local dir_marks = api.nvim_buf_get_extmarks(
    notes.state.folders_buf,
    ns_folders,
    0,
    -1,
    { details = true }
  )
  local dir_priority
  for _, m in ipairs(dir_marks) do
    if m[2] == a_row - 1 then
      dir_priority = m[4].priority
    end
  end
  check(
    'NotesCut outranks the base NotesDir highlight',
    cut_priority ~= nil and dir_priority ~= nil and cut_priority > dir_priority,
    'cut=' .. tostring(cut_priority) .. ' dir=' .. tostring(dir_priority)
  )

  notes.close()
end

-- ── cut_folder: mark/cancel, true root refused ─────────────────────────────────
do
  io.write('cut_folder mark/cancel\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- true root
  picker.cut_folder()
  check('true root cannot be marked', notes.state.cut_folder == nil)

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('folder A marked', notes.state.cut_folder == 'A')
  picker.cut_folder() -- second press cancels
  check('second x cancels', notes.state.cut_folder == nil)

  notes.close()
end

-- ── cut_folder: the main row (drilled-into folder) cannot be marked either ─────
do
  io.write('cut_folder refuses the main row from inside it\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'a note' })

  fresh_open(dir)
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.change_folder() -- drill into A; row 1 is now the main row for A itself
  check('drilled into A', notes.state.main_folder == 'A')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A
  picker.cut_folder()
  check('main row (A itself) cannot be marked from inside it', notes.state.cut_folder == nil)

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A/B' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('child row B can still be marked', notes.state.cut_folder == 'A/B')

  notes.close()
end

-- ── cut_folder / cut_note are mutually exclusive ───────────────────────────────
do
  io.write('cut_folder clears cut_note and vice versa\n')
  local dir = tmpdir()
  writefile(dir .. '/root note', { 'root note' })
  writefile(dir .. '/A/note', { 'a note' })

  local ns_cut = api.nvim_create_namespace('notes_list')
  local function has_cut_mark(buf)
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_cut, 0, -1, { details = true })) do
      if m[4].hl_group == 'NotesCut' then
        return true
      end
    end
    return false
  end

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  check('note marked', notes.state.cut ~= nil)
  check('note cut mark drawn', has_cut_mark(notes.state.list_buf))

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('marking a folder clears the marked note', notes.state.cut == nil)
  check('folder marked', notes.state.cut_folder == 'A')
  check('stale note cut mark is gone', not has_cut_mark(notes.state.list_buf))
  check('folder cut mark drawn', has_cut_mark(notes.state.folders_buf))

  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  check('marking a note clears the marked folder', notes.state.cut_folder == nil)
  check('stale folder cut mark is gone', not has_cut_mark(notes.state.folders_buf))

  notes.close()
end

-- ── paste_folder: moves a nested folder to a sibling, notes travel with it ─────
do
  io.write('paste_folder moves nested folder to sibling\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'note in B' })
  fn.mkdir(dir .. '/C', 'p')
  fn.writefile({}, dir .. '/C/.gitkeep')

  fresh_open(dir)
  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A
  picker.change_folder() -- drill into A
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A/B' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('B marked', notes.state.cut_folder == 'A/B')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A
  picker.change_folder() -- go up to root
  check('back at root', notes.state.main_folder == nil)

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'C' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note() -- bound key dispatches to paste_folder when a folder is cut

  check(
    'B moved on disk',
    fn.isdirectory(dir .. '/A/B') == 0 and fn.isdirectory(dir .. '/C/B') == 1
  )
  check('note travelled with the folder', fn.filereadable(dir .. '/C/B/note') == 1)
  check('cut_folder cleared', notes.state.cut_folder == nil)
  check(
    'drilled into destination C',
    notes.state.main_folder == 'C' and notes.state.current_folder == 'C'
  )
  check(
    'cursor lands on the moved folder row',
    (function()
      local row = api.nvim_win_get_cursor(notes.state.folders_win)[1]
      return notes.state.folders[row] and notes.state.folders[row].folder == 'C/B'
    end)()
  )

  notes.close()
end

-- ── paste_folder: cannot move a folder into its own descendant ─────────────────
do
  io.write('paste_folder blocks moving into own subtree\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'note in B' })

  fresh_open(dir)
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A (only child at root)
  picker.change_folder() -- drill into A; row 1 = A, row 2 = B
  api.nvim_win_set_cursor(notes.state.folders_win, { 2, 0 }) -- A/B, a descendant of A
  picker.paste_note()
  check('A stays on disk (not moved into its own child)', fn.isdirectory(dir .. '/A') == 1)
  check('B untouched', fn.isdirectory(dir .. '/A/B') == 1)
  check('cut_folder still marked (paste refused, not consumed)', notes.state.cut_folder == 'A')

  notes.close()
end

-- ── paste_folder: destination already has a folder with the same name ──────────
do
  io.write('paste_folder blocks name collision at destination\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })
  writefile(dir .. '/C/A/other', { 'other note' })

  fresh_open(dir)
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'C' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()
  check('source A untouched', fn.isdirectory(dir .. '/A') == 1)
  check('destination A/A untouched', fn.filereadable(dir .. '/C/A/other') == 1)

  notes.close()
end

-- ── conflicted folder blocks cut_folder / paste_folder ──────────────────────────
do
  io.write('block folder move on conflict\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/c1', { 'conflicted note' })
  fn.mkdir(dir .. '/Dest', 'p')
  fn.writefile({}, dir .. '/Dest/.gitkeep')

  fresh_open(dir)
  local cfile
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'Work' then
      cfile = n.file
    end
  end
  notes.state.conflicts = { [cfile] = true }
  picker.populate()

  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Work' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('cut_folder blocked on conflict', notes.state.cut_folder == nil)

  notes.state.cut_folder = 'Work' -- force a marked conflicted folder
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Dest' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()
  check(
    'paste_folder blocked on conflict',
    fn.isdirectory(dir .. '/Work') == 1 and fn.isdirectory(dir .. '/Dest/Work') == 0
  )

  notes.close()
end

-- ── rename_folder rewrites a marked note's absolute st.cut path ────────────────
do
  io.write('rename_folder rewrites st.cut\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  notes.state.current_folder = 'A/B'
  picker.filter()
  picker.render_notes()
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  local note = notes.state.items[1]
  picker.cut_note()
  check('note marked', notes.state.cut == note.file)

  notes.state.main_folder = 'A/B'
  picker.build_folders()
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A/B itself

  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig

  local expected = dir .. '/A/Renamed/note'
  check('st.cut rewritten to the new path', notes.state.cut == expected, notes.state.cut)
  check('the rewritten path exists on disk', fn.filereadable(notes.state.cut) == 1)

  notes.state.main_folder = nil
  picker.build_folders()
  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = root
  picker.paste_note()
  check('paste after rename succeeds', fn.filereadable(dir .. '/note') == 1)

  notes.close()
end

-- ── rename_folder rewrites a marked folder's st.cut_folder path ────────────────
do
  io.write('rename_folder rewrites st.cut_folder\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/C/note', { 'deep note' })

  fresh_open(dir)
  notes.state.main_folder = 'A/B'
  notes.state.current_folder = 'A/B'
  picker.build_folders()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A/B/C' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('C marked', notes.state.cut_folder == 'A/B/C')

  api.nvim_win_set_cursor(notes.state.folders_win, { 1, 0 }) -- main row = A/B itself
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig

  check(
    'st.cut_folder prefix rewritten',
    notes.state.cut_folder == 'A/Renamed/C',
    notes.state.cut_folder
  )

  notes.close()
end

-- ── delete_folder clears a marked note's st.cut when it was inside the subtree ─
do
  io.write('delete_folder clears st.cut\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })
  writefile(dir .. '/root note', { 'root note' })

  fresh_open(dir)
  notes.state.current_folder = 'A/B'
  picker.filter()
  picker.render_notes()
  api.nvim_win_set_cursor(notes.state.list_win, { 1, 0 })
  picker.cut_note()
  check('note marked', notes.state.cut ~= nil)

  notes.state.main_folder = nil
  picker.build_folders()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('A deleted from disk', fn.isdirectory(dir .. '/A') == 0)
  check('st.cut cleared after ancestor deleted', notes.state.cut == nil)

  -- paste must be a no-op (nothing marked), not an error
  for i, f in ipairs(notes.state.folders) do
    if f.folder == nil then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.paste_note()
  check('paste after stale cut is a safe no-op', fn.filereadable(dir .. '/root note') == 1)

  notes.close()
end

-- ── delete_folder clears a marked folder's st.cut_folder when inside the subtree ─
do
  io.write('delete_folder clears st.cut_folder\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/C/note', { 'deep note' })

  fresh_open(dir)
  notes.state.main_folder = 'A/B'
  notes.state.current_folder = 'A/B'
  picker.build_folders()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A/B/C' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  picker.cut_folder()
  check('C marked', notes.state.cut_folder == 'A/B/C')

  notes.state.main_folder = nil
  picker.build_folders()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'A' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('A deleted from disk', fn.isdirectory(dir .. '/A') == 0)
  check('st.cut_folder cleared after ancestor deleted', notes.state.cut_folder == nil)

  notes.close()
end

-- ── folder names reject backslash too (Windows path separator) ─────────────────
do
  io.write('folder name rejects backslash\n')
  local dir = tmpdir()

  fresh_open(dir)
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('A\\B') end
  picker.create_folder()
  vim.ui.input = orig
  check('create_folder rejects backslash', fn.isdirectory(dir .. '/A') == 0 and fn.isdirectory(dir .. '/A/B') == 0)

  writefile(dir .. '/Existing/note', { 'a note' })
  picker.populate()
  for i, f in ipairs(notes.state.folders) do
    if f.folder == 'Existing' then
      api.nvim_win_set_cursor(notes.state.folders_win, { i, 0 })
    end
  end
  vim.ui.input = function(_, cb) cb('X\\Y') end
  picker.rename_folder()
  vim.ui.input = orig
  check(
    'rename_folder rejects backslash',
    fn.isdirectory(dir .. '/Existing') == 1 and fn.isdirectory(dir .. '/X') == 0
  )

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
