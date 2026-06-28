#!/usr/bin/env bash
# GitHub-sync scenario tests for the MERGE conflict model. For each case we build a
# bare "remote" plus two clones (A = the plugin's dir, B = a second machine), mutate
# via B, then drive the plugin's sync/pull/restore on A through test/sync_driver.lua
# and assert the resulting git/worktree state.
#
# Conflicts are NOT resolved by a dialog: a conflict is left as standard git markers
# in the file (repo enters MERGING). Resolving = remove the markers and sync again.
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

# action   — run the driver against A
drive() {
  local action="$1"
  NOTES_DIR="$A" NOTES_REMOTE="$REMOTE" \
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

merging() { # echo yes/no whether a merge is in progress in A
  [ -f "$A/.git/MERGE_HEAD" ] && echo yes || echo no
}

has_markers() { # echo yes/no whether $A/$1 contains conflict markers
  grep -q '^<<<<<<< ' "$A/$1" 2>/dev/null && echo yes || echo no
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

# ── S2: remote & local edit the SAME file → markers left, resolve by editing ──
s2() {
  echo 'S2: same-file conflict → markers in file, then resolve + push'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"   # uncommitted local edit, same line
  drive sync
  check 'driver ok' 0 $?
  check 'merge in progress' 'yes' "$(merging)"
  check 'file has conflict markers' 'yes' "$(has_markers note.txt)"
  check 'remote NOT pushed (still REMOTE)' "$(printf 'hello\nREMOTE')" "$(remote_file note.txt)"

  # user resolves the markers in the editor and saves → sync again
  printf 'hello\nLOCAL\nREMOTE\n' >"$A/note.txt"
  drive sync
  check 'driver ok (resolve)' 0 $?
  check 'merge finished' 'no' "$(merging)"
  check 'resolved content pushed' "$(printf 'hello\nLOCAL\nREMOTE')" "$(remote_file note.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S2-guard: leaving markers in place must NOT commit ────────────────────────
s2_guard() {
  echo 'S2-guard: unresolved markers → no commit, still MERGING'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"
  drive sync                                  # creates the conflict
  local before; before="$(git -C "$REMOTE" rev-parse HEAD)"
  drive sync                                  # markers still present
  check 'driver ok' 0 $?
  check 'still merging' 'yes' "$(merging)"
  check 'markers still present' 'yes' "$(has_markers note.txt)"
  check 'remote unchanged (no commit pushed)' "$before" "$(git -C "$REMOTE" rev-parse HEAD)"
  teardown
}

# ── S3: remote & local edit DIFFERENT files → auto-merge, both kept ──────────
s3() {
  echo 'S3: different-file edits → auto-merge'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'second\nLOCAL\n' >"$A/a2.txt"    # uncommitted edit to a different file
  drive sync
  check 'driver ok' 0 $?
  check 'no conflict' 'no' "$(merging)"
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

# ── S5: diverged history (local commit + remote commit) + dirty ──────────────
s5() {
  echo 'S5: diverged history + uncommitted local change → merge'
  setup
  printf 'C\n' >"$A/c.txt"; gitq "$A" add -A; gitq "$A" commit -m c   # local-ahead, unpushed
  printf 'D\n' >"$B/d.txt"; gitq "$B" add -A; gitq "$B" commit -m d; gitq "$B" push  # remote-ahead
  printf 'hello\ndirty\n' >"$A/note.txt"   # uncommitted local change (independent)
  drive sync
  check 'driver ok' 0 $?
  check 'no conflict' 'no' "$(merging)"
  check 'local commit pushed' 'C' "$(remote_file c.txt)"
  check 'remote commit present locally' 'D' "$(cat "$A/d.txt" 2>/dev/null)"
  check 'dirty change committed+pushed' "$(printf 'hello\ndirty')" "$(remote_file note.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S6: clean tree, local-ahead commit, remote advanced → merge + push ───────
s6() {
  echo 'S6: clean local-ahead + remote advanced → merge and push'
  setup
  printf 'E\n' >"$A/e.txt"; gitq "$A" add -A; gitq "$A" commit -m e   # local-ahead, clean tree
  printf 'F\n' >"$B/f.txt"; gitq "$B" add -A; gitq "$B" commit -m f; gitq "$B" push
  drive sync
  check 'driver ok' 0 $?
  check 'no conflict' 'no' "$(merging)"
  check 'local commit pushed' 'E' "$(remote_file e.txt)"
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

# ── S8: same-file conflict on OPEN (pull) → markers left, local intact ────────
s8() {
  echo 'S8: pull conflict on open → markers in file, no broken state'
  setup
  printf 'hello\nLOCAL\n' >"$A/note.txt"; gitq "$A" add -A; gitq "$A" commit -m local   # unpushed, conflicts
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m remote; gitq "$B" push
  drive pull
  check 'driver ok' 0 $?
  check 'merge in progress' 'yes' "$(merging)"
  check 'file has conflict markers' 'yes' "$(has_markers note.txt)"
  check 'no rebase dir left' 'gone' "$([ -d "$A/.git/rebase-merge" ] || [ -d "$A/.git/rebase-apply" ] && echo exists || echo gone)"
  teardown
}

# ── S9: modify/delete (remote modified, local deleted) → auto-keep remote ─────
s9() {
  echo 'S9: modify/delete conflict → auto-resolves to keep the modified file'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  rm "$A/note.txt"   # uncommitted local deletion
  drive sync
  check 'driver ok' 0 $?
  check 'merge finished' 'no' "$(merging)"
  check 'modified file kept on disk' "$(printf 'hello\nREMOTE')" "$(cat "$A/note.txt" 2>/dev/null)"
  check 'kept file pushed' "$(printf 'hello\nREMOTE')" "$(remote_file note.txt)"
  check 'tree clean' '' "$(git -C "$A" status --porcelain)"
  teardown
}

# ── S10: conflict on OPEN with an UNCOMMITTED local edit → real merge, not a ──
#         stash-pop orphan. The old --autostash left markers with NO MERGE_HEAD,
#         and the next sync then `git add -A`-committed (and pushed) the markers.
s10() {
  echo 'S10: dirty conflict on open → MERGE_HEAD (no stash-pop), markers never pushed'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"   # UNCOMMITTED local edit, same line
  drive pull                               # open: commit-first then merge
  check 'driver ok' 0 $?
  check 'real merge in progress' 'yes' "$(merging)"
  check 'file has conflict markers' 'yes' "$(has_markers note.txt)"
  check 'no stash leaked' '' "$(git -C "$A" stash list)"

  local before; before="$(git -C "$REMOTE" rev-parse HEAD)"
  drive sync                               # must NOT commit/push the marker file
  check 'driver ok (sync)' 0 $?
  check 'still merging' 'yes' "$(merging)"
  check 'markers still present' 'yes' "$(has_markers note.txt)"
  check 'markers NOT pushed' "$before" "$(git -C "$REMOTE" rev-parse HEAD)"
  check 'remote note still clean' "$(printf 'hello\nREMOTE')" "$(remote_file note.txt)"

  # resolve and sync → merge completes and pushes the resolution
  printf 'hello\nLOCAL\nREMOTE\n' >"$A/note.txt"
  drive sync
  check 'driver ok (resolve)' 0 $?
  check 'merge finished' 'no' "$(merging)"
  check 'resolved content pushed' "$(printf 'hello\nLOCAL\nREMOTE')" "$(remote_file note.txt)"
  teardown
}

s1; s2; s2_guard; s3; s4; s5; s6; s7; s8; s9; s10

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails sync check(s) FAILED"
  exit 1
fi
echo 'all sync checks passed'
