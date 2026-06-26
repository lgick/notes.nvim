#!/usr/bin/env bash
# GitHub-sync scenario tests. For each case we build a bare "remote" plus two
# clones (A = the plugin's dir, B = a second machine), mutate via B, then drive
# the plugin's sync/pull/restore on A through test/sync_driver.lua and assert the
# resulting git/worktree state.
#
# Run from the repo root: bash test/sync_spec.sh   (or via test/run.sh)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NVIM=${NVIM:-nvim}

fails=0
pass() { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s  (%s)\n' "$1" "${2:-}"; fails=$((fails + 1)); }
check() { # name  expected  actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
gconf() {
  git -C "$1" config user.email test@notes.nvim
  git -C "$1" config user.name 'Notes Test'
  git -C "$1" config commit.gpgsign false
}

# action  [confirm]   — run the driver against A
drive() {
  local action="$1" confirm="${2:-1}"
  NOTES_DIR="$A" NOTES_REMOTE="$REMOTE" NOTES_CONFIRM="$confirm" \
    "$NVIM" --headless -l "$REPO_ROOT/test/sync_driver.lua" "$action" \
    >/dev/null 2>"$ROOT/driver.err"
  return $?
}

setup() { # creates REMOTE + A (with an initial commit pushed) + B
  ROOT="$(mktemp -d)"
  REMOTE="$ROOT/remote.git"
  A="$ROOT/A"
  B="$ROOT/B"
  git init -q --bare -b main "$REMOTE"
  git clone -q "$REMOTE" "$A" 2>/dev/null; gconf "$A"
  printf 'hello\n' >"$A/note.txt"
  printf 'second\n' >"$A/a2.txt"
  gitq "$A" add -A
  gitq "$A" commit -m init
  gitq "$A" push -u origin HEAD
  git clone -q "$REMOTE" "$B"; gconf "$B"
}

teardown() { rm -rf "$ROOT"; }

rebase_in_progress() { # 0 if a rebase is mid-flight in A
  [ -d "$A/.git/rebase-merge" ] || [ -d "$A/.git/rebase-apply" ]
}

remote_file() { # print a file's content as it exists on the remote HEAD
  git -C "$REMOTE" show "HEAD:$1" 2>/dev/null
}

# ── S1: remote added a file, local clean → pull brings it in ─────────────────
s1() {
  echo 'S1: remote add, local clean → pull'
  setup
  printf 'from B\n' >"$B/b.txt"; gitq "$B" add -A; gitq "$B" commit -m b; gitq "$B" push
  drive pull
  check 'driver ok' 0 $?
  check 'pulled new file' 'from B' "$(cat "$A/b.txt" 2>/dev/null)"
  teardown
}

# ── S2: remote & local edit the SAME file → conflict dialog (Yes / No) ────────
s2_yes() {
  echo 'S2a: same-file conflict, choose Yes (keep local)'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"   # uncommitted local edit, same line
  drive sync 1
  check 'driver ok' 0 $?
  check 'local kept on disk' "$(printf 'hello\nLOCAL')" "$(cat "$A/note.txt")"
  check 'local pushed to remote' "$(printf 'hello\nLOCAL')" "$(remote_file note.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  check 'no stash left' '' "$(git -C "$A" stash list)"
  teardown
}

s2_no() {
  echo 'S2b: same-file conflict, choose No (keep remote)'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  local before; before="$(git -C "$REMOTE" rev-parse HEAD)"
  printf 'hello\nLOCAL\n' >"$A/note.txt"
  drive sync 2
  check 'driver ok' 0 $?
  check 'remote version on disk' "$(printf 'hello\nREMOTE')" "$(cat "$A/note.txt")"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  check 'no stash left' '' "$(git -C "$A" stash list)"
  check 'remote unchanged (no push)' "$before" "$(git -C "$REMOTE" rev-parse HEAD)"
  teardown
}

# ── S3: remote & local edit DIFFERENT files → auto-merge, both kept ──────────
s3() {
  echo 'S3: different-file edits → auto-merge'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'second\nLOCAL\n' >"$A/a2.txt"    # uncommitted edit to a different file
  drive sync 1
  check 'driver ok' 0 $?
  check 'remote edit merged in' "$(printf 'hello\nREMOTE')" "$(cat "$A/note.txt")"
  check 'local edit preserved' "$(printf 'second\nLOCAL')" "$(cat "$A/a2.txt")"
  check 'local edit pushed' "$(printf 'second\nLOCAL')" "$(remote_file a2.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S4: remote deleted a file, local clean → pull removes it ──────────────────
s4() {
  echo 'S4: remote delete, local clean → pull'
  setup
  gitq "$B" rm a2.txt; gitq "$B" commit -m del; gitq "$B" push
  drive pull
  check 'driver ok' 0 $?
  check 'file removed locally' 'gone' "$([ -e "$A/a2.txt" ] && echo exists || echo gone)"
  teardown
}

# ── S5: diverged history (local commit + remote commit) + dirty (G2) ─────────
s5() {
  echo 'S5: diverged history + uncommitted local change → rebase-after-stash'
  setup
  printf 'C\n' >"$A/c.txt"; gitq "$A" add -A; gitq "$A" commit -m c   # local-ahead, unpushed
  printf 'D\n' >"$B/d.txt"; gitq "$B" add -A; gitq "$B" commit -m d; gitq "$B" push  # remote-ahead
  printf 'hello\ndirty\n' >"$A/note.txt"   # uncommitted local change (independent)
  drive sync 1
  check 'driver ok' 0 $?
  check 'local commit pushed' 'C' "$(remote_file c.txt)"
  check 'remote commit present locally' 'D' "$(cat "$A/d.txt" 2>/dev/null)"
  check 'dirty change committed+pushed' "$(printf 'hello\ndirty')" "$(remote_file note.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  check 'no rebase in progress' 1 "$(rebase_in_progress; echo $?)"
  teardown
}

# ── S6: clean tree, local-ahead commit, remote advanced → push-reject retry (G3)
s6() {
  echo 'S6: clean local-ahead + remote advanced → self-healing push'
  setup
  printf 'E\n' >"$A/e.txt"; gitq "$A" add -A; gitq "$A" commit -m e   # local-ahead, clean tree
  printf 'F\n' >"$B/f.txt"; gitq "$B" add -A; gitq "$B" commit -m f; gitq "$B" push
  drive sync 1
  check 'driver ok' 0 $?
  check 'local commit pushed after rebase' 'E' "$(remote_file e.txt)"
  check 'remote commit present locally' 'F' "$(cat "$A/f.txt" 2>/dev/null)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S7: accidental local rm of a tracked file at open → restore() ────────────
s7() {
  echo 'S7: accidental rm → restore() recovers, deletion not propagated'
  setup
  rm "$A/a2.txt"   # accidental shell deletion, uncommitted
  drive restore
  check 'driver ok' 0 $?
  check 'file restored' 'second' "$(cat "$A/a2.txt" 2>/dev/null)"
  check 'no pending deletion' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S8: pull rebase conflict on open → rebase --abort leaves clean tree (G1) ──
s8() {
  echo 'S8: pull rebase conflict → rebase --abort, no broken state'
  setup
  printf 'hello\nLOCAL\n' >"$A/note.txt"; gitq "$A" add -A; gitq "$A" commit -m local   # unpushed, conflicts
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m remote; gitq "$B" push
  local head_before; head_before="$(git -C "$A" rev-parse HEAD)"
  drive pull
  check 'driver ok' 0 $?
  check 'no rebase in progress' 1 "$(rebase_in_progress; echo $?)"
  check 'local commit intact (rebase aborted)' "$head_before" "$(git -C "$A" rev-parse HEAD)"
  check 'local content intact' "$(printf 'hello\nLOCAL')" "$(cat "$A/note.txt")"
  check 'tree clean (no conflict markers)' '' "$(git -C "$A" status --porcelain)"
  teardown
}

s1; s2_yes; s2_no; s3; s4; s5; s6; s7; s8

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails sync check(s) FAILED"
  exit 1
fi
echo 'all sync checks passed'
