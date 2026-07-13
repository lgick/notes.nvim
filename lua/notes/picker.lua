-- Filetree explorer model: a single tree (folders + notes, any depth) rendered
-- into one buffer, with the editor below. Notes are ID-named files; the title is
-- the first non-blank line of their content.

local M = {}

local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('notes_list')
local ns_active = api.nvim_create_namespace('notes_active')
local ns_folders = api.nvim_create_namespace('notes_folders')
local ns_title = api.nvim_create_namespace('notes_title')
local ns_conflict = api.nvim_create_namespace('notes_conflict')

local EMPTY_TITLE = 'New Note'

-- Relative paths of every real folder at any depth from the last scan() ("Work",
-- "Work/Projects"). Module-local: build_tree() derives the tree from it; not
-- part of the documented state.
local all_folders = {}

local function cfg()
  return require('notes').config
end

local function state()
  return require('notes').state
end

-- True when the note at `file` is currently in a merge conflict.
local function is_conflicted(file)
  return (state().conflicts or {})[file] ~= nil
end
M.is_conflicted = is_conflicted

-- True when any note inside `folder` (relative path, any depth; '' = root) OR any
-- of its descendants is in a merge conflict. '' covers the whole tree.
local function folder_has_conflict(folder)
  local st = state()
  if not st.conflicts then
    return false
  end
  local target = folder or ''
  for _, n in ipairs(st.notes_all or {}) do
    if st.conflicts[n.file] then
      if target == '' or n.folder == target or n.folder:sub(1, #target + 1) == target .. '/' then
        return true
      end
    end
  end
  return false
end

local function notify_conflict_block()
  vim.notify('[notes.nvim] Resolve the conflict first', vim.log.levels.WARN)
end

local function sync()
  local c = cfg()
  if c.repo == '' then
    return
  end
  -- Пока идёт стартовый restore/pull (synced=false), CRUD-синхронизацию не запускаем:
  -- её git-команды гонялись бы с открытым M.pull и могли протолкнуть в remote коммит,
  -- из-за которого этот pull падает на ещё untracked-файле ("Cannot fast-forward your
  -- working tree"). Всё созданное за это окно закоммитит пост-pull sync_on_exit в
  -- init.open (тот же гейт уже стоит на BufWritePost).
  if not require('notes').state.synced then
    return
  end
  -- Полностью асинхронно и под мьютексом sync_on_exit: commit_only внутри делает свой
  -- `git add -A` (в т.ч. фиксирует удаление, чтобы restore() его не воскресил), поэтому
  -- отдельный блокирующий `git add -A` здесь не нужен — он только морозил UI и плодил
  -- конкурентные git-процессы.
  require('notes.git').sync_on_exit()
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

-- Scan walks the notes directory recursively, at any depth. Builds the flat notes
-- list (state.notes_all) and the flat list of all folder relative paths
-- (all_folders); build_tree() later derives the visible tree from the latter.
-- Hidden entries (.git, .gitkeep) are skipped.
function M.scan()
  local dir = cfg().dir
  local real = {} -- relative paths of every folder, any depth
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

  local function walk(abs_dir, rel)
    for name, ftype in vim.fs.dir(abs_dir) do
      if name:sub(1, 1) ~= '.' then
        local abs = abs_dir .. '/' .. name
        if ftype == 'directory' then
          local child_rel = rel == '' and name or (rel .. '/' .. name)
          real[#real + 1] = child_rel
          walk(abs, child_rel)
        elseif ftype == 'file' then
          add_file(abs, rel)
        end
      end
    end
  end

  if fn.isdirectory(dir) == 1 then
    walk(dir, '')
  end

  table.sort(notes, function(a, b)
    if a.empty ~= b.empty then
      return a.empty -- empty notes always pinned to the top
    end
    return a.mtime > b.mtime
  end)

  all_folders = real
  state().notes_all = notes
end

-- Freshness of `folder_rel` = the most recent mtime among all notes in it and its
-- descendants (recursively); if none exist anywhere in the subtree, falls back to
-- the directory's own mtime (≈ creation time), so a new empty folder sorts to the
-- top among its siblings.
local function folder_recursive_mtime(folder_rel)
  local max_mtime = 0
  local has_note = false
  for _, n in ipairs(state().notes_all or {}) do
    if n.folder == folder_rel or n.folder:sub(1, #folder_rel + 1) == folder_rel .. '/' then
      max_mtime = math.max(max_mtime, n.mtime)
      has_note = true
    end
  end
  if has_note then
    return max_mtime, true
  end
  local s = vim.uv.fs_stat(cfg().dir .. '/' .. folder_rel)
  return s and s.mtime.sec or 0, false
end

-- Drop expanded-folder entries whose path no longer exists in all_folders (folder
-- deleted/renamed outside the plugin, or by a rename/delete action that didn't
-- clean up its own key).
local function prune_expanded()
  local st = state()
  if not st.expanded_folders then
    return
  end
  local valid = {}
  for _, f in ipairs(all_folders) do
    valid[f] = true
  end
  for path in pairs(st.expanded_folders) do
    if not valid[path] then
      st.expanded_folders[path] = nil
    end
  end
end

-- Immediate children of `folder_rel` ('' = root) from all_folders, sorted by
-- recursive freshness. Strict total order (table.sort is not stable): freshness →
-- note-bearing → name. The note-bearing tie-break matters for paste: moving a note
-- out of a folder empties it and bumps the *directory* mtime to the same second as
-- the moved note's bumped mtime in the destination — without the tie-break the
-- unstable sort could float the (empty) source above the destination.
local function direct_children(folder_rel)
  local prefix = folder_rel == '' and '' or (folder_rel .. '/')
  local children = {}
  for _, f in ipairs(all_folders) do
    if folder_rel == '' then
      if not f:find('/') then
        children[#children + 1] = f
      end
    elseif f:sub(1, #prefix) == prefix and not f:sub(#prefix + 1):find('/') then
      children[#children + 1] = f
    end
  end

  local fm, has_note = {}, {}
  for _, f in ipairs(children) do
    fm[f], has_note[f] = folder_recursive_mtime(f)
  end
  table.sort(children, function(a, b)
    local ma, mb = fm[a] or 0, fm[b] or 0
    if ma ~= mb then
      return ma > mb
    end
    local na, nb = has_note[a] or false, has_note[b] or false
    if na ~= nb then
      return na
    end
    return a < b
  end)
  return children
end

-- Direct notes of `folder_rel` from state.notes_all; already sorted by scan()
-- (empty-first, then mtime descending).
local function direct_notes(folder_rel)
  local out = {}
  for _, n in ipairs(state().notes_all or {}) do
    if n.folder == folder_rel then
      out[#out + 1] = n
    end
  end
  return out
end

-- Builds the flat tree (state.tree_items) by recursively walking from the root
-- ('' ), descending into a folder only when it is in state.expanded_folders.
-- Folders are listed before notes at each level.
function M.build_tree()
  local st = state()
  st.expanded_folders = st.expanded_folders or {}
  local items = {}

  local function build_level(folder_rel, depth)
    for _, f in ipairs(direct_children(folder_rel)) do
      local expanded = st.expanded_folders[f] == true
      items[#items + 1] = {
        type = 'folder',
        path = f,
        name = f:match('[^/]+$'),
        depth = depth,
        expanded = expanded,
      }
      if expanded then
        build_level(f, depth + 1)
      end
    end
    for _, n in ipairs(direct_notes(folder_rel)) do
      items[#items + 1] = {
        type = 'note',
        file = n.file,
        folder = n.folder,
        title = n.title,
        mtime = n.mtime,
        empty = n.empty,
        depth = depth,
      }
    end
  end

  build_level('', 0)
  st.tree_items = items
end

local function note_key(file)
  return 'note:' .. file
end

local function folder_key(path)
  return 'folder:' .. path
end

local function item_key(it)
  return it.type == 'folder' and folder_key(it.path) or note_key(it.file)
end

local function item_at_cursor()
  local st = state()
  if not (st.explorer_win and api.nvim_win_is_valid(st.explorer_win)) then
    return nil
  end
  local l = api.nvim_win_get_cursor(st.explorer_win)[1]
  return (st.tree_items or {})[l]
end
M.item_at_cursor = item_at_cursor

-- The folder to create/paste into: the folder under the cursor, or the folder of
-- the note under the cursor; '' (root) if nothing is under the cursor.
function M.context_folder()
  local it = item_at_cursor()
  if not it then
    return ''
  end
  return it.type == 'folder' and it.path or it.folder
end

-- Move the explorer cursor onto the row matching `key` (as returned by item_key).
-- Returns true if found.
local function cursor_to(key)
  local st = state()
  if not (key and st.explorer_win and api.nvim_win_is_valid(st.explorer_win)) then
    return false
  end
  for i, it in ipairs(st.tree_items or {}) do
    if item_key(it) == key then
      pcall(api.nvim_win_set_cursor, st.explorer_win, { i, 0 })
      return true
    end
  end
  return false
end

-- Expand `folder` so a newly created/moved child inside it is visible. Ancestors
-- of `folder` are guaranteed already expanded: build_tree only ever surfaces an
-- item whose full ancestor chain is expanded, and `folder` came from
-- context_folder() (a currently visible row), so only `folder` itself needs it.
local function expand(folder)
  if folder ~= '' then
    local st = state()
    st.expanded_folders = st.expanded_folders or {}
    st.expanded_folders[folder] = true
  end
end

-- After a re-render, restore the cursor to the same logical item (by key) if it
-- is still present; otherwise fall back to the active note's row, else row 1.
-- Background re-renders (git sync, BufWritePost) must not yank the cursor to the
-- top while the user is elsewhere in the tree.
local function restore_cursor(prev_key)
  local st = state()
  if not (st.explorer_win and api.nvim_win_is_valid(st.explorer_win)) then
    return
  end
  if cursor_to(prev_key) then
    return
  end
  if st.current_file and cursor_to(note_key(st.current_file)) then
    return
  end
  if st.tree_items and #st.tree_items > 0 then
    pcall(api.nvim_win_set_cursor, st.explorer_win, { 1, 0 })
  end
end

function M.highlight_active()
  local st = state()
  if not (st.explorer_buf and api.nvim_buf_is_valid(st.explorer_buf)) then
    return
  end
  api.nvim_buf_clear_namespace(st.explorer_buf, ns_active, 0, -1)
  if st.current_file then
    for i, it in ipairs(st.tree_items or {}) do
      if it.type == 'note' and it.file == st.current_file then
        local line = api.nvim_buf_get_lines(st.explorer_buf, i - 1, i, false)[1] or ''
        api.nvim_buf_set_extmark(
          st.explorer_buf,
          ns_active,
          i - 1,
          0,
          { end_col = #line, hl_group = 'NotesActive', priority = 0 }
        )
        break
      end
    end
  end
end

function M.render_tree()
  local st = state()
  if not (st.explorer_buf and api.nvim_buf_is_valid(st.explorer_buf)) then
    return
  end

  local prev_key = nil
  if st.explorer_win and api.nvim_win_is_valid(st.explorer_win)
      and api.nvim_get_current_win() == st.explorer_win then
    local it = item_at_cursor()
    if it then
      prev_key = item_key(it)
    end
  end

  local icons = require('notes.ui').tree_icons()
  local lines = {}
  local title_col = {} -- byte offset of the title text, per line (notes only)

  for _, it in ipairs(st.tree_items or {}) do
    local indent = string.rep('  ', it.depth)
    if it.type == 'folder' then
      local glyph = it.expanded and icons.folder_open or icons.folder
      lines[#lines + 1] = indent .. glyph .. ' ' .. it.name .. '/'
    else
      local prefix = indent .. (icons.note ~= '' and (icons.note .. ' ') or '')
      local date = os.date('%d.%m.%Y', it.mtime) .. ' - '
      lines[#lines + 1] = prefix .. date .. it.title
      title_col[#lines] = #prefix + #date
    end
  end

  local empty = #lines == 0
  if empty then
    lines = { '(no notes)' }
  else
    -- Trailing blank row: an explicit "root" drop zone. Every folder/note row
    -- resolves context_folder() to itself or its own folder, so without this the
    -- root ('') could only be targeted when a root-level note happens to exist
    -- under the cursor — this blank line (item_at_cursor() finds nothing there)
    -- is always available for creating/pasting back at the top level.
    lines[#lines + 1] = ''
  end

  vim.bo[st.explorer_buf].modifiable = true
  api.nvim_buf_set_lines(st.explorer_buf, 0, -1, false, lines)
  vim.bo[st.explorer_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.explorer_buf, ns_folders, 0, -1)
  api.nvim_buf_clear_namespace(st.explorer_buf, ns_title, 0, -1)
  api.nvim_buf_clear_namespace(st.explorer_buf, ns_conflict, 0, -1)
  api.nvim_buf_clear_namespace(st.explorer_buf, ns, 0, -1)

  if not empty then
    for i, it in ipairs(st.tree_items) do
      local line = lines[i]
      if it.type == 'folder' then
        api.nvim_buf_set_extmark(
          st.explorer_buf,
          ns_folders,
          i - 1,
          0,
          { end_col = #line, hl_group = 'NotesDir', priority = 0 }
        )
        if folder_has_conflict(it.path) then
          api.nvim_buf_set_extmark(st.explorer_buf, ns_conflict, i - 1, 0, {
            end_col = #line,
            hl_group = 'NotesConflict',
            hl_mode = 'combine',
            priority = 300,
          })
        end
        if it.path == st.cut_folder then
          api.nvim_buf_set_extmark(
            st.explorer_buf,
            ns,
            i - 1,
            0,
            { end_col = #line, hl_group = 'NotesCut', priority = 200 }
          )
        end
      else
        api.nvim_buf_set_extmark(st.explorer_buf, ns_title, i - 1, title_col[i], {
          end_col = #line,
          hl_group = 'NotesTitle',
          hl_mode = 'combine',
          priority = 100,
        })
        if is_conflicted(it.file) then
          api.nvim_buf_set_extmark(st.explorer_buf, ns_conflict, i - 1, 0, {
            end_col = #line,
            hl_group = 'NotesConflict',
            hl_mode = 'combine',
            priority = 300,
          })
        end
        if it.file == st.cut then
          api.nvim_buf_set_extmark(
            st.explorer_buf,
            ns,
            i - 1,
            0,
            { end_col = #line, hl_group = 'NotesCut', priority = 200 }
          )
        end
      end
    end
  end

  restore_cursor(prev_key)
  M.highlight_active()
end

-- Update the title of the currently open note in-memory from the buffer content
-- (without a disk read), then re-render the tree. Called on every
-- TextChanged/TextChangedI in the editor buffer so the tree stays in sync while typing.
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
  for _, n in ipairs(st.notes_all or {}) do
    if n.file == file then
      n.title = title
      n.empty = empty
    end
  end
  for _, it in ipairs(st.tree_items or {}) do
    if it.type == 'note' and it.file == file then
      it.title = title
      it.empty = empty
    end
  end
  M.render_tree()
  require('notes.ui').refresh_editor_statusline()
end

function M.populate()
  M.scan()
  prune_expanded()
  M.build_tree()
  M.render_tree()
end

M.refresh = M.populate

-- `o` / `<CR>`: a folder toggles expand/collapse in place; a note focuses the editor.
function M.toggle_expand()
  local it = item_at_cursor()
  if not it then
    return
  end
  if it.type == 'folder' then
    local st = state()
    st.expanded_folders = st.expanded_folders or {}
    if st.expanded_folders[it.path] then
      st.expanded_folders[it.path] = nil
    else
      st.expanded_folders[it.path] = true
    end
    local key = folder_key(it.path)
    M.build_tree()
    M.render_tree()
    cursor_to(key)
  else
    local st = state()
    if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
      api.nvim_set_current_win(st.edit_win)
    end
  end
end

-- CursorMoved auto-open: a note under the cursor opens in the editor.
function M.open_selected()
  local it = item_at_cursor()
  if it and it.type == 'note' then
    require('notes.ui').open_in_edit(it.file)
    M.highlight_active()
  end
end

-- Unique ID filename (timestamp, no extension) inside target_dir.
local function new_id(target_dir)
  local base = os.date('%Y%m%d%H%M%S')
  local name = base .. '.md'
  local i = 1
  while
    fn.filereadable(target_dir .. '/' .. name) == 1
    or fn.isdirectory(target_dir .. '/' .. name) == 1
  do
    name = base .. '-' .. i .. '.md'
    i = i + 1
  end
  return name
end

-- `a`: new note in the context folder (folder under cursor, or the folder of the
-- note under cursor; root otherwise). Only one empty note may exist per folder: an
-- existing one is reopened instead.
function M.create_note()
  local dir = cfg().dir
  local folder = M.context_folder()
  local target_dir = folder == '' and dir or (dir .. '/' .. folder)

  for _, n in ipairs(state().notes_all or {}) do
    if n.empty and n.folder == folder then
      require('notes.ui').open_in_edit(n.file)
      expand(folder)
      M.populate()
      cursor_to(note_key(n.file))
      return
    end
  end

  fn.mkdir(target_dir, 'p')
  local target = target_dir .. '/' .. new_id(target_dir)
  fn.writefile({}, target)
  require('notes.ui').open_in_edit(target)
  expand(folder)
  M.populate()
  cursor_to(note_key(target))
  sync()
end

-- `A`: new folder in the context folder. A single leaf name is expected: '/' and
-- '\' are rejected (deeper nesting is reached by expanding and creating again).
function M.create_folder()
  local parent = M.context_folder()
  vim.ui.input({ prompt = 'New folder: ' }, function(input)
    if not input or input == '' then
      return
    end
    if input:find('[/\\]') then
      vim.notify('[notes.nvim] Folder name cannot contain "/" or "\\"', vim.log.levels.WARN)
      return
    end
    local rel = parent == '' and input or (parent .. '/' .. input)
    local path = cfg().dir .. '/' .. rel
    fn.mkdir(path, 'p')
    -- .gitkeep lets an otherwise empty folder be committed and synced
    fn.writefile({}, path .. '/.gitkeep')
    expand(parent)
    M.populate()
    cursor_to(folder_key(rel))
    sync()
  end)
end

function M.delete_note()
  local it = item_at_cursor()
  if not (it and it.type == 'note') then
    return
  end
  if is_conflicted(it.file) then
    notify_conflict_block()
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
  local it = item_at_cursor()
  if not (it and it.type == 'folder') then
    vim.notify('[notes.nvim] Select a folder to delete', vim.log.levels.WARN)
    return
  end
  local f = it.path

  if folder_has_conflict(f) then
    notify_conflict_block()
    return
  end
  local prompt = 'Delete folder "' .. f .. '" and all its notes?'
  if fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
    return
  end
  local path = cfg().dir .. '/' .. f
  local st = state()
  local cur = st.current_file
  if cur and (cur == path or cur:sub(1, #path + 1) == path .. '/') then
    require('notes.ui').show_placeholder()
  end
  fn.delete(path, 'rf')

  -- drop the deleted folder (and any of its descendants) from expanded_folders
  if st.expanded_folders then
    st.expanded_folders[f] = nil
    for p in pairs(st.expanded_folders) do
      if p:sub(1, #f + 1) == f .. '/' then
        st.expanded_folders[p] = nil
      end
    end
  end

  -- a marked note/folder may have been inside the deleted subtree — clear the
  -- pending cut so paste doesn't try to move a now-nonexistent path
  if st.cut and (st.cut == path or st.cut:sub(1, #path + 1) == path .. '/') then
    st.cut = nil
  end
  if st.cut_folder and (st.cut_folder == f or st.cut_folder:sub(1, #f + 1) == f .. '/') then
    st.cut_folder = nil
  end

  M.populate()
  sync()
end

-- `d`: dispatch by row type.
function M.delete()
  local it = item_at_cursor()
  if not it then
    return
  end
  if it.type == 'note' then
    M.delete_note()
  else
    M.delete_folder()
  end
end

-- `r`: rename the folder under the cursor. Only a single leaf changes; the
-- folder's parent path stays put.
function M.rename_folder()
  local it = item_at_cursor()
  if not (it and it.type == 'folder') then
    vim.notify('[notes.nvim] Select a folder to rename', vim.log.levels.WARN)
    return
  end
  local f = it.path

  local leaf = f:match('[^/]+$')
  vim.ui.input({ prompt = 'Rename folder: ', default = leaf }, function(input)
    if not input or input == '' or input == leaf then
      return
    end
    if input:find('[/\\]') then
      vim.notify('[notes.nvim] Folder name cannot contain "/" or "\\"', vim.log.levels.WARN)
      return
    end
    if folder_has_conflict(f) then
      notify_conflict_block()
      return
    end
    local dir = cfg().dir
    local parent = f:match('^(.*)/[^/]+$')
    local newrel = parent and (parent .. '/' .. input) or input
    local oldp = dir .. '/' .. f
    local newp = dir .. '/' .. newrel
    local st = state()
    local cur = st.current_file
    local inside = cur and cur:sub(1, #oldp + 1) == oldp .. '/'

    -- persist unsaved edits before the rename so they survive the directory move
    -- (after rename oldp is gone; the post-rename open_in_edit write would fail silently)
    if
      inside
      and st.edit_buf
      and api.nvim_buf_is_valid(st.edit_buf)
      and vim.bo[st.edit_buf].buftype == ''
      and vim.bo[st.edit_buf].modified
    then
      api.nvim_buf_call(st.edit_buf, function()
        vim.cmd('silent write')
      end)
    end

    fn.rename(oldp, newp)

    if inside then
      local old_buf = st.edit_buf
      require('notes.ui').open_in_edit(newp .. cur:sub(#oldp + 1))
      if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
        pcall(api.nvim_buf_delete, old_buf, { force = true })
      end
    end

    -- rewrite expanded_folders keys: the renamed folder itself and any descendants
    -- move from the old prefix to the new one
    if st.expanded_folders then
      local rewritten = {}
      for path, v in pairs(st.expanded_folders) do
        if path == f then
          rewritten[newrel] = v
        elseif path:sub(1, #f + 1) == f .. '/' then
          rewritten[newrel .. path:sub(#f + 1)] = v
        else
          rewritten[path] = v
        end
      end
      st.expanded_folders = rewritten
    end

    -- a marked note/folder may live inside the renamed folder too — keep the
    -- pending cut pointed at a path that still exists on disk
    if st.cut and (st.cut == oldp or st.cut:sub(1, #oldp + 1) == oldp .. '/') then
      st.cut = newp .. st.cut:sub(#oldp + 1)
    end
    if st.cut_folder then
      if st.cut_folder == f then
        st.cut_folder = newrel
      elseif st.cut_folder:sub(1, #f + 1) == f .. '/' then
        st.cut_folder = newrel .. st.cut_folder:sub(#f + 1)
      end
    end

    M.populate()
    cursor_to(folder_key(newrel))
    sync()
  end)
end

-- `x`: mark the note or folder under the cursor for moving. A note and a folder
-- can't be marked at the same time; a second `x` on the already-marked item
-- cancels the move. Only the highlight needs to change here (the tree's shape is
-- unaffected), so a lightweight render_tree() is enough — no rescan.
function M.cut()
  local it = item_at_cursor()
  if not it then
    return
  end

  local st = state()
  if it.type == 'note' then
    if is_conflicted(it.file) then
      notify_conflict_block()
      return
    end
    local cancel = st.cut == it.file
    if cancel then
      st.cut = nil
    else
      st.cut = it.file
      st.cut_folder = nil -- a note and a folder can't be marked at the same time
    end
    M.render_tree()
    vim.notify(
      cancel and '[notes.nvim] Move cancelled'
        or ('[notes.nvim] Navigate to a folder and press ' .. cfg().keys.paste)
    )
  else
    if folder_has_conflict(it.path) then
      notify_conflict_block()
      return
    end
    local cancel = st.cut_folder == it.path
    if cancel then
      st.cut_folder = nil
    else
      st.cut_folder = it.path
      st.cut = nil
    end
    M.render_tree()
    vim.notify(
      cancel and '[notes.nvim] Move cancelled'
        or ('[notes.nvim] Navigate to the destination folder and press ' .. cfg().keys.paste)
    )
  end
end

-- Drop the marked note into the context folder.
function M.paste_note()
  local st = state()
  if not st.cut then
    return
  end
  if is_conflicted(st.cut) then
    notify_conflict_block()
    return
  end

  local folder = M.context_folder()
  local dir = cfg().dir
  local target_dir = folder == '' and dir or (dir .. '/' .. folder)
  local src = st.cut
  local target = target_dir .. '/' .. fn.fnamemodify(src, ':t')
  st.cut = nil

  if src == target then
    M.render_tree()
    return
  end

  fn.mkdir(target_dir, 'p')

  -- persist unsaved edits before the rename: open_in_edit writes the editor buffer
  -- under its old name, which after the rename would recreate the note at its old
  -- path (a duplicate). Writing now puts the content in src, which rename moves to
  -- target, and leaves the buffer unmodified so the post-rename write is a no-op.
  if
    st.current_file == src
    and st.edit_buf
    and api.nvim_buf_is_valid(st.edit_buf)
    and vim.bo[st.edit_buf].buftype == ''
    and vim.bo[st.edit_buf].modified
  then
    api.nvim_buf_call(st.edit_buf, function()
      vim.cmd('silent write')
    end)
  end

  fn.rename(src, target)

  -- поднять папку-приёмник наверх: свежесть папки = максимальный mtime её заметок,
  -- а fn.rename сохраняет mtime, поэтому обновляем его на «сейчас» (заодно
  -- перемещённая заметка окажется вверху списка заметок этой папки)
  local now = os.time()
  vim.uv.fs_utime(target, now, now)

  if st.current_file == src then
    local old_buf = st.edit_buf
    require('notes.ui').open_in_edit(target)
    if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
      pcall(api.nvim_buf_delete, old_buf, { force = true })
    end
  end

  expand(folder)
  M.populate()
  cursor_to(note_key(target))
  sync()
end

-- Drop the marked folder into the context folder (or root). Blocked if the marked
-- folder holds a conflict, or if the destination is the folder itself or one of
-- its own descendants (can't nest a folder in itself).
function M.paste_folder()
  local st = state()
  local src = st.cut_folder
  if not src then
    return
  end
  if folder_has_conflict(src) then
    notify_conflict_block()
    return
  end

  local dest = M.context_folder()
  local into_self = dest == src or dest:sub(1, #src + 1) == src .. '/'
  if into_self then
    vim.notify('[notes.nvim] Cannot move a folder into itself', vim.log.levels.WARN)
    return
  end

  local dir = cfg().dir
  local leaf = src:match('[^/]+$')
  local newrel = dest == '' and leaf or (dest .. '/' .. leaf)
  st.cut_folder = nil

  if newrel == src then
    M.render_tree()
    return
  end

  local oldp = dir .. '/' .. src
  local newp = dir .. '/' .. newrel
  if fn.isdirectory(newp) == 1 then
    vim.notify(
      '[notes.nvim] A folder named "' .. leaf .. '" already exists there',
      vim.log.levels.WARN
    )
    return
  end

  local cur = st.current_file
  local inside = cur and cur:sub(1, #oldp + 1) == oldp .. '/'

  -- persist unsaved edits before the rename so they survive the directory move
  if
    inside
    and st.edit_buf
    and api.nvim_buf_is_valid(st.edit_buf)
    and vim.bo[st.edit_buf].buftype == ''
    and vim.bo[st.edit_buf].modified
  then
    api.nvim_buf_call(st.edit_buf, function()
      vim.cmd('silent write')
    end)
  end

  fn.rename(oldp, newp)

  -- fn.rename preserves mtime; bump it so the destination floats to the top of
  -- the tree (folder recency = the newest mtime in its subtree)
  local now = os.time()
  vim.uv.fs_utime(newp, now, now)

  if inside then
    local old_buf = st.edit_buf
    require('notes.ui').open_in_edit(newp .. cur:sub(#oldp + 1))
    if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
      pcall(api.nvim_buf_delete, old_buf, { force = true })
    end
  end

  -- rewrite expanded_folders: the moved folder itself and its descendants move
  -- from the old prefix to the new one
  if st.expanded_folders then
    local rewritten = {}
    for path, v in pairs(st.expanded_folders) do
      if path == src then
        rewritten[newrel] = v
      elseif path:sub(1, #src + 1) == src .. '/' then
        rewritten[newrel .. path:sub(#src + 1)] = v
      else
        rewritten[path] = v
      end
    end
    st.expanded_folders = rewritten
  end
  expand(dest)

  M.populate()
  cursor_to(folder_key(newrel))
  sync()
end

-- `p`: dispatch to paste_folder when a folder is marked, else paste_note.
function M.paste()
  local st = state()
  if st.cut_folder then
    M.paste_folder()
  elseif st.cut then
    M.paste_note()
  end
end

function M.attach_explorer(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('h', '<Nop>', 'Notes: no horizontal move')
  map('l', '<Nop>', 'Notes: no horizontal move')
  map(keys.open_file, M.toggle_expand, 'Notes: expand/collapse folder, or focus editor')
  map(keys.change_folder, M.toggle_expand, 'Notes: expand/collapse folder, or focus editor')
  map(keys.create, M.create_note, 'Notes: create note')
  map(keys.create_folder, M.create_folder, 'Notes: create folder')
  map(keys.delete, M.delete, 'Notes: delete note/folder')
  map(keys.rename, M.rename_folder, 'Notes: rename folder')
  map(keys.move, M.cut, 'Notes: mark note/folder for moving')
  map(keys.paste, M.paste, 'Notes: paste marked note/folder')
  map(keys.scroll_down, function()
    require('notes.ui').scroll_edit(1)
  end, 'Notes: scroll editor down')
  map(keys.scroll_up, function()
    require('notes.ui').scroll_edit(-1)
  end, 'Notes: scroll editor up')
  map(keys.refresh, function()
    M.refresh()
    sync()
  end, 'Notes: refresh and sync')
  map(keys.open_github, function()
    require('notes.git').open_github()
  end, 'Notes: open GitHub')
  map(keys.toggle_panels, function()
    require('notes.ui').toggle_panels()
  end, 'Notes: toggle panels')
  map(keys.close, function()
    require('notes').close_interactive()
  end, 'Notes: close')
end

return M
