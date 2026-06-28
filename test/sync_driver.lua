-- Drives one plugin-side git action against a repo set up by sync_spec.sh,
-- waiting for the async chain to settle, then exits 0 (or 1 on internal error).
-- All git-state assertions live in sync_spec.sh.
--
-- Run: nvim --headless -l test/sync_driver.lua <action>
--   action ∈ { sync, pull, restore }
--   env NOTES_DIR     — the plugin's notes directory (clone "A")
--   env NOTES_REMOTE  — remote URL (the bare repo)
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

vim.cmd('quit')
