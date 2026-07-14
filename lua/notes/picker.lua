-- Two-pane model (macOS Notes style): folders column + notes column.
-- Notes are ID-named files; the title is the first non-blank line of their content.

local M = {}

local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('notes_list')
local ns_active = api.nvim_create_namespace('notes_active')
local ns_folders = api.nvim_create_namespace('notes_folders')
local ns_title = api.nvim_create_namespace('notes_title')
local ns_conflict = api.nvim_create_namespace('notes_conflict')

local EMPTY_TITLE = 'New Note'
local ROOT_LABEL = 'Notes' -- virtual folder for notes that live at the repo root

-- Relative paths of every real folder at any depth from the last scan() ("Work",
-- "Work/Projects"). Module-local: build_folders() derives the visible drill-down
-- level from it; not part of the documented state.
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

-- True when any note inside `folder` (relative path, any depth) OR any of its
-- descendants is in a merge conflict. `folder == nil` means the root "Notes" main
-- row, which covers the whole tree (root is the ancestor of every folder).
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
-- (all_folders); build_folders() later derives the visible drill-down level from
-- the latter. Hidden entries (.git, .gitkeep) are skipped.
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
-- top among its siblings. Third return is the recursive note count for the same
-- subtree (empty notes included), used by build_folders() for the "[N]" badge.
local function folder_recursive_mtime(folder_rel)
  local max_mtime = 0
  local cnt = 0
  for _, n in ipairs(state().notes_all or {}) do
    if n.folder == folder_rel or n.folder:sub(1, #folder_rel + 1) == folder_rel .. '/' then
      max_mtime = math.max(max_mtime, n.mtime)
      cnt = cnt + 1
    end
  end
  if cnt > 0 then
    return max_mtime, true, cnt
  end
  local s = vim.uv.fs_stat(cfg().dir .. '/' .. folder_rel)
  return s and s.mtime.sec or 0, false, 0
end

-- Builds the visible drill-down level of the folders column from all_folders:
-- row 1 is the current level (main_folder, nil = root "Notes"), followed by its
-- immediate children sorted by recursive freshness (same strict tie-break as
-- before: freshness → note-bearing → name, since table.sort is not stable).
function M.build_folders()
  local main = state().main_folder
  local folders = {
    { name = main and main:match('[^/]+$') or ROOT_LABEL, folder = main, is_main = true },
  }

  local prefix = main and (main .. '/') or ''
  local children = {}
  for _, f in ipairs(all_folders) do
    if main == nil then
      if not f:find('/') then
        children[#children + 1] = f
      end
    elseif f:sub(1, #prefix) == prefix and not f:sub(#prefix + 1):find('/') then
      children[#children + 1] = f
    end
  end

  local fm, has_note, count = {}, {}, {}
  for _, f in ipairs(children) do
    fm[f], has_note[f], count[f] = folder_recursive_mtime(f)
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

  for _, f in ipairs(children) do
    folders[#folders + 1] =
      { name = f:match('[^/]+$'), folder = f, is_main = false, count = count[f] }
  end

  state().folders = folders
end

-- If the drill-down level or the selected folder vanished (deleted/renamed), fall
-- back up. Checked against disk, not state.folders: the folders column only shows
-- one level at a time, so a stale current_folder from a different branch of the
-- tree would not be found there even though it still exists.
local function validate_folder()
  local st = state()
  local dir = cfg().dir
  if st.main_folder and fn.isdirectory(dir .. '/' .. st.main_folder) == 0 then
    st.main_folder, st.current_folder = nil, nil
    return
  end
  if st.current_folder and fn.isdirectory(dir .. '/' .. st.current_folder) == 0 then
    st.current_folder = st.main_folder
  end
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

-- Truncates s from the left with a leading '…' so its tail (the current folder's
-- name) stays visible within width, instead of Neovim's default right-truncation
-- (which would hide the name at deep nesting). No-op if s already fits.
local function fit_left(s, width)
  if fn.strdisplaywidth(s) <= width then
    return s
  end
  local total = fn.strchars(s)
  for drop = 1, total - 1 do
    local tail = fn.strcharpart(s, drop, total - drop)
    if fn.strdisplaywidth('…' .. tail) <= width then
      return '…' .. tail
    end
  end
  return '…'
end

function M.render_folders()
  local st = state()
  if not (st.folders_buf and api.nvim_buf_is_valid(st.folders_buf)) then
    return
  end

  local width = (st.folders_win and api.nvim_win_is_valid(st.folders_win))
      and api.nvim_win_get_width(st.folders_win)
    or cfg().folders_width

  local lines = {}
  local folders = st.folders or {}
  local n = #folders
  for i, f in ipairs(folders) do
    local line
    if f.is_main then
      -- root → "Notes/"; drilled-in level → "Notes/<path>/ .." ('..' hints `o` = up)
      line = f.folder and (ROOT_LABEL .. '/' .. f.folder .. '/ ..') or (ROOT_LABEL .. '/')
      line = fit_left(line, width)
    elseif i == n then
      line = '└─ ' .. f.name .. '[' .. f.count .. ']/'
    else
      line = '├─ ' .. f.name .. '[' .. f.count .. ']/'
    end
    lines[#lines + 1] = line
  end

  vim.bo[st.folders_buf].modifiable = true
  api.nvim_buf_set_lines(st.folders_buf, 0, -1, false, lines)
  vim.bo[st.folders_buf].modifiable = false

  api.nvim_buf_clear_namespace(st.folders_buf, ns_folders, 0, -1)
  api.nvim_buf_clear_namespace(st.folders_buf, ns_conflict, 0, -1)
  api.nvim_buf_clear_namespace(st.folders_buf, ns, 0, -1)
  for i, f in ipairs(folders) do
    -- hl_group (not line_hl_group) with a low priority: line_hl_group is a separate
    -- rendering layer that would override hl_group (NotesCut, NotesConflict)
    -- regardless of priority, hiding them on the selected/cut row. hl_group lets
    -- priority ordering apply instead.
    api.nvim_buf_set_extmark(
      st.folders_buf,
      ns_folders,
      i - 1,
      0,
      { end_col = #lines[i], hl_group = 'NotesDir', priority = 0 }
    )
    if folder_has_conflict(f.folder) then
      api.nvim_buf_set_extmark(st.folders_buf, ns_conflict, i - 1, 0, {
        end_col = #lines[i],
        hl_group = 'NotesConflict',
        hl_mode = 'combine',
        priority = 300,
      })
    end
    if f.folder ~= nil and f.folder == st.cut_folder then
      -- hl_group over the text only (not full width); priority > NotesDir/Active (0)
      api.nvim_buf_set_extmark(
        st.folders_buf,
        ns,
        i - 1,
        0,
        { end_col = #lines[i], hl_group = 'NotesCut', priority = 200 }
      )
    end
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
        -- hl_group (same layer as NotesCut) so priority 0 reliably loses to NotesCut's 200.
        -- line_hl_group is a separate rendering layer and would override hl_group regardless of priority.
        local line = api.nvim_buf_get_lines(st.list_buf, i - 1, i, false)[1] or ''
        api.nvim_buf_set_extmark(
          st.list_buf,
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
  api.nvim_buf_clear_namespace(st.list_buf, ns_title, 0, -1)
  api.nvim_buf_clear_namespace(st.list_buf, ns_conflict, 0, -1)
  if not empty then
    local prefix = 13 -- len("dd.mm.yyyy - ")
    for i, it in ipairs(st.items) do
      api.nvim_buf_set_extmark(st.list_buf, ns_title, i - 1, prefix, {
        end_col = #lines[i],
        hl_group = 'NotesTitle',
        hl_mode = 'combine',
        priority = 100,
      })
      if is_conflicted(it.file) then
        -- wavy error underline over the row text; combine so it overlays the title
        -- color/bold rather than replacing them, priority above Title/Active/Cut
        api.nvim_buf_set_extmark(st.list_buf, ns_conflict, i - 1, 0, {
          end_col = #lines[i],
          hl_group = 'NotesConflict',
          hl_mode = 'combine',
          priority = 300,
        })
      end
      if it.file == st.cut then
        -- hl_group over the text only (not full width); priority > NotesActive (0)
        api.nvim_buf_set_extmark(
          st.list_buf,
          ns,
          i - 1,
          0,
          { end_col = #lines[i], hl_group = 'NotesCut', priority = 200 }
        )
      end
    end
  end

  -- Ставим курсор на активную заметку (current_file), а не жёстко на строку 1:
  -- фоновые ре-рендеры (git-синхронизация по завершении, BufWritePost) иначе
  -- перебрасывали бы курсор наверх и авто-открывали верхнюю заметку. Если открытой
  -- заметки нет в текущем списке (первый показ, смена папки) — строка 1.
  if st.list_win and api.nvim_win_is_valid(st.list_win) and not empty then
    local row = 1
    if st.current_file then
      for i, it in ipairs(st.items) do
        if it.file == st.current_file then
          row = i
          break
        end
      end
    end
    api.nvim_win_set_cursor(st.list_win, { row, 0 })
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
  require('notes.ui').refresh_editor_statusline()
end

function M.populate()
  M.scan()
  validate_folder()
  M.build_folders()
  M.filter()
  M.render_folders()
  M.render_notes()
  require('notes.ui').refresh_editor_statusline()
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

-- `<CR>` in the folders column: on a child row, drill into it (same as `o`) and move
-- focus to the notes column; on the main row, keep the level unchanged (unlike `o`,
-- which goes up) and just move focus to the notes column.
function M.select_folder()
  local f = selected_folder()
  if not f then
    return
  end
  if not f.is_main then
    M.change_folder()
  end
  local st = state()
  if st.list_win and api.nvim_win_is_valid(st.list_win) then
    api.nvim_set_current_win(st.list_win)
  end
end

-- `<CR>` in the notes column: open the note under the cursor (if not already open)
-- and move focus to the editor.
function M.select_note()
  M.open_selected()
  local st = state()
  if st.edit_win and api.nvim_win_is_valid(st.edit_win) then
    api.nvim_set_current_win(st.edit_win)
  end
end

-- `o` in the folders column: drill-down navigation. On the main row (row 1), go up
-- one level (no-op at the true root); on a child row, enter that folder.
function M.change_folder()
  local f = selected_folder()
  if not f then
    return
  end
  local st = state()
  if f.is_main then
    if st.main_folder == nil then
      return
    end
    local parent = st.main_folder:match('^(.*)/[^/]+$')
    st.main_folder = parent
    st.current_folder = parent
  else
    st.main_folder = f.folder
    st.current_folder = f.folder
  end
  M.populate()
  if st.folders_win and api.nvim_win_is_valid(st.folders_win) then
    api.nvim_win_set_cursor(st.folders_win, { 1, 0 })
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
  -- open first, then populate: render_notes puts the cursor on current_file, so the
  -- new (empty, pinned-top) note becomes the one the cursor lands on
  require('notes.ui').open_in_edit(target)
  M.populate()
  sync()
end

-- New folder is created as a child of the current drill-down level (main_folder).
-- A single leaf name is expected per call: '/' is rejected (deeper nesting is
-- reached by drilling in with `o` and creating again).
function M.create_folder()
  vim.ui.input({ prompt = 'New folder: ' }, function(input)
    if not input or input == '' then
      return
    end
    if input:find('[/\\]') then
      vim.notify('[notes.nvim] Folder name cannot contain "/" or "\\"', vim.log.levels.WARN)
      return
    end
    local main = state().main_folder
    local rel = main and (main .. '/' .. input) or input
    local path = cfg().dir .. '/' .. rel
    fn.mkdir(path, 'p')
    -- .gitkeep lets an otherwise empty folder be committed and synced
    fn.writefile({}, path .. '/.gitkeep')
    M.populate()
    sync()
  end)
end

-- Rename works on the main row (the folder currently drilled into) or a child row;
-- only the true root "Notes" (folder == nil) is rejected. The new name is a single
-- leaf; the folder's parent path is unchanged.
function M.rename_folder()
  local f = selected_folder()
  if not f or f.folder == nil then
    vim.notify('[notes.nvim] Select a folder to rename', vim.log.levels.WARN)
    return
  end

  local leaf = f.folder:match('[^/]+$')
  vim.ui.input({ prompt = 'Rename folder: ', default = leaf }, function(input)
    if not input or input == '' or input == leaf then
      return
    end
    if input:find('[/\\]') then
      vim.notify('[notes.nvim] Folder name cannot contain "/" or "\\"', vim.log.levels.WARN)
      return
    end
    if folder_has_conflict(f.folder) then
      notify_conflict_block()
      return
    end
    local dir = cfg().dir
    local parent = f.folder:match('^(.*)/[^/]+$')
    local newrel = parent and (parent .. '/' .. input) or input
    local oldp = dir .. '/' .. f.folder
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

    -- current_folder/main_folder may point at the renamed folder itself or at one
    -- of its descendants (we could be drilled several levels below it); rewrite
    -- the f.folder prefix to newrel in both so navigation stays consistent
    local function rewrite_prefix(path)
      if path == nil then
        return nil
      end
      if path == f.folder then
        return newrel
      end
      if path:sub(1, #f.folder + 1) == f.folder .. '/' then
        return newrel .. path:sub(#f.folder + 1)
      end
      return path
    end
    st.current_folder = rewrite_prefix(st.current_folder)
    st.main_folder = rewrite_prefix(st.main_folder)

    -- a marked note/folder may live inside the renamed folder too — keep the
    -- pending cut pointed at a path that still exists on disk
    if st.cut and (st.cut == oldp or st.cut:sub(1, #oldp + 1) == oldp .. '/') then
      st.cut = newp .. st.cut:sub(#oldp + 1)
    end
    st.cut_folder = rewrite_prefix(st.cut_folder)

    M.populate()
    sync()
  end)
end

function M.delete_note()
  local it = selected_note()
  if not it then
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
  local f = selected_folder()
  if not f or f.folder == nil then
    vim.notify('[notes.nvim] Select a folder to delete', vim.log.levels.WARN)
    return
  end

  if folder_has_conflict(f.folder) then
    notify_conflict_block()
    return
  end
  local prompt = 'Delete folder "' .. f.folder .. '" and all its notes?'
  if fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
    return
  end
  local path = cfg().dir .. '/' .. f.folder
  local st = state()
  local cur = st.current_file
  if cur and (cur == path or cur:sub(1, #path + 1) == path .. '/') then
    require('notes.ui').show_placeholder()
  end
  fn.delete(path, 'rf')

  local function inside_deleted(p)
    return p ~= nil and (p == f.folder or p:sub(1, #f.folder + 1) == f.folder .. '/')
  end
  if inside_deleted(st.main_folder) then
    -- the drilled-into level itself (or an ancestor of it) was deleted → go up to
    -- its parent, which still exists
    st.main_folder = f.folder:match('^(.*)/[^/]+$')
    st.current_folder = st.main_folder
  elseif inside_deleted(st.current_folder) then
    st.current_folder = st.main_folder
  end

  -- a marked note/folder may have been inside the deleted subtree — clear the
  -- pending cut so paste doesn't try to move a now-nonexistent path
  if st.cut and (st.cut == path or st.cut:sub(1, #path + 1) == path .. '/') then
    st.cut = nil
  end
  if inside_deleted(st.cut_folder) then
    st.cut_folder = nil
  end

  M.populate()
  sync()
end

-- Mark the selected note for moving; focus stays in the notes column.
function M.cut_note()
  local it = selected_note()
  if not it then
    return
  end
  if is_conflicted(it.file) then
    notify_conflict_block()
    return
  end
  local st = state()
  -- второе нажатие x на уже помеченной заметке отменяет перемещение
  -- (без idiom `and/or`: nil ложно и сломал бы ветку отмены)
  local cancel = st.cut == it.file
  local had_cut_folder = st.cut_folder ~= nil
  if cancel then
    st.cut = nil
  else
    st.cut = it.file
    st.cut_folder = nil -- a note and a folder can't be marked for moving at the same time
  end

  -- render_notes сбрасывает курсор на строку 1; при пометке список не меняется,
  -- поэтому сохраняем позицию и возвращаем её, чтобы остаться на выделенной заметке
  local pos = (st.list_win and api.nvim_win_is_valid(st.list_win))
      and api.nvim_win_get_cursor(st.list_win)
    or nil
  M.render_notes()
  if pos then
    pcall(api.nvim_win_set_cursor, st.list_win, pos)
  end
  if had_cut_folder then
    -- a previously marked folder just got cleared above; without this the
    -- folders column would keep showing its stale NotesCut highlight
    M.render_folders()
  end

  vim.notify(
    cancel and '[notes.nvim] Move cancelled'
      or ('[notes.nvim] Navigate to a folder and press ' .. cfg().keys.paste)
  )
end

-- Mark the selected folder for moving. Only a child row can be marked — the main
-- row (the folder currently drilled into, or the true root) cannot be moved from
-- inside itself. The user then navigates within the folders column (drill in/out,
-- move the cursor) to the destination and presses `paste`.
function M.cut_folder()
  local f = selected_folder()
  if not f or f.is_main then
    vim.notify('[notes.nvim] Cannot move the current folder from inside it', vim.log.levels.WARN)
    return
  end
  if folder_has_conflict(f.folder) then
    notify_conflict_block()
    return
  end
  local st = state()
  -- second press on the already-marked folder cancels the move
  local cancel = st.cut_folder == f.folder
  local had_cut = st.cut ~= nil
  if cancel then
    st.cut_folder = nil
  else
    st.cut_folder = f.folder
    st.cut = nil -- a note and a folder can't be marked for moving at the same time
  end

  local pos = (st.folders_win and api.nvim_win_is_valid(st.folders_win))
      and api.nvim_win_get_cursor(st.folders_win)
    or nil
  M.render_folders()
  if pos then
    pcall(api.nvim_win_set_cursor, st.folders_win, pos)
  end
  if had_cut then
    -- a previously marked note just got cleared above; without this the notes
    -- column would keep showing its stale NotesCut highlight
    M.render_notes()
  end

  vim.notify(
    cancel and '[notes.nvim] Move cancelled'
      or ('[notes.nvim] Navigate to the destination folder and press ' .. cfg().keys.paste)
  )
end

-- p in the folders column: drop the marked folder into the selected folder (or
-- root). Blocked if the marked folder holds a conflict, or if the destination is
-- the folder itself or one of its own descendants (can't nest a folder in itself).
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

  local f = selected_folder()
  if not f then
    return
  end
  local dest = f.folder -- nil = root
  local into_self = dest ~= nil and (dest == src or dest:sub(1, #src + 1) == src .. '/')
  if into_self then
    vim.notify('[notes.nvim] Cannot move a folder into itself', vim.log.levels.WARN)
    return
  end

  local dir = cfg().dir
  local leaf = src:match('[^/]+$')
  local newrel = dest and (dest .. '/' .. leaf) or leaf
  st.cut_folder = nil

  if newrel == src then
    M.render_folders()
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
  -- the folders column (folder recency = the newest mtime in its subtree)
  local now = os.time()
  vim.uv.fs_utime(newp, now, now)

  if inside then
    local old_buf = st.edit_buf
    require('notes.ui').open_in_edit(newp .. cur:sub(#oldp + 1))
    if old_buf and old_buf ~= st.edit_buf and api.nvim_buf_is_valid(old_buf) then
      pcall(api.nvim_buf_delete, old_buf, { force = true })
    end
  end

  -- drill into the destination so its children (including the moved folder) show
  st.main_folder = dest
  st.current_folder = dest
  M.populate()

  if st.folders_win and api.nvim_win_is_valid(st.folders_win) then
    for i, folder in ipairs(st.folders or {}) do
      if folder.folder == newrel then
        api.nvim_win_set_cursor(st.folders_win, { i, 0 })
        break
      end
    end
  end

  sync()
end

-- p in the folders column: drop the marked note into the selected folder, or (if
-- a folder is marked instead) dispatch to paste_folder.
function M.paste_note()
  local st = state()
  if st.cut_folder then
    M.paste_folder()
    return
  end
  if not st.cut then
    return
  end
  if is_conflicted(st.cut) then
    notify_conflict_block()
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

  -- проваливаемся (drill-down) в папку-приёмник: её заметки заполняют колонку
  -- Notes, а с обновлённым mtime она стоит первой среди своих соседей
  st.main_folder = f.folder
  st.current_folder = f.folder
  M.populate()

  if st.folders_win and api.nvim_win_is_valid(st.folders_win) then
    api.nvim_win_set_cursor(st.folders_win, { 1, 0 })
  end

  sync()
end

function M.attach_folders(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('h', '<Nop>', 'Notes: no horizontal move')
  map('l', '<Nop>', 'Notes: no horizontal move')
  map(keys.paste, M.paste_note, 'Notes: paste note into folder')
  map(keys.move, M.cut_folder, 'Notes: mark folder for moving')
  map(keys.create, M.create_folder, 'Notes: create folder')
  map(keys.rename, M.rename_folder, 'Notes: rename folder')
  map(keys.delete, M.delete_folder, 'Notes: delete folder')
  map(keys.change_folder, M.change_folder, 'Notes: enter/up folder')
  map(keys.select, M.select_folder, 'Notes: enter folder / focus notes')
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

function M.attach_notes(buf)
  local keys = cfg().keys
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('h', '<Nop>', 'Notes: no horizontal move')
  map('l', '<Nop>', 'Notes: no horizontal move')
  map(keys.create, M.create_note, 'Notes: create note')
  map(keys.delete, M.delete_note, 'Notes: delete note')
  map(keys.move, M.cut_note, 'Notes: move note')
  map(keys.select, M.select_note, 'Notes: focus editor')
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
