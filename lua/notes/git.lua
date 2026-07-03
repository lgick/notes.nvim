-- Async git sync: clone / commit / merge / push via vim.system.
-- Conflict model: a merge conflict is left in the file as standard git markers
-- (repo enters MERGING). The conflicted notes are recorded in state.conflicts so
-- the UI can highlight them; the user resolves the markers in the editor and saves,
-- which completes the merge and pushes. No modal dialogs.

local M = {}

local fn = vim.fn

local function cfg()
  return require('notes').config
end

local function notify(msg, level)
  -- Схлопываем переводы строк: многострочный текст ошибки git (напр. abort'а pull)
  -- иначе переполняет область сообщений и вызывает hit-enter "Press ENTER" prompt.
  msg = msg:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if #msg > 300 then
    msg = msg:sub(1, 300) .. '…'
  end
  vim.schedule(function()
    vim.notify('[notes.nvim] ' .. msg, level or vim.log.levels.INFO)
  end)
end

local function git(args, cwd, cb)
  -- LC_ALL=C forces English git output so our stdout/stderr string matching
  -- ("nothing to commit", "fetch first"/"rejected", …) works under any locale.
  vim.system(
    vim.list_extend({ 'git' }, args),
    { cwd = cwd, text = true, env = { LC_ALL = 'C', LANG = 'C' } },
    function(res)
      vim.schedule(function()
        cb(res)
      end)
    end
  )
end

local function is_repo(dir)
  return fn.isdirectory(dir .. '/.git') == 1
end

-- A merge is in progress while .git/MERGE_HEAD exists.
local function merging(dir)
  return vim.uv.fs_stat(dir .. '/.git/MERGE_HEAD') ~= nil
end

-- True while the file still contains unresolved conflict markers.
local function has_markers(file)
  local ok, lines = pcall(fn.readfile, file)
  if not ok then
    return false
  end
  for _, l in ipairs(lines) do
    if
      l:match('^<<<<<<< ')
      or l:match('^=======$')
      or l:match('^>>>>>>> ')
      or l:match('^||||||| ')
    then
      return true
    end
  end
  return false
end

-- A human label for a conflicted note: "folder/title" where folder is "Notes" for
-- root notes or the subdirectory name, and title is the first real content line.
local function conflict_label(path)
  local dir = cfg().dir
  local parent = fn.fnamemodify(path, ':h')
  local folder = (parent == dir) and 'Notes' or fn.fnamemodify(parent, ':t')

  local ok, lines = pcall(fn.readfile, path, '', 50)
  if ok then
    for _, l in ipairs(lines) do
      local t = vim.trim(l)
      if
        t ~= ''
        and not t:match('^<<<<<<<')
        and not t:match('^=======')
        and not t:match('^>>>>>>>')
        and not t:match('^|||||||')
      then
        return folder .. '/' .. t
      end
    end
  end
  return folder .. '/' .. fn.fnamemodify(path, ':t')
end

local function notify_conflict(paths)
  local labels = {}
  for _, p in ipairs(paths) do
    labels[#labels + 1] = conflict_label(p)
  end
  notify(
    'Conflict in: ' .. table.concat(labels, ', ') .. ' — edit and save to resolve',
    vim.log.levels.WARN
  )
end

-- Refresh state.conflicts from git's unmerged-files list. Paths from git are
-- relative to the repo root; we store absolute paths so they match note.file.
-- -z avoids path quoting (needed for non-ASCII/spaces). cb receives the set.
local function update_conflicts(dir, cb)
  git({ 'diff', '--name-only', '--diff-filter=U', '-z' }, dir, function(res)
    local set = {}
    if res.code == 0 and res.stdout then
      for _, rel in ipairs(vim.split(res.stdout, '\0', { trimempty = true })) do
        set[dir .. '/' .. rel] = true
      end
    end
    require('notes').state.conflicts = next(set) and set or nil
    cb(set)
  end)
end

function M.ensure_repo(cb)
  local dir = cfg().dir

  if is_repo(dir) then
    cb()
    return
  end

  local repo = cfg().repo
  if repo == '' then
    -- no remote configured: just create the directory
    fn.mkdir(dir, 'p')
    cb()
    return
  end

  local parent = fn.fnamemodify(dir, ':h')
  fn.mkdir(parent, 'p')
  notify('Cloning repository…')

  git({ 'clone', repo, dir }, parent, function(res)
    if res.code == 0 then
      notify('Repository cloned')
    else
      notify('Clone failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
    end
    cb()
  end)
end

-- Restores tracked files deleted outside the plugin (e.g. accidental `rm`).
-- The plugin commits all its own edits, so an uncommitted deletion at open time
-- is accidental and must be recovered from the last commit. Modified-but-present
-- files are left untouched. -z suppresses path quoting (needed for non-ASCII/spaces).
-- Skipped while a merge is in progress: checking out files would corrupt the
-- unmerged index entries.
function M.restore(cb)
  local c = cfg()

  if not is_repo(c.dir) or merging(c.dir) then
    cb()
    return
  end

  require('notes.ui').set_sync_status('syncing')

  git({ 'ls-files', '--deleted', '-z' }, c.dir, function(res)
    local out = res.stdout or ''
    if res.code ~= 0 or out == '' then
      cb()
      return
    end

    local files = vim.split(out, '\0', { trimempty = true })
    git(vim.list_extend({ 'checkout', '--' }, files), c.dir, function(co_res)
      if co_res.code == 0 then
        notify('Restored ' .. #files .. ' file(s) from last commit')
      end
      cb()
    end)
  end)
end

-- Pull on open: merge (not rebase), so a conflict stays as markers in the file
-- instead of leaving the repo mid-rebase. Skips if the remote has no branches yet.
function M.pull(cb)
  local c = cfg()

  if not is_repo(c.dir) then
    cb()
    return
  end

  -- a merge left unresolved from a previous session: surface it, let the user resolve
  if merging(c.dir) then
    update_conflicts(c.dir, function(set)
      if next(set) then
        notify_conflict(vim.tbl_keys(set))
      end
      cb()
    end)
    return
  end

  require('notes.ui').set_sync_status('syncing')

  git({ 'ls-remote', '--heads', 'origin' }, c.dir, function(ls_res)
    if ls_res.code ~= 0 or not ls_res.stdout or ls_res.stdout == '' then
      cb()
      return
    end

    -- Commit local changes before merging so a conflict becomes a real MERGE_HEAD
    -- merge (markers + MERGE_HEAD), which the resolve flow handles. The old
    -- --autostash could instead leave a stash-pop conflict — markers with NO
    -- MERGE_HEAD — which merging() can't see, so the next sync_on_exit would blindly
    -- `git add -A` and commit (even push) the marker file. ("nothing to commit"
    -- here is fine: there was nothing local to save.) --no-edit skips the editor.
    git({ 'add', '-A' }, c.dir, function()
      git({ 'commit', '-m', 'notes: ' .. os.date('%Y-%m-%d %H:%M') }, c.dir, function()
        git({ 'pull', '--no-rebase', '--no-edit' }, c.dir, function(res)
          update_conflicts(c.dir, function(set)
            if next(set) then
              notify_conflict(vim.tbl_keys(set))
              -- sync_on_exit won't run (MERGE_HEAD present); set status here
              require('notes.ui').set_sync_status('conflict')
            elseif res.code ~= 0 then
              notify('Pull failed: ' .. (res.stderr or ''), vim.log.levels.WARN)
            end
            cb()
          end)
        end)
      end)
    end)
  end)
end

-- Exposed for unit tests (mirrors repo_url export pattern).
M.conflict_label = conflict_label

-- git@github.com:user/repo.git / ssh://git@host/… / https://…  →  https://host/user/repo
function M.repo_url(repo)
  local url = repo
    :gsub('^git@([^:]+):', 'https://%1/')
    :gsub('^ssh://git@', 'https://')
    :gsub('%.git$', '')
  return url
end

function M.open_github()
  local repo = cfg().repo
  if repo == '' then
    notify('No repo configured', vim.log.levels.WARN)
    return
  end

  vim.ui.open(M.repo_url(repo))
end

-- Serialise concurrent calls: if a sync is already running, set pending and
-- re-run once it finishes. This prevents the push race that occurs when rapid
-- CRUD operations each trigger sync_on_exit() before the first push completes.
local syncing = false
local sync_pending = false

function M.sync_on_exit()
  local c = cfg()

  if not is_repo(c.dir) then
    return
  end

  if syncing then
    sync_pending = true
    return
  end
  syncing = true
  require('notes.ui').set_sync_status('syncing')

  local function finish()
    syncing = false
    if sync_pending then
      sync_pending = false
      M.sync_on_exit()
    else
      local notes = require('notes')
      if notes.is_open() then
        require('notes.picker').refresh()
        local st = notes.state
        require('notes.ui').set_sync_status(st.conflicts and 'conflict' or 'idle')
      end
      -- one-shot completion hook fired only at true idle (no pending sync);
      -- used by the test suite to await the async chain
      if M._on_idle then
        local cb = M._on_idle
        M._on_idle = nil
        cb()
      end
    end
  end

  -- forward declarations: do_push ↔ do_resolve ↔ commit_only reference each other
  local do_push, do_resolve, commit_only

  -- stage everything and commit; "nothing to commit" is a non-error → cb()
  commit_only = function(cb)
    git({ 'add', '-A' }, c.dir, function(add_res)
      if add_res.code ~= 0 then
        notify('git add failed: ' .. (add_res.stderr or ''), vim.log.levels.ERROR)
        finish()
        return
      end
      local msg = 'notes: ' .. os.date('%Y-%m-%d %H:%M')
      git({ 'commit', '-m', msg }, c.dir, function(commit_res)
        if commit_res.code ~= 0 then
          local out = (commit_res.stdout or '') .. (commit_res.stderr or '')
          if out:find('nothing to commit') or out:find('nothing added to commit') then
            cb()
            return
          end
          notify('git commit failed: ' .. (commit_res.stderr or ''), vim.log.levels.ERROR)
          finish()
          return
        end
        cb()
      end)
    end)
  end

  -- self-healing push: a reject means the remote advanced after our last sync.
  -- Merge it in and retry once. Guarded by pushed_retry so we never loop.
  local pushed_retry = false
  do_push = function()
    require('notes').state.conflicts = nil
    git({ 'push', '-u', 'origin', 'HEAD' }, c.dir, function(res)
      if res.code == 0 then
        notify('Synced (pushed)')
        finish()
        return
      end

      local err = res.stderr or ''
      local rejected = err:find('fetch first')
        or err:find('non%-fast%-forward')
        or err:find('rejected')
      if rejected and not pushed_retry then
        pushed_retry = true
        git({ 'pull', '--no-rebase', '--no-edit' }, c.dir, function(pull_res)
          update_conflicts(c.dir, function(set)
            if next(set) or pull_res.code == 0 then
              do_resolve()
            else
              notify('Push failed: ' .. (pull_res.stderr or ''), vim.log.levels.ERROR)
              finish()
            end
          end)
        end)
        return
      end

      notify('Push failed: ' .. err, vim.log.levels.ERROR)
      finish()
    end)
  end

  -- After a merge (or while one is in progress): if any conflicted file still has
  -- markers, stop and let the user resolve it. Otherwise stage all resolutions
  -- (incl. modify/delete files kept as-is) and commit the merge, then push.
  do_resolve = function()
    update_conflicts(c.dir, function(set)
      local markers = {}
      for path in pairs(set) do
        if has_markers(path) then
          markers[#markers + 1] = path
        end
      end
      if #markers > 0 then
        notify_conflict(markers)
        finish()
        return
      end
      commit_only(do_push)
    end)
  end

  -- Route to the resolve flow when the index has any unmerged entry: a normal
  -- MERGE_HEAD merge (e.g. a save that resolved markers), OR a stash-pop conflict
  -- (markers but NO MERGE_HEAD) that merging() alone can't detect. do_resolve stops
  -- if any conflicted file still has markers, so the marker file is never committed.
  update_conflicts(c.dir, function(set)
    if merging(c.dir) or next(set) then
      do_resolve()
      return
    end

    -- normal path: commit local edits, merge remote, then resolve/push
    commit_only(function()
      git({ 'ls-remote', '--heads', 'origin' }, c.dir, function(ls_res)
        if ls_res.code ~= 0 or not ls_res.stdout or ls_res.stdout == '' then
          -- no remote branches yet (fresh repo): push our commit and set upstream
          do_push()
          return
        end
        git({ 'pull', '--no-rebase', '--no-edit' }, c.dir, function()
          do_resolve()
        end)
      end)
    end)
  end)
end

return M
