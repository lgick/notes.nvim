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
  check('target folder first among real folders', notes.state.folders[2].folder == 'Target', folder_names()[2])
  check(
    'notes column shows target folder note',
    #notes.state.items == 1 and notes.state.items[1].title == 'move me',
    table.concat(titles(), ',')
  )

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

io.write('\n')
if failures > 0 then
  io.write(failures .. ' check(s) FAILED\n')
  vim.cmd('cquit 1')
else
  io.write('all picker checks passed\n')
  vim.cmd('quit')
end
