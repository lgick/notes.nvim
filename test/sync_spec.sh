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

# ── S11: ensure_repo clones a fresh dir when repo is configured ──────────────
s11() {
  echo 'S11: ensure_repo clones into a missing dir when repo is set'
  setup
  rm -rf "$A"   # simulate first-ever open: the plugin's dir does not exist yet
  drive ensure_repo
  check 'driver ok' 0 $?
  check 'dir is now a git repo' 'yes' "$([ -d "$A/.git" ] && echo yes || echo no)"
  check 'cloned file present' 'hello' "$(cat "$A/note.txt" 2>/dev/null)"
  teardown
}

# ── S12: ensure_repo just mkdir's when repo == '' (no clone, no .git) ────────
s12() {
  echo "S12: ensure_repo with repo='' only creates the directory"
  ROOT="$(mktemp -d)"
  A="$ROOT/A"   # never created
  REMOTE=''
  drive ensure_repo
  check 'driver ok' 0 $?
  check 'dir created' 'yes' "$([ -d "$A" ] && echo yes || echo no)"
  check 'not a git repo' 'no' "$([ -d "$A/.git" ] && echo yes || echo no)"
  teardown
}

# ── S13: commit_now_blocking() commits a pending deletion synchronously ──────
#         (VimLeavePre path) so restore() on the next open can't resurrect it.
s13() {
  echo 'S13: commit_now_blocking commits a deletion (VimLeavePre safety net)'
  setup
  rm "$A/a2.txt"   # plugin already deleted the file on disk, sync_on_exit not yet run
  drive commit
  check 'driver ok' 0 $?
  check 'deletion committed' '' "$(git -C "$A" status --porcelain)"
  check 'file gone from HEAD' '' "$(git -C "$A" show HEAD:a2.txt 2>/dev/null)"
  # restore() must NOT resurrect it: the deletion is now committed, not "accidental"
  drive restore
  check 'driver ok (restore)' 0 $?
  check 'still gone after restore' 'gone' "$([ -e "$A/a2.txt" ] && echo exists || echo gone)"
  teardown
}

# ── S13-guard: commit_now_blocking must NOT commit over unresolved markers ───
s13_guard() {
  echo 'S13-guard: commit_now_blocking is a no-op while MERGING with markers'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"; gitq "$B" add -A; gitq "$B" commit -m r; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"
  drive pull                                  # creates the conflict, markers + MERGE_HEAD
  check 'driver ok (pull)' 0 $?
  check 'merge in progress' 'yes' "$(merging)"
  drive commit
  check 'driver ok (commit)' 0 $?
  check 'still merging' 'yes' "$(merging)"
  check 'markers still present' 'yes' "$(has_markers note.txt)"
  teardown
}

# ── S14: sync_on_exit's finish() skips the full picker.scan() when the pull ──
#         brought no changes (Already up to date) — only a cheap redraw runs.
s14() {
  echo 'S14: sync_on_exit with UI open skips scan() when pull brings no changes'
  setup
  local f="$ROOT/scancount"
  NOTES_SCANCOUNT_FILE="$f" NOTES_DIR="$A" NOTES_REMOTE="$REMOTE" \
    "$NVIM" --headless -l "$REPO_ROOT/test/sync_driver.lua" scan_count \
    >/dev/null 2>"$ROOT/driver.err"
  local rc=$?
  check 'driver ok' 0 "$rc"
  check 'no full scan when nothing changed' '0' "$(cat "$f" 2>/dev/null)"
  teardown
}

# ── S14b: …but DOES scan() once when the pull actually merges in a change ────
s14b() {
  echo 'S14b: sync_on_exit with UI open scans once when pull brings a change'
  setup
  printf 'from B\n' >"$B/b.txt"; gitq "$B" add -A; gitq "$B" commit -m b; gitq "$B" push
  local f="$ROOT/scancount"
  NOTES_SCANCOUNT_FILE="$f" NOTES_DIR="$A" NOTES_REMOTE="$REMOTE" \
    "$NVIM" --headless -l "$REPO_ROOT/test/sync_driver.lua" scan_count \
    >/dev/null 2>"$ROOT/driver.err"
  local rc=$?
  check 'driver ok' 0 "$rc"
  check 'full scan runs when pull changed files' '1' "$(cat "$f" 2>/dev/null)"
  check 'pulled file present' 'from B' "$(cat "$A/b.txt" 2>/dev/null)"
  teardown
}

# ── S14c: a CONFLICTING pull that also brings a new file still triggers a scan.
#         Regression guard: gating tree_changed on `pull_res.code == 0` alone would
#         wrongly skip the rescan here (a conflicting pull exits non-zero even though
#         git wrote real merge activity, including the new file, to stdout).
s14c() {
  echo 'S14c: conflicting pull that also adds a file still triggers exactly one scan'
  setup
  printf 'hello\nREMOTE\n' >"$B/note.txt"
  printf 'brand new\n' >"$B/newnote.txt"
  gitq "$B" add -A; gitq "$B" commit -m 'remote conflict + new file'; gitq "$B" push
  printf 'hello\nLOCAL\n' >"$A/note.txt"   # uncommitted local edit, same line → conflict
  local f="$ROOT/scancount"
  NOTES_SCANCOUNT_FILE="$f" NOTES_DIR="$A" NOTES_REMOTE="$REMOTE" \
    "$NVIM" --headless -l "$REPO_ROOT/test/sync_driver.lua" scan_count \
    >/dev/null 2>"$ROOT/driver.err"
  local rc=$?
  check 'driver ok' 0 "$rc"
  check 'merge in progress' 'yes' "$(merging)"
  check 'file has conflict markers' 'yes' "$(has_markers note.txt)"
  check 'new file from remote landed on disk' 'brand new' "$(cat "$A/newnote.txt" 2>/dev/null)"
  check 'exactly one scan ran (tree_changed correctly true)' '1' "$(cat "$f" 2>/dev/null)"
  teardown
}

s1; s2; s2_guard; s3; s4; s5; s6; s7; s8; s9; s10; s11; s12; s13; s13_guard; s14; s14b; s14c

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails sync check(s) FAILED"
  exit 1
fi
echo 'all sync checks passed'
