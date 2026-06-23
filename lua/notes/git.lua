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

-- Pull uses the upstream set by clone, no explicit branch needed
function M.pull(cb)
  local c = cfg()

  if not is_repo(c.dir) then
    cb()
    return
  end

  git({ 'pull', '--rebase' }, c.dir, function(res)
    if res.code ~= 0 then
      notify('Pull failed: ' .. (res.stderr or ''), vim.log.levels.WARN)
    end
    cb()
  end)
end

function M.sync_on_exit()
  local c = cfg()

  if not is_repo(c.dir) then
    return
  end

  git({ 'status', '--porcelain' }, c.dir, function(res)
    if res.code ~= 0 or not res.stdout or res.stdout == '' then
      return
    end

    git({ 'add', '-A' }, c.dir, function(add_res)
      if add_res.code ~= 0 then
        notify('git add failed: ' .. (add_res.stderr or ''), vim.log.levels.ERROR)
        return
      end

      local msg = 'notes: ' .. os.date('%Y-%m-%d %H:%M')

      git({ 'commit', '-m', msg }, c.dir, function(commit_res)
        if commit_res.code ~= 0 then
          notify('git commit failed: ' .. (commit_res.stderr or ''), vim.log.levels.ERROR)
          return
        end

        git({ 'push' }, c.dir, function(push_res)
          if push_res.code == 0 then
            notify('Synced (pushed)')
          else
            notify('Push failed: ' .. (push_res.stderr or ''), vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  end)
end

return M
