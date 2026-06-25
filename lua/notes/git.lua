-- Async git sync: clone / pull / commit / push via vim.system

local M = {}

local fn = vim.fn

local function cfg()
  return require('notes').config
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify('[notes.nvim] ' .. msg, level or vim.log.levels.INFO)
  end)
end

local function git(args, cwd, cb)
  vim.system(vim.list_extend({ 'git' }, args), { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
end

local function is_repo(dir)
  return fn.isdirectory(dir .. '/.git') == 1
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
function M.restore(cb)
  local c = cfg()

  if not is_repo(c.dir) then
    cb()
    return
  end

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

-- Pull uses the upstream set by clone, no explicit branch needed.
-- Skips silently if the remote has no branches yet (freshly created repo).
function M.pull(cb)
  local c = cfg()

  if not is_repo(c.dir) then
    cb()
    return
  end

  git({ 'ls-remote', '--heads', 'origin' }, c.dir, function(ls_res)
    if ls_res.code ~= 0 or not ls_res.stdout or ls_res.stdout == '' then
      cb()
      return
    end

    -- --autostash: stash local uncommitted edits before rebase, restore after;
    -- without it pull fails on a dirty working tree
    git({ 'pull', '--rebase', '--autostash' }, c.dir, function(res)
      if res.code ~= 0 then
        notify('Pull failed: ' .. (res.stderr or ''), vim.log.levels.WARN)
      end
      cb()
    end)
  end)
end

-- git@github.com:user/repo.git / ssh://git@host/… / https://…  →  https://host/user/repo
function M.open_github()
  local repo = cfg().repo
  if repo == '' then
    notify('No repo configured', vim.log.levels.WARN)
    return
  end

  local url = repo
    :gsub('^git@([^:]+):', 'https://%1/')
    :gsub('^ssh://git@', 'https://')
    :gsub('%.git$', '')

  vim.ui.open(url)
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

  local function finish()
    syncing = false
    if sync_pending then
      sync_pending = false
      M.sync_on_exit()
    end
  end

  -- use -u origin HEAD to handle missing upstream on first push
  local function do_push()
    git({ 'push', '-u', 'origin', 'HEAD' }, c.dir, function(push_res)
      if push_res.code == 0 then
        notify('Synced (pushed)')
      else
        notify('Push failed: ' .. (push_res.stderr or ''), vim.log.levels.ERROR)
      end
      finish()
    end)
  end

  local function commit_and_push()
    git({ 'add', '-A' }, c.dir, function(add_res)
      if add_res.code ~= 0 then
        notify('git add failed: ' .. (add_res.stderr or ''), vim.log.levels.ERROR)
        finish()
        return
      end

      local msg = 'notes: ' .. os.date('%Y-%m-%d %H:%M')

      git({ 'commit', '-m', msg }, c.dir, function(commit_res)
        if commit_res.code ~= 0 then
          notify('git commit failed: ' .. (commit_res.stderr or ''), vim.log.levels.ERROR)
          finish()
          return
        end

        do_push()
      end)
    end)
  end

  -- check uncommitted changes
  git({ 'status', '--porcelain' }, c.dir, function(status_res)
    local has_changes = status_res.code == 0
      and status_res.stdout
      and status_res.stdout ~= ''

    if has_changes then
      commit_and_push()
      return
    end

    -- check unpushed commits (also covers missing upstream: rev-list returns non-zero)
    git({ 'rev-list', '@{u}..HEAD', '--count' }, c.dir, function(ahead_res)
      local trimmed = ((ahead_res.stdout or ''):gsub('%s+', ''))
      local ahead = tonumber(trimmed)
      -- ahead_res.code ~= 0 means no upstream → push anyway
      if ahead_res.code ~= 0 or (ahead and ahead > 0) then
        do_push()
      else
        finish()
      end
    end)
  end)
end

return M
