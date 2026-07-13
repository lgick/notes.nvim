-- Headless picker tests for the filetree explorer model:
-- recursive tree scan/build/render, expand/collapse, title-from-first-line,
-- empty-note rules, create/move/rename/delete on the tree, and the
-- delete-of-open-note placeholder fallback.
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

local function tree_items()
  return notes.state.tree_items or {}
end

local function folder_names()
  local out = {}
  for _, it in ipairs(tree_items()) do
    if it.type == 'folder' then
      out[#out + 1] = it.name
    end
  end
  return out
end

local function note_titles()
  local out = {}
  for _, it in ipairs(tree_items()) do
    if it.type == 'note' then
      out[#out + 1] = it.title
    end
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

local function contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

-- Extmarks on a single 1-based buffer row. nvim_buf_get_extmarks treats bare
-- integer start/end as extmark ids (not row numbers), so range queries must use
-- {row, col} tuples or, as here, a full-buffer scan filtered by row.
local function marks_on_row(buf, ns, row1)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[2] == row1 - 1 then
      out[#out + 1] = m
    end
  end
  return out
end

-- 1-based row of a folder by relative path, or nil
local function folder_row(path)
  for i, it in ipairs(tree_items()) do
    if it.type == 'folder' and it.path == path then
      return i
    end
  end
  return nil
end

-- 1-based row of a note by absolute file path, or nil
local function note_row(file)
  for i, it in ipairs(tree_items()) do
    if it.type == 'note' and it.file == file then
      return i
    end
  end
  return nil
end

-- Move the explorer cursor onto the folder/note row; returns the row (or nil).
local function goto_folder(path)
  local r = folder_row(path)
  if r then
    api.nvim_win_set_cursor(notes.state.explorer_win, { r, 0 })
  end
  return r
end

local function goto_note(file)
  local r = note_row(file)
  if r then
    api.nvim_win_set_cursor(notes.state.explorer_win, { r, 0 })
  end
  return r
end

-- Expand a folder (and its ancestors, which must already be visible/expanded)
-- and repopulate so its children become visible.
local function expand_folder(path)
  notes.state.expanded_folders = notes.state.expanded_folders or {}
  notes.state.expanded_folders[path] = true
  picker.populate()
end

-- ── scan + titles ─────────────────────────────────────────────────────────────
do
  io.write('scan + titles\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'alpha note', 'second line' })
  writefile(dir .. '/n2', { '', '  beta note' }) -- title = first non-blank line
  writefile(dir .. '/Work/n3', { 'gamma note' })
  writefile(dir .. '/blank', {}) -- empty note

  fresh_open(dir)

  check('folders include "Work"', contains(folder_names(), 'Work'))
  check('title from first line', contains(all_titles(), 'alpha note'))
  check('title skips blank lines', contains(all_titles(), 'beta note'))
  check('nested note scanned', contains(all_titles(), 'gamma note'))
  check('empty note titled "New Note"', contains(all_titles(), 'New Note'))
  -- Work starts collapsed, so its nested note is not shown at the root level
  check('collapsed root excludes nested note', not contains(note_titles(), 'gamma note'))
  local roots = note_titles()
  check('empty note pinned to top among root notes', roots[1] == 'New Note', roots[1])

  notes.close()
end

-- ── collapsed folders hide their notes; expanding reveals them nested ─────────
do
  io.write('expand reveals nested notes; collapsed hides them\n')
  local dir = tmpdir()
  writefile(dir .. '/root_note', { 'at root' })
  writefile(dir .. '/Work/work_note', { 'in work' })

  fresh_open(dir)
  check(
    'collapsed: only the root note is visible',
    #note_titles() == 1 and note_titles()[1] == 'at root',
    table.concat(note_titles(), ',')
  )

  expand_folder('Work')
  check(
    'expanded: both notes visible',
    contains(note_titles(), 'at root') and contains(note_titles(), 'in work')
  )

  local work_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'in work' then
      work_file = n.file
    end
  end
  local wrow, nrow = folder_row('Work'), note_row(work_file)
  check(
    'the nested note is one level deeper than its folder',
    notes.state.tree_items[nrow].depth == notes.state.tree_items[wrow].depth + 1
  )

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
  check('fresher folder before staler', names[1] == 'Fresh' and names[2] == 'Old', table.concat(names, ','))

  notes.close()
end

-- ── folders sort before notes at the same tree level ─────────────────────────
do
  io.write('folders sort before notes at the same level\n')
  local dir = tmpdir()
  writefile(dir .. '/zzz_note', { 'zzz note' })
  fn.mkdir(dir .. '/aaa_folder', 'p')
  fn.writefile({}, dir .. '/aaa_folder/.gitkeep')

  fresh_open(dir)
  local first = notes.state.tree_items[1]
  check('first root row is the folder, not the note', first and first.type == 'folder', first and first.type)

  notes.close()
end

-- ── notes row format: "dd.mm.yyyy - title" ───────────────────────────────────
do
  io.write('row format\n')
  local dir = tmpdir()
  writefile(dir .. '/n', { 'hello' })

  fresh_open(dir)
  local row = api.nvim_buf_get_lines(notes.state.explorer_buf, 0, 1, false)[1]
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
  local marks = api.nvim_buf_get_extmarks(notes.state.explorer_buf, ns_title, 0, -1, { details = true })
  check('one title mark rendered', #marks == 1, 'count=' .. #marks)
  -- root note, no icon: prefix "dd.mm.yyyy - " is 13 bytes
  check('title mark starts after date prefix', marks[1] and marks[1][3] == 13, marks[1] and marks[1][3])
  check('title mark uses NotesTitle', marks[1] and marks[1][4].hl_group == 'NotesTitle')

  notes.close()
end

-- ── recursive indent: 2 spaces per depth level ────────────────────────────────
do
  io.write('recursive indent\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B')

  local a_row, b_row = folder_row('A'), folder_row('A/B')
  local a_line = api.nvim_buf_get_lines(notes.state.explorer_buf, a_row - 1, a_row, false)[1]
  local b_line = api.nvim_buf_get_lines(notes.state.explorer_buf, b_row - 1, b_row, false)[1]
  check('A at depth 0 has no leading spaces', a_line:sub(1, 1) ~= ' ', a_line)
  check('A/B at depth 1 has a 2-space indent', b_line:sub(1, 2) == '  ' and b_line:sub(3, 3) ~= ' ', b_line)

  local note_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'deep note' then
      note_file = n.file
    end
  end
  local n_row = note_row(note_file)
  local n_line = api.nvim_buf_get_lines(notes.state.explorer_buf, n_row - 1, n_row, false)[1]
  check('note at depth 2 has a 4-space indent', n_line:sub(1, 4) == '    ' and n_line:sub(5, 5) ~= ' ', n_line)

  notes.close()
end

-- ── expand/collapse toggling via toggle_expand (`o`) ──────────────────────────
do
  io.write('expand/collapse toggling\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  check(
    'root shows only A (B and the note are hidden)',
    #tree_items() == 1 and tree_items()[1].path == 'A',
    tree_items()[1] and tree_items()[1].path
  )

  goto_folder('A')
  picker.toggle_expand()
  check('A expanded', notes.state.expanded_folders['A'] == true)
  check('A/B now visible under A', folder_row('A/B') ~= nil)
  check('the deep note still hidden (B not expanded)', not contains(note_titles(), 'deep note'))

  goto_folder('A/B')
  picker.toggle_expand()
  check('B expanded', notes.state.expanded_folders['A/B'] == true)
  check('the deep note now visible', contains(note_titles(), 'deep note'))

  goto_folder('A')
  picker.toggle_expand()
  check('A collapsed', notes.state.expanded_folders['A'] == nil)
  check('root shows only A again', #tree_items() == 1)

  notes.close()
end

-- ── toggle_expand on a note focuses the editor ────────────────────────────────
do
  io.write('toggle_expand on a note focuses the editor\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local file = notes.state.notes_all[1].file
  goto_note(file)
  api.nvim_set_current_win(notes.state.explorer_win)
  picker.toggle_expand()
  check('focus moved to the editor', api.nvim_get_current_win() == notes.state.edit_win)

  notes.close()
end

-- ── conflict highlight: conflicted note row + its folder row get NotesConflict ─
do
  io.write('conflict highlight\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/c1', { 'conflicted note' })

  fresh_open(dir)
  local cfile
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'Work' then
      cfile = n.file
    end
  end
  notes.state.conflicts = { [cfile] = true }
  expand_folder('Work')

  local ns_conflict = api.nvim_create_namespace('notes_conflict')
  local nrow = note_row(cfile)
  local note_marks = marks_on_row(notes.state.explorer_buf, ns_conflict, nrow)
  check('note row highlighted', #note_marks == 1, 'count=' .. #note_marks)
  check('note row uses NotesConflict', note_marks[1] and note_marks[1][4].hl_group == 'NotesConflict')

  local frow = folder_row('Work')
  local fmarks = marks_on_row(notes.state.explorer_buf, ns_conflict, frow)
  check(
    'conflicted folder row highlighted',
    #fmarks == 1 and fmarks[1][4].hl_group == 'NotesConflict'
  )

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
  picker.populate() -- root level (A collapsed): ancestor A must show as conflicted

  local ns_conflict = api.nvim_create_namespace('notes_conflict')
  local a_row = folder_row('A')
  local fmarks = marks_on_row(notes.state.explorer_buf, ns_conflict, a_row)
  check(
    'ancestor folder A highlighted for a deeply nested conflict',
    #fmarks == 1 and fmarks[1][4].hl_group == 'NotesConflict'
  )

  notes.close()
end

-- ── NotesActive highlights the open note row ──────────────────────────────────
do
  io.write('NotesActive on the open note row\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local file = notes.state.notes_all[1].file
  goto_note(file)
  picker.open_selected()

  local row = note_row(file)
  local ns_active = api.nvim_create_namespace('notes_active')
  local marks = marks_on_row(notes.state.explorer_buf, ns_active, row)
  check('NotesActive mark present on the open note row', #marks == 1 and marks[1][4].hl_group == 'NotesActive')

  notes.close()
end

-- ── NotesCut extmark outranks the base NotesDir highlight ─────────────────────
do
  io.write('NotesCut outranks NotesDir\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  goto_folder('A')
  picker.cut()

  local a_row = folder_row('A')
  local ns_cut = api.nvim_create_namespace('notes_list')
  local ns_folders = api.nvim_create_namespace('notes_folders')
  local cut_marks = marks_on_row(notes.state.explorer_buf, ns_cut, a_row)
  local dir_marks = marks_on_row(notes.state.explorer_buf, ns_folders, a_row)
  local cut_priority = cut_marks[1] and cut_marks[1][4].hl_group == 'NotesCut' and cut_marks[1][4].priority
  local dir_priority = dir_marks[1] and dir_marks[1][4].priority
  check('NotesCut extmark present', cut_priority ~= nil)
  check(
    'NotesCut outranks NotesDir',
    cut_priority ~= nil and dir_priority ~= nil and cut_priority > dir_priority,
    'cut=' .. tostring(cut_priority) .. ' dir=' .. tostring(dir_priority)
  )

  notes.close()
end

-- ── tree_icons: fallback and custom override ──────────────────────────────────
do
  io.write('tree_icons\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  local ui = require('notes.ui')
  notes.config.tree_icons = nil
  local icons = ui.tree_icons()
  -- headless: nvim-web-devicons is not loaded → plain Unicode fallback
  check('closed folder fallback is ▶', icons.folder == '\xe2\x96\xb6', icons.folder)
  check('open folder fallback is ▼', icons.folder_open == '\xe2\x96\xbc', icons.folder_open)
  check('note icon empty by default', icons.note == '')

  notes.config.tree_icons = { folder = 'C', folder_open = 'O', note = 'N' }
  local custom = ui.tree_icons()
  check('custom folder icon', custom.folder == 'C')
  check('custom folder_open icon', custom.folder_open == 'O')
  check('custom note icon', custom.note == 'N')

  local row = folder_row('A')
  picker.render_tree()
  local line = api.nvim_buf_get_lines(notes.state.explorer_buf, row - 1, row, false)[1]
  check('rendered folder row uses the custom closed-folder icon', line:sub(1, 1) == 'C', line)

  notes.config.tree_icons = nil
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
  expand_folder('Work')
  goto_note(cfile)

  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_note()
  check('delete_note blocked', fn.filereadable(cfile) == 1)

  picker.cut()
  check('cut blocked (nothing marked)', notes.state.cut == nil)
  notes.state.cut = cfile -- force a marked conflicted note
  goto_folder('Dest')
  picker.paste()
  check('paste blocked', fn.filereadable(cfile) == 1 and fn.filereadable(dir .. '/Dest/c1') == 0)
  notes.state.cut = nil

  goto_folder('Work')
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

-- ── block folder move (cut/paste) on conflict ─────────────────────────────────
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

  goto_folder('Work')
  picker.cut()
  check('cut blocked on conflict', notes.state.cut_folder == nil)

  notes.state.cut_folder = 'Work' -- force a marked conflicted folder
  goto_folder('Dest')
  picker.paste()
  check(
    'paste_folder blocked on conflict',
    fn.isdirectory(dir .. '/Work') == 1 and fn.isdirectory(dir .. '/Dest/Work') == 0
  )

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
  check('folder appears in tree', contains(folder_names(), 'Personal'))

  notes.close()
end

-- ── create_folder creates inside the current level and auto-expands it ────────
do
  io.write('create folder inside current level\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  goto_folder('A')

  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Sub') end
  picker.create_folder()
  vim.ui.input = orig

  check('subfolder created on disk', fn.isdirectory(dir .. '/A/Sub') == 1)
  check('.gitkeep written', fn.filereadable(dir .. '/A/Sub/.gitkeep') == 1)
  check('A auto-expanded so Sub is visible', folder_row('A/Sub') ~= nil)

  notes.close()
end

-- ── create_note moves the cursor onto the new note ───────────────────────────
do
  io.write('create moves cursor to new note\n')
  local dir = tmpdir()
  writefile(dir .. '/f/a', { 'aaa' })
  writefile(dir .. '/f/b', { 'bbb' })

  fresh_open(dir)
  expand_folder('f')
  goto_folder('f')

  picker.create_note()

  local new_row = note_row(notes.state.current_file)
  check(
    'cursor moved to the new note row',
    api.nvim_win_get_cursor(notes.state.explorer_win)[1] == new_row,
    tostring(new_row)
  )
  local it = notes.state.tree_items[new_row]
  check('new note is empty', it and it.empty == true)
  check('new note is inside f/', it and it.folder == 'f', it and it.folder)

  notes.close()
end

-- ── create_note: only one empty note per folder ──────────────────────────────
do
  io.write('create note dedupe\n')
  local dir = tmpdir()
  fresh_open(dir)

  -- empty tree: nothing under the cursor → context_folder() == '' (root)
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

-- ── create_note in a subfolder ────────────────────────────────────────────────
do
  io.write('create note in subfolder\n')
  local dir = tmpdir()
  fn.mkdir(dir .. '/Work', 'p')
  fn.writefile({}, dir .. '/Work/.gitkeep')

  fresh_open(dir)
  goto_folder('Work')
  picker.create_note()

  local f = notes.state.current_file
  check('note created', f ~= nil and fn.filereadable(f) == 1)
  check('note is inside Work/', f ~= nil and f:find('/Work/') ~= nil, tostring(f))

  notes.close()
end

-- ── create_note auto-expands a collapsed target folder ────────────────────────
do
  io.write('create_note auto-expands a collapsed target folder\n')
  local dir = tmpdir()
  writefile(dir .. '/Work/existing', { 'existing note' })

  fresh_open(dir)
  check('Work starts collapsed', notes.state.expanded_folders == nil or notes.state.expanded_folders['Work'] == nil)
  goto_folder('Work')
  picker.create_note()

  check('Work auto-expanded', notes.state.expanded_folders['Work'] == true)
  check('new note visible under Work', note_row(notes.state.current_file) ~= nil)

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
  local file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'move me' then
      file = n.file
    end
  end
  goto_note(file)
  picker.cut()
  check('cut marks the note', notes.state.cut == file)

  goto_folder('Target')
  picker.paste()

  check('note moved into folder', fn.filereadable(dir .. '/Target/movable') == 1)
  check('old path gone', fn.filereadable(dir .. '/movable') == 0)
  check('cut cleared', notes.state.cut == nil)
  check('target folder auto-expanded', notes.state.expanded_folders['Target'] == true)
  local moved_row = note_row(dir .. '/Target/movable')
  check(
    'cursor lands on the moved note',
    moved_row ~= nil and api.nvim_win_get_cursor(notes.state.explorer_win)[1] == moved_row
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
  expand_folder('a_src')
  local file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'move me' then
      file = n.file
    end
  end
  goto_note(file)
  picker.cut()
  goto_folder('z_dst')
  picker.paste()

  -- force the exact collision: a_src dir mtime == z_dst note mtime (same second)
  fn.system({ 'touch', '-t', '202601011200', dir .. '/a_src' })
  fn.system({ 'touch', '-t', '202601011200', dir .. '/z_dst/note' })

  for _ = 1, 5 do
    picker.populate()
    check('destination z_dst is first folder', folder_names()[1] == 'z_dst', folder_names()[1])
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
  fn.system({ 'touch', '-t', '202601010003', dir .. '/f/c' })
  fn.system({ 'touch', '-t', '202601010002', dir .. '/f/b' })
  fn.system({ 'touch', '-t', '202601010001', dir .. '/f/a' })

  fresh_open(dir)
  expand_folder('f')

  local file_b
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'bbb' then
      file_b = n.file
    end
  end
  goto_note(file_b)
  local row_before = api.nvim_win_get_cursor(notes.state.explorer_win)[1]
  picker.cut()
  check(
    'cursor stays on the same note after cut',
    api.nvim_win_get_cursor(notes.state.explorer_win)[1] == row_before
  )
  check('marked note is b', notes.state.cut == file_b)

  picker.cut() -- cancel on the same row
  check('cursor stays after cancel', api.nvim_win_get_cursor(notes.state.explorer_win)[1] == row_before)
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
  expand_folder('f')

  local file_b
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'bbb' then
      file_b = n.file
    end
  end
  goto_note(file_b)
  picker.open_selected()
  check('note b is open', notes.state.current_file == file_b)
  local row_b = api.nvim_win_get_cursor(notes.state.explorer_win)[1]

  -- a background sync would call refresh(); cursor must stay on the active note
  picker.refresh()
  check(
    'cursor stays on active note after refresh',
    api.nvim_win_get_cursor(notes.state.explorer_win)[1] == row_b
  )

  vim.bo[notes.state.edit_buf].modified = false
  notes.close()
end

-- ── render_tree preserves cursor on an unrelated row across a background change ─
do
  io.write('render_tree preserves cursor across an unrelated expand\n')
  local dir = tmpdir()
  writefile(dir .. '/Zebra note', { 'zebra' })
  fn.mkdir(dir .. '/Alpha', 'p')
  fn.writefile({}, dir .. '/Alpha/.gitkeep')

  fresh_open(dir)
  local zebra_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'zebra' then
      zebra_file = n.file
    end
  end
  goto_note(zebra_file)

  notes.state.expanded_folders = notes.state.expanded_folders or {}
  notes.state.expanded_folders['Alpha'] = true
  picker.populate()

  check(
    'cursor stays on the zebra note row after an unrelated expand',
    api.nvim_win_get_cursor(notes.state.explorer_win)[1] == note_row(zebra_file)
  )

  notes.close()
end

-- ── cancel move: second `x` on the marked note clears the mark ────────────────
do
  io.write('cancel move (toggle x)\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local file = notes.state.notes_all[1].file
  goto_note(file)
  picker.cut()
  check('cut marks the note', notes.state.cut == file)
  picker.cut() -- second press on the same note cancels
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
  local file = notes.state.notes_all[1].file
  goto_note(file)
  picker.open_selected()
  -- modify the open note without saving, then move it
  api.nvim_buf_set_lines(notes.state.edit_buf, 0, -1, false, { 'move me', 'UNSAVED EDIT' })
  picker.cut()
  goto_folder('Target')
  picker.paste()

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

-- ── move note to root via the trailing "root drop zone" row ───────────────────
do
  io.write('move note to root\n')
  local dir = tmpdir()
  writefile(dir .. '/Inbox/n1', { 'inbox note' })

  fresh_open(dir)
  expand_folder('Inbox')
  local file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'inbox note' then
      file = n.file
    end
  end
  goto_note(file)
  picker.cut()
  check('cut set', notes.state.cut ~= nil)

  -- cursor past the last tree row = root drop zone (context_folder() == '')
  local last = #notes.state.tree_items + 1
  api.nvim_win_set_cursor(notes.state.explorer_win, { last, 0 })
  check('drop-zone row resolves to root', picker.context_folder() == '')
  picker.paste()

  check('note moved to root dir', fn.filereadable(dir .. '/n1') == 1, dir .. '/n1')
  check('old path gone', fn.filereadable(dir .. '/Inbox/n1') == 0)
  check('cut cleared', notes.state.cut == nil)

  notes.close()
end

-- ── rename folder (moves all its notes) ──────────────────────────────────────
do
  io.write('rename folder\n')
  local dir = tmpdir()
  writefile(dir .. '/Old/note', { 'content' })

  fresh_open(dir)
  goto_folder('Old')
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('New') end
  picker.rename_folder()
  vim.ui.input = orig

  check('folder renamed on disk', fn.isdirectory(dir .. '/New') == 1 and fn.isdirectory(dir .. '/Old') == 0)
  check('note moved with folder', fn.filereadable(dir .. '/New/note') == 1)

  notes.close()
end

-- ── rename nested folder rewrites expanded_folders keys ───────────────────────
do
  io.write('rename nested folder rewrites expanded_folders\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B') -- B itself expanded

  goto_folder('A/B')
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig

  check('folder renamed on disk', fn.isdirectory(dir .. '/A/Renamed') == 1 and fn.isdirectory(dir .. '/A/B') == 0)
  check('note moved with folder', fn.filereadable(dir .. '/A/Renamed/note') == 1)
  check(
    'expanded_folders key rewritten to the new path',
    notes.state.expanded_folders['A/Renamed'] == true,
    tostring(notes.state.expanded_folders['A/Renamed'])
  )
  check('old key removed', notes.state.expanded_folders['A/B'] == nil)
  check('the deep note (now under A/Renamed) is still visible', contains(note_titles(), 'deep note'))

  notes.close()
end

-- ── delete the open note → placeholder, no E211 ──────────────────────────────
do
  io.write('delete open note\n')
  local dir = tmpdir()
  writefile(dir .. '/only', { 'the only note' })

  fresh_open(dir)
  local file = notes.state.notes_all[1].file
  goto_note(file)
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
  check(
    'explorer shows empty marker',
    api.nvim_buf_get_lines(notes.state.explorer_buf, 0, -1, false)[1] == '(no notes)'
  )

  notes.close()
end

-- ── delete folder removes it from the tree and its expanded_folders keys ──────
do
  io.write('delete nested folder clears its own and descendant expanded_folders keys\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/C/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B')
  expand_folder('A/B/C')

  goto_folder('A/B')
  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('B deleted from disk', fn.isdirectory(dir .. '/A/B') == 0)
  check('A still expanded', notes.state.expanded_folders['A'] == true)
  check('A/B key removed', notes.state.expanded_folders['A/B'] == nil)
  check('A/B/C (descendant) key removed', notes.state.expanded_folders['A/B/C'] == nil)
  check('A now shows no children (B gone)', folder_row('A/B') == nil)

  notes.close()
end

-- ── prune_expanded drops stale keys not on disk ────────────────────────────────
do
  io.write('prune_expanded disk check\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  notes.state.expanded_folders = { A = true, Ghost = true } -- Ghost never existed on disk
  picker.populate()
  check('stale key pruned', notes.state.expanded_folders['Ghost'] == nil)
  check('valid key kept', notes.state.expanded_folders['A'] == true)

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
  local file = notes.state.notes_all[1].file
  goto_note(file)
  picker.open_selected()
  check('note open in editor', notes.state.current_file ~= nil)

  local buf = notes.state.edit_buf
  api.nvim_buf_set_lines(buf, 0, -1, false, { '', 'updated title', 'body' })
  picker.update_live_title(buf, notes.state.current_file)

  local row = note_row(notes.state.current_file)
  check(
    'tree item title updated',
    notes.state.tree_items[row].title == 'updated title',
    notes.state.tree_items[row].title
  )
  local line = api.nvim_buf_get_lines(notes.state.explorer_buf, row - 1, row, false)[1]
  check('rendered row shows updated title', line:find('updated title') ~= nil, line)
  check('empty flag cleared after update', notes.state.tree_items[row].empty == false)

  vim.bo[buf].modified = false
  notes.close()
end

-- ── paste no-op when nothing is cut ──────────────────────────────────────────
do
  io.write('paste no-op without cut\n')
  local dir = tmpdir()
  writefile(dir .. '/note', { 'test' })
  fn.mkdir(dir .. '/Dest', 'p')
  fn.writefile({}, dir .. '/Dest/.gitkeep')

  fresh_open(dir)
  notes.state.cut = nil

  goto_folder('Dest')
  picker.paste()

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
  local file = notes.state.notes_all[1].file
  goto_note(file)
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
  local file2 = notes.state.notes_all[1].file
  goto_note(file2)
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

-- ── toggle_panels: hide and restore the explorer window ────────────────────────
do
  io.write('toggle_panels\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })
  writefile(dir .. '/Work/n2', { 'note two' })

  fresh_open(dir)
  local ui = require('notes.ui')

  -- initial state: panel visible
  check('initial: panels_hidden false', notes.state.panels_hidden == false)
  check(
    'initial: explorer_win valid',
    notes.state.explorer_win ~= nil and api.nvim_win_is_valid(notes.state.explorer_win)
  )

  -- hide the panel
  ui.toggle_panels()
  check('hidden: panels_hidden true', notes.state.panels_hidden == true)
  check('hidden: explorer_win nil', notes.state.explorer_win == nil)
  check(
    'hidden: edit_win still valid',
    notes.state.edit_win ~= nil and api.nvim_win_is_valid(notes.state.edit_win)
  )
  check('hidden: plugin still open', notes.is_open())

  -- show the panel again
  ui.toggle_panels()
  check('shown: panels_hidden false', notes.state.panels_hidden == false)
  check(
    'shown: explorer_win valid',
    notes.state.explorer_win ~= nil and api.nvim_win_is_valid(notes.state.explorer_win)
  )

  -- the panel is populated after restore
  local lines = api.nvim_buf_get_lines(notes.state.explorer_buf, 0, -1, false)
  check('shown: explorer populated', #lines > 0 and lines[1] ~= '(no notes)', (#lines > 0 and lines[1]) or 'empty')

  -- CursorMoved still works: moving onto a note opens it (root note "n1", since
  -- "Work/n2" is hidden until Work is expanded)
  api.nvim_set_current_win(notes.state.explorer_win)
  local file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'note one' then
      file = n.file
    end
  end
  goto_note(file)
  picker.open_selected()
  check('cursor-move opens note after restore', notes.state.current_file ~= nil)

  if notes.state.edit_buf and api.nvim_buf_is_valid(notes.state.edit_buf) then
    vim.bo[notes.state.edit_buf].modified = false
  end
  notes.close()
end

-- ── toggle_panels: closing works correctly while the panel is hidden ───────────
do
  io.write('close with hidden panels\n')
  local dir = tmpdir()
  writefile(dir .. '/n1', { 'note one' })

  fresh_open(dir)
  local ui = require('notes.ui')

  ui.toggle_panels()
  check('panel hidden before close', notes.state.panels_hidden == true)

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

-- ── cut: mutually exclusive between note and folder ────────────────────────────
do
  io.write('cut is mutually exclusive between note and folder\n')
  local dir = tmpdir()
  writefile(dir .. '/root note', { 'root note' })
  writefile(dir .. '/A/note', { 'a note' })

  local ns_cut = api.nvim_create_namespace('notes_list')
  local function has_cut_mark_at(row)
    for _, m in ipairs(marks_on_row(notes.state.explorer_buf, ns_cut, row)) do
      if m[4].hl_group == 'NotesCut' then
        return true
      end
    end
    return false
  end

  fresh_open(dir)
  local root_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.title == 'root note' then
      root_file = n.file
    end
  end
  local note_row_i = goto_note(root_file)
  picker.cut()
  check('note marked', notes.state.cut ~= nil)
  check('note cut mark drawn', has_cut_mark_at(note_row_i))

  local a_row = goto_folder('A')
  picker.cut()
  check('marking a folder clears the marked note', notes.state.cut == nil)
  check('folder marked', notes.state.cut_folder == 'A')
  check('stale note cut mark is gone', not has_cut_mark_at(note_row_i))
  check('folder cut mark drawn', has_cut_mark_at(a_row))

  goto_note(root_file)
  picker.cut()
  check('marking a note clears the marked folder', notes.state.cut_folder == nil)
  check('stale folder cut mark is gone', not has_cut_mark_at(a_row))

  notes.close()
end

-- ── cut folder: mark/cancel ────────────────────────────────────────────────────
do
  io.write('cut folder mark/cancel\n')
  local dir = tmpdir()
  writefile(dir .. '/A/note', { 'a note' })

  fresh_open(dir)
  goto_folder('A')
  picker.cut()
  check('folder A marked', notes.state.cut_folder == 'A')
  picker.cut() -- second press cancels
  check('second x cancels', notes.state.cut_folder == nil)

  notes.close()
end

-- ── recursive folder freshness: a note in a grandchild bumps its ancestor ─────
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
    names[1] == 'Fresh' and names[2] == 'Old',
    table.concat(names, ',')
  )

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
  expand_folder('A')
  goto_folder('A/B')
  picker.cut()
  check('B marked', notes.state.cut_folder == 'A/B')

  goto_folder('C')
  picker.paste() -- bound key dispatches to paste_folder when a folder is cut

  check('B moved on disk', fn.isdirectory(dir .. '/A/B') == 0 and fn.isdirectory(dir .. '/C/B') == 1)
  check('note travelled with the folder', fn.filereadable(dir .. '/C/B/note') == 1)
  check('cut_folder cleared', notes.state.cut_folder == nil)
  check('C auto-expanded so B is visible under it', notes.state.expanded_folders['C'] == true)
  local moved_row = folder_row('C/B')
  check(
    'cursor lands on the moved folder row',
    moved_row ~= nil and api.nvim_win_get_cursor(notes.state.explorer_win)[1] == moved_row
  )

  notes.close()
end

-- ── paste_folder: cannot move a folder into its own descendant ─────────────────
do
  io.write('paste_folder blocks moving into own subtree\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'note in B' })

  fresh_open(dir)
  goto_folder('A')
  picker.cut()
  check('A marked', notes.state.cut_folder == 'A')

  expand_folder('A')
  goto_folder('A/B') -- a descendant of A
  picker.paste()
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
  goto_folder('A')
  picker.cut()
  goto_folder('C')
  picker.paste()
  check('source A untouched', fn.isdirectory(dir .. '/A') == 1)
  check('destination A/A untouched', fn.filereadable(dir .. '/C/A/other') == 1)

  notes.close()
end

-- ── rename_folder rewrites a marked note's absolute st.cut path ────────────────
do
  io.write('rename_folder rewrites st.cut\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B')
  local note_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'A/B' then
      note_file = n.file
    end
  end
  goto_note(note_file)
  picker.cut()
  check('note marked', notes.state.cut == note_file)

  goto_folder('A/B')
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb('Renamed') end
  picker.rename_folder()
  vim.ui.input = orig

  local expected = dir .. '/A/Renamed/note'
  check('st.cut rewritten to the new path', notes.state.cut == expected, notes.state.cut)
  check('the rewritten path exists on disk', fn.filereadable(notes.state.cut) == 1)

  -- paste to root via the drop zone confirms the rewritten path is still valid
  local last = #notes.state.tree_items + 1
  api.nvim_win_set_cursor(notes.state.explorer_win, { last, 0 })
  picker.paste()
  check('paste after rename succeeds', fn.filereadable(dir .. '/note') == 1)

  notes.close()
end

-- ── rename_folder rewrites a marked folder's st.cut_folder path ────────────────
do
  io.write('rename_folder rewrites st.cut_folder\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/C/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B')
  goto_folder('A/B/C')
  picker.cut()
  check('C marked', notes.state.cut_folder == 'A/B/C')

  goto_folder('A/B')
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
  expand_folder('A')
  expand_folder('A/B')
  local note_file
  for _, n in ipairs(notes.state.notes_all) do
    if n.folder == 'A/B' then
      note_file = n.file
    end
  end
  goto_note(note_file)
  picker.cut()
  check('note marked', notes.state.cut ~= nil)

  goto_folder('A')
  local orig = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  picker.delete_folder()
  vim.fn.confirm = orig

  check('A deleted from disk', fn.isdirectory(dir .. '/A') == 0)
  check('st.cut cleared after ancestor deleted', notes.state.cut == nil)

  -- paste must be a safe no-op (nothing marked), not an error
  local last = #notes.state.tree_items + 1
  api.nvim_win_set_cursor(notes.state.explorer_win, { last, 0 })
  picker.paste()
  check('paste after stale cut is a safe no-op', fn.filereadable(dir .. '/root note') == 1)

  notes.close()
end

-- ── delete_folder clears a marked folder's st.cut_folder when inside the subtree ─
do
  io.write('delete_folder clears st.cut_folder\n')
  local dir = tmpdir()
  writefile(dir .. '/A/B/C/note', { 'deep note' })

  fresh_open(dir)
  expand_folder('A')
  expand_folder('A/B')
  goto_folder('A/B/C')
  picker.cut()
  check('C marked', notes.state.cut_folder == 'A/B/C')

  goto_folder('A')
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
  goto_folder('Existing')
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
