#!/usr/bin/env bash
# Test suite entry point. Runs the picker spec (headless Lua) and the git-sync
# scenario spec (bare remote + two clones). Exits non-zero if anything fails.
#
# Requires only `git` and `nvim` (>= 0.10) on PATH. Run from anywhere:
#   bash test/run.sh

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
NVIM=${NVIM:-nvim}
status=0

echo '=== picker spec ==='
( cd "$ROOT" && "$NVIM" --headless -l "$DIR/picker_spec.lua" ) || status=1

echo
echo '=== git-sync spec ==='
( cd "$ROOT" && bash "$DIR/sync_spec.sh" ) || status=1

echo
if [ "$status" -eq 0 ]; then
  echo 'ALL TESTS PASSED'
else
  echo 'SOME TESTS FAILED'
fi
exit "$status"
