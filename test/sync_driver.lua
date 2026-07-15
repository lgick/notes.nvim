-- Drives one plugin-side git action against a repo set up by sync_spec.sh,
-- waiting for the async chain to settle, then exits 0 (or 1 on internal error).
-- All git-state assertions live in sync_spec.sh.
--
-- Run: nvim --headless -l test/sync_driver.lua <action>
--   action ∈ { sync, pull, restore, ensure_repo, commit, scan_count }
--   env NOTES_DIR     — the plugin's notes directory (clone "A")
--   env NOTES_REMOTE  — remote URL (the bare repo)
--   env NOTES_SCANCOUNT_FILE — (scan_count only) file to write the picker.scan() call count to
--
-- The merge model needs no conflict dialog: a conflict is left as markers in the
-- file (repo enters MERGING); resolving = remove markers and run `sync` again.

package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local action = arg[1]
local dir = vim.env.NOTES_DIR
local remote = vim.env.NOTES_REMOTE or ''

local notes = require('notes')
local git = require('notes.git')
notes.setup({ dir = dir, repo = remote })
notes.state.synced = true -- behave like an established session

local done = false
-- non-nil only for 'scan_count': number of picker.scan() calls during the run,
-- written to NOTES_SCANCOUNT_FILE below once the async chain settles
local scan_calls = nil

if action == 'sync' then
  git._on_idle = function()
    done = true
  end
  git.sync_on_exit()
elseif action == 'pull' then
  git.pull(function()
    done = true
  end)
elseif action == 'restore' then
  git.restore(function()
    done = true
  end)
elseif action == 'ensure_repo' then
  git.ensure_repo(function()
    done = true
  end)
elseif action == 'commit' then
  -- commit_now_blocking() is synchronous (vim.system(...):wait()); no callback to await
  git.commit_now_blocking()
  done = true
elseif action == 'scan_count' then
  -- opens the real UI (like notes.open()'s ui.open()+picker.populate()) so
  -- sync_on_exit's finish() sees notes.is_open() == true and exercises its
  -- tree_changed branch (full picker.refresh()/scan() vs cheap redraw-only)
  local ui = require('notes.ui')
  local picker = require('notes.picker')
  ui.open()
  picker.populate()

  scan_calls = 0
  local orig_scan = picker.scan
  picker.scan = function(...)
    scan_calls = scan_calls + 1
    return orig_scan(...)
  end

  git._on_idle = function()
    done = true
  end
  git.sync_on_exit()
else
  io.stderr:write('unknown action: ' .. tostring(action) .. '\n')
  vim.cmd('cquit 1')
end

local ok = vim.wait(20000, function()
  return done
end, 50)
if not ok then
  io.stderr:write('timed out waiting for ' .. action .. ' to settle\n')
  vim.cmd('cquit 1')
end

if scan_calls ~= nil and vim.env.NOTES_SCANCOUNT_FILE and vim.env.NOTES_SCANCOUNT_FILE ~= '' then
  vim.fn.writefile({ tostring(scan_calls) }, vim.env.NOTES_SCANCOUNT_FILE)
end

vim.cmd('quit')
