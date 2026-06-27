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
        -- a rebase conflict leaves the repo mid-rebase; abort so the next
        -- sync_on_exit does not commit on top of a broken rebase state
        git({ 'rebase', '--abort' }, c.dir, function()
          notify('Pull failed: ' .. (res.stderr or ''), vim.log.levels.WARN)
          cb()
        end)
        return
      end
      cb()
    end)
  end)
end

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

  local function finish()
    syncing = false
    if sync_pending then
      sync_pending = false
      M.sync_on_exit()
    else
      if require('notes').is_open() then
        require('notes.picker').refresh()
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

  -- self-healing push: a reject means the remote advanced after our last fetch.
  -- Rebase local commits on top and retry once. Guarded so we never loop.
  local pushed_retry = false
  local function do_push()
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
        git({ 'pull', '--rebase', '--autostash' }, c.dir, function(pull_res)
          if pull_res.code == 0 then
            do_push()
          else
            git({ 'rebase', '--abort' }, c.dir, function()
              notify('Push failed: remote diverged, resolve manually', vim.log.levels.ERROR)
              finish()
            end)
          end
        end)
        return
      end

      notify('Push failed: ' .. err, vim.log.levels.ERROR)
      finish()
    end)
  end

  local function do_commit_push()
    git({ 'add', '-A' }, c.dir, function(add_res)
      if add_res.code ~= 0 then
        notify('git add failed: ' .. (add_res.stderr or ''), vim.log.levels.ERROR)
        finish()
        return
      end
      local msg = 'notes: ' .. os.date('%Y-%m-%d %H:%M')
      git({ 'commit', '-m', msg }, c.dir, function(commit_res)
        if commit_res.code ~= 0 then
          -- "nothing to commit" goes to stdout not stderr; treat as success and check for push
          local out = (commit_res.stdout or '') .. (commit_res.stderr or '')
          if out:find('nothing to commit') or out:find('nothing added to commit') then
            do_push()
            return
          end
          notify('git commit failed: ' .. (commit_res.stderr or ''), vim.log.levels.ERROR)
          finish()
          return
        end
        do_push()
      end)
    end)
  end

  -- After a failed stash pop: show which files conflict and ask whether to
  -- overwrite GitHub's version with the local one.
  local function handle_stash_conflict()
    git({ 'status', '--porcelain' }, c.dir, function(status_res)
      local conflict_xy =
        { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }
      local conflicts = {} -- array of { xy=…, file=… }
      for line in (status_res.stdout or ''):gmatch('[^\n]+') do
        local xy, fname = line:match('^(..)%s+(.+)')
        if xy and conflict_xy[xy] then
          conflicts[#conflicts + 1] = { xy = xy, file = fname }
        end
      end

      if #conflicts == 0 then
        -- pop failed for an unrecognised reason (e.g. untracked filename collision);
        -- always drop the stash so it does not accumulate, then commit whatever changed
        git({ 'stash', 'drop' }, c.dir, function()
          do_commit_push()
        end)
        return
      end

      local names = table.concat(
        vim.tbl_map(function(e)
          return e.file
        end, conflicts),
        ', '
      )
      -- conflict dialog runs on the main thread (we are inside vim.schedule)
      local choice = vim.fn.confirm(
        '[notes.nvim] GitHub updated: ' .. names .. '\nLocal changes will overwrite. Push?',
        '&Yes\n&No',
        2
      )

      if choice == 1 then
        -- keep local (stash = "theirs" in this stash-pop merge context)
        --
        -- UD/DD: the stash deleted the file; stage 3 is absent, so `checkout --theirs`
        --   would fail with "does not have a theirs version". Use `git rm --force`
        --   to stage the deletion explicitly.
        -- other XY: `checkout --theirs` restores the stash (local) version.
        local to_rm = {}
        local to_co = {}
        for _, e in ipairs(conflicts) do
          if e.xy == 'UD' or e.xy == 'DD' then
            to_rm[#to_rm + 1] = e.file
          else
            to_co[#to_co + 1] = e.file
          end
        end

        local function after_resolved()
          git({ 'stash', 'drop' }, c.dir, function()
            do_commit_push()
          end)
        end

        local function do_rm_then_done()
          if #to_rm == 0 then
            after_resolved()
            return
          end
          git(vim.list_extend({ 'rm', '--force', '--' }, to_rm), c.dir, function(rm_res)
            if rm_res.code ~= 0 then
              notify('Conflict resolve failed: ' .. (rm_res.stderr or ''), vim.log.levels.ERROR)
              finish()
            else
              after_resolved()
            end
          end)
        end

        if #to_co > 0 then
          git(vim.list_extend({ 'checkout', '--theirs', '--' }, to_co), c.dir, function(co_res)
            if co_res.code ~= 0 then
              notify('Conflict resolve failed: ' .. (co_res.stderr or ''), vim.log.levels.ERROR)
              finish()
            else
              do_rm_then_done()
            end
          end)
        else
          do_rm_then_done()
        end
      else
        -- keep GitHub version: reset to the pulled state and drop the failed stash
        git({ 'reset', '--hard', 'HEAD' }, c.dir, function()
          git({ 'stash', 'drop' }, c.dir, function()
            notify('Local changes discarded; kept GitHub version')
            -- force-reload the editor buffer from disk (:edit! discards buffer changes)
            local st = require('notes').state
            if st.current_file and st.edit_win and vim.api.nvim_win_is_valid(st.edit_win) then
              vim.api.nvim_win_call(st.edit_win, function()
                vim.cmd('edit! ' .. vim.fn.fnameescape(st.current_file))
              end)
            end
            finish()
          end)
        end)
      end
    end)
  end

  -- Fetch remote, then (if remote is ahead) stash → pull → pop before committing.
  -- This guarantees the push never fails with "fetch first".
  local function sync_with_remote_then_commit()
    git({ 'fetch', 'origin' }, c.dir, function(fetch_res)
      if fetch_res.code ~= 0 then
        -- offline or unreachable; commit locally, push will fail with a clear error
        do_commit_push()
        return
      end

      git({ 'rev-list', 'HEAD..FETCH_HEAD', '--count' }, c.dir, function(ahead_res)
        local ahead = tonumber(((ahead_res.stdout or ''):gsub('%s+', ''))) or 0

        if ahead == 0 then
          -- already in sync with remote
          do_commit_push()
          return
        end

        -- remote has new commits: stash local changes, pull, restore
        git({ 'stash', 'push', '--include-untracked' }, c.dir, function(stash_res)
          local nothing_stashed = (stash_res.stdout or ''):find('No local changes')

          -- reapply the stashed working tree (if any), then commit/push.
          -- Runs once the remote history is reconciled into local HEAD.
          local function pop_and_commit()
            if nothing_stashed then
              do_commit_push()
              return
            end
            git({ 'stash', 'pop' }, c.dir, function(pop_res)
              if pop_res.code == 0 then
                do_commit_push()
              else
                handle_stash_conflict()
              end
            end)
          end

          git({ 'pull', '--ff-only' }, c.dir, function(pull_res)
            if pull_res.code == 0 then
              pop_and_commit()
              return
            end

            -- ff-only failed: local also has commits (diverged history). The tree is
            -- clean now (changes are stashed), so rebase local commits onto remote.
            git({ 'pull', '--rebase' }, c.dir, function(rebase_res)
              if rebase_res.code == 0 then
                pop_and_commit()
                return
              end
              -- rebase hit a content conflict between committed histories: abort to
              -- leave a clean tree, restore the stash, and report.
              git({ 'rebase', '--abort' }, c.dir, function()
                if nothing_stashed then
                  notify('Sync failed: rebase conflict, resolve manually', vim.log.levels.ERROR)
                  finish()
                else
                  git({ 'stash', 'pop' }, c.dir, function()
                    notify('Sync failed: could not merge remote changes', vim.log.levels.ERROR)
                    finish()
                  end)
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end

  -- check uncommitted changes
  git({ 'status', '--porcelain' }, c.dir, function(status_res)
    local has_changes = status_res.code == 0 and status_res.stdout and status_res.stdout ~= ''

    if has_changes then
      sync_with_remote_then_commit()
      return
    end

    -- no local changes; check for unpushed commits
    -- (rev-list non-zero exit = no upstream → push anyway)
    git({ 'rev-list', '@{u}..HEAD', '--count' }, c.dir, function(ahead_res)
      local trimmed = ((ahead_res.stdout or ''):gsub('%s+', ''))
      local ahead = tonumber(trimmed)
      if ahead_res.code ~= 0 or (ahead and ahead > 0) then
        do_push()
      else
        finish()
      end
    end)
  end)
end

return M
