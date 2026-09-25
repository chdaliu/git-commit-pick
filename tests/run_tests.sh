#!/bin/bash
# run_tests.sh
#
# Automated checks for scripts/git_commit_pick.sh. Builds the fixture, runs
# every scenario in an isolated case directory with a fake HOME, and prints
# PASS/FAIL counters. Exits non-zero when any check fails.

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
TESTS="$ROOT/tests"
SCRIPT="$ROOT/scripts/git_commit_pick.sh"
FIX="$TESTS/fixture"
OUT="$TESTS/out"

rm -rf "$OUT"
mkdir -p "$OUT"
OUTC="$(cd "$OUT" && pwd -P)"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both '$2')"; fi
}
assert_contains() {
  case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing '$3')";; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) bad "$1 (unexpected '$3')";; *) ok "$1";; esac
}
assert_exists() {
  if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing '$2')"; fi
}
assert_gone() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (still exists '$2')"; fi
}
assert_sha() {
  if [[ "$2" =~ ^[0-9a-f]{40}$ ]]; then ok "$1"; else bad "$1 (not a 40-char id: '$2')"; fi
}

sv() { printf '%s\n' "$1" | grep -E "^  $2: " | head -1 | sed 's/^[^:]*:[[:space:]]*//'; }
epoch_of() { date -j -f "%Y%m%d%H%M%S" "$1" +%s; }
head_of() { git -C "$1" rev-parse --verify -q HEAD 2>/dev/null; }
subject_of() { git -C "$1" log -1 --format=%s 2>/dev/null; }
at_of() { git -C "$1" log -1 --format=%at 2>/dev/null; }
ct_of() { git -C "$1" log -1 --format=%ct 2>/dev/null; }

build_case() {
  local tag="$1"
  rm -rf "$OUT/$tag"
  mkdir -p "$OUT/$tag"
  cp -Rp "$FIX/." "$OUT/$tag/"
  mkdir -p "$OUT/$tag/home/.Trash"
  cat > "$OUT/$tag/home/.gitconfig" <<'EOF'
[user]
	name = GitCommitPick Test
	email = test@example.com
EOF
}

run_pick() {
  local tag="$1"
  shift
  HOME="$OUTC/$tag/home" "$SCRIPT" "$@" --language en
}

wait_sha() {
  local p="$1" base="$2" i=0 sha
  while [ "$i" -lt 200 ]; do
    sha="$(git -C "$p" rev-parse --verify -q HEAD 2>/dev/null)"
    if [ -n "$sha" ] && [ "$sha" != "$base" ]; then
      printf '%s\n' "$sha"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

first_committed_sha() {
  printf '%s\n' "$1" | grep -F "[committed]" | head -1 | awk '{print $NF}'
}

echo "== 1. syntax checks =="
for f in "$SCRIPT" "$TESTS/create_test_fixture.sh" "$TESTS/run_tests.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

echo "== 2. message tables =="
KEYS="$(grep -oE '(msg|ask) [a-z_]+' "$SCRIPT" | awk '{print $2}' | sort -u)"
eval "$(sed -n '/^msg_en() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^msg_zh() {/,/^}/p' "$SCRIPT")"
MISSING=0
for k in $KEYS; do
  en="$(msg_en "$k")"
  zh="$(msg_zh "$k")"
  if [ -z "$en" ] || [ -z "$zh" ]; then
    MISSING=$((MISSING + 1))
    bad "message key '$k' (en='$en' zh='$zh')"
  fi
done
if [ "$MISSING" -eq 0 ]; then ok "all message keys exist in both tables"; fi

echo "== 3. fixture =="
if "$TESTS/create_test_fixture.sh" "$FIX" >/dev/null 2>&1; then ok "fixture built"; else bad "fixture built"; fi
assert_exists "fixture src" "$FIX/src"
assert_exists "fixture src_remote" "$FIX/src_remote"
assert_exists "fixture origin.git" "$FIX/origin.git"
assert_exists "fixture src_empty_remote" "$FIX/src_empty_remote"
assert_exists "fixture origin_empty.git" "$FIX/origin_empty.git"

echo "== 4. --help =="
RES="$("$SCRIPT" --help 2>&1)"
RC=$?
assert_eq "help exit code" "$RC" "0"
assert_contains "help usage line" "$RES" "Usage: git_commit_pick.sh"
assert_contains "help time formats" "$RES" "YYYYMMDDHHMM"

echo "== 5. unknown option =="
RES="$("$SCRIPT" --bogus 2>&1)"
RC=$?
assert_eq "unknown option exit code" "$RC" "1"
assert_contains "unknown option message" "$RES" "Unknown option"

echo "== 6. validation: not a git repository =="
build_case t06
RES="$(run_pick t06 "$OUTC/t06/nongit" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "nongit exit code" "$RC" "1"
assert_contains "nongit message" "$RES" "Not a git repository"

echo "== 7. validation: clean repository =="
build_case t07
RES="$(run_pick t07 "$OUTC/t07/clean" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "clean exit code" "$RC" "1"
assert_contains "clean message" "$RES" "git status is empty"

echo "== 8. validation: nothing staged =="
build_case t08
RES="$(run_pick t08 "$OUTC/t08/unstaged" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "unstaged exit code" "$RC" "1"
assert_contains "unstaged message" "$RES" "Nothing is staged"

echo "== 9. validation: .git is a file =="
build_case t09
RES="$(run_pick t09 "$OUTC/t09/gitfile" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "gitfile exit code" "$RC" "1"
assert_contains "gitfile message" "$RES" ".git is a file"

echo "== 10. validation: invalid time =="
build_case t10
RES="$(run_pick t10 "$OUTC/t10/src" --time "2026-13-40 99:00:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "invalid time exit code" "$RC" "1"
assert_contains "invalid time message" "$RES" "Invalid time format"
assert_gone "no copy created" "$OUTC/t10/src-1"

echo "== 11. validation: missing repository =="
build_case t11
RES="$(run_pick t11 --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "missing repo exit code" "$RC" "1"
assert_contains "missing repo message" "$RES" "No repository path"

echo "== 12. --yes requires --select =="
build_case t12
RES="$(run_pick t12 "$OUTC/t12/src" --time "2026-09-20 14:30:00" --yes --no-push 2>&1)"
RC=$?
assert_eq "no select exit code" "$RC" "1"
assert_contains "no select message" "$RES" "requires --select"
assert_gone "no copy created" "$OUTC/t12/src-1"

echo "== 13. dry-run =="
build_case t13
RES="$(run_pick t13 "$OUTC/t13/src" --time "2026-09-20 14:30:00,15:45:00" --yes --dry-run 2>&1)"
RC=$?
assert_eq "dry-run exit code" "$RC" "0"
assert_contains "dry-run plan" "$RES" "[plan]"
assert_contains "dry-run banner" "$RES" "DRY-RUN"
assert_gone "dry-run copy 1" "$OUTC/t13/src-1"
assert_gone "dry-run copy 2" "$OUTC/t13/src-2"
assert_eq "dry-run trash empty" "$(ls -A "$OUTC/t13/home/.Trash")" ""

echo "== 14. interactive times, inheritance, cancel =="
build_case t14
RES="$(printf '2026-09-20 14:30:00\n15:45:00\n\nc\n' | run_pick t14 "$OUTC/t14/src" --no-push 2>&1)"
RC=$?
assert_eq "interactive cancel exit code" "$RC" "0"
assert_contains "resolved time-only" "$RES" "15:45:00  ->  2026-09-20 15:45:00"
assert_contains "cancel message" "$RES" "Selection cancelled"
assert_contains "cancel discarded message" "$RES" "Every copy created by this run was moved to the Trash"
assert_gone "copy 1 moved out" "$OUTC/t14/src-1"
assert_gone "copy 2 moved out" "$OUTC/t14/src-2"
assert_exists "copy 1 in trash" "$OUTC/t14/home/.Trash/src-1"
assert_exists "copy 2 in trash" "$OUTC/t14/home/.Trash/src-2"
assert_exists "original kept" "$OUTC/t14/src"
assert_eq "copy 1 author date" "$(at_of "$OUTC/t14/home/.Trash/src-1")" "$(epoch_of 20260920143000)"
assert_eq "copy 2 author date" "$(at_of "$OUTC/t14/home/.Trash/src-2")" "$(epoch_of 20260920154500)"
assert_eq "copy 1 committer date" "$(ct_of "$OUTC/t14/home/.Trash/src-1")" "$(epoch_of 20260920143000)"
assert_eq "copy 1 subject" "$(subject_of "$OUTC/t14/home/.Trash/src-1")" "Initial commit"
assert_eq "trash holds both copies" "$(ls -A "$OUTC/t14/home/.Trash" | wc -l | tr -d ' ')" "2"
assert_eq "source has no commit" "$(head_of "$OUTC/t14/src")" ""
FILES="$(git -c core.quotePath=false -C "$OUTC/t14/home/.Trash/src-1" ls-files)"
assert_contains "staged a.txt committed" "$FILES" "a.txt"
assert_contains "staged sub/b.txt committed" "$FILES" "sub/b.txt"
assert_contains "staged 中文.txt committed" "$FILES" "中文.txt"
assert_not_contains "untracked file not committed" "$FILES" "unstaged.txt"
STATUS="$(git -C "$OUTC/t14/home/.Trash/src-1" status --porcelain)"
assert_contains "untracked file still present" "$STATUS" "?? unstaged.txt"

echo "== 15. time-only defaults to today =="
build_case t15
RES="$(printf '15:45:00\n\nc\n' | run_pick t15 "$OUTC/t15/src" --no-push 2>&1)"
RC=$?
assert_eq "today exit code" "$RC" "0"
TODAY="$(date +%Y-%m-%d)"
assert_eq "time-only author date" "$(at_of "$OUTC/t15/home/.Trash/src-1")" "$(date -j -f "%Y-%m-%d %H:%M:%S" "$TODAY 15:45:00" +%s)"

echo "== 16. compact and epoch formats =="
build_case t16
RES="$(printf 'c\n' | run_pick t16 "$OUTC/t16/src" --time "202609201430.00,20260920143000,1789885800,1789885800123" --no-push 2>&1)"
RC=$?
assert_eq "formats exit code" "$RC" "0"
assert_eq "compact .SS date" "$(at_of "$OUTC/t16/home/.Trash/src-1")" "$(epoch_of 20260920143000)"
assert_eq "compact 14-digit date" "$(at_of "$OUTC/t16/home/.Trash/src-2")" "$(epoch_of 20260920143000)"
assert_eq "epoch seconds date" "$(at_of "$OUTC/t16/home/.Trash/src-3")" "1789885800"
assert_eq "epoch milliseconds date" "$(at_of "$OUTC/t16/home/.Trash/src-4")" "1789885800"

echo "== 17. repeated --time and custom message =="
build_case t17
RES="$(printf 'c\n' | run_pick t17 "$OUTC/t17/src" --time "2026-09-20 14:30:00" --time "2026-09-20 15:45:00" -m "My message" --no-push 2>&1)"
RC=$?
assert_eq "custom message exit code" "$RC" "0"
assert_exists "custom copy 1" "$OUTC/t17/home/.Trash/src-1"
assert_exists "custom copy 2" "$OUTC/t17/home/.Trash/src-2"
assert_eq "custom subject 1" "$(subject_of "$OUTC/t17/home/.Trash/src-1")" "My message"
assert_eq "custom subject 2" "$(subject_of "$OUTC/t17/home/.Trash/src-2")" "My message"

echo "== 18. source repository untouched =="
assert_eq "source still unborn" "$(head_of "$OUTC/t14/src")" ""
STAGED="$(git -c core.quotePath=false -C "$OUTC/t14/src" diff --cached --name-only | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "source staged unchanged" "$STAGED" "a.txt sub/b.txt 中文.txt "
SRC_STATUS="$(git -C "$OUTC/t14/src" status --porcelain)"
assert_contains "source untracked unchanged" "$SRC_STATUS" "?? unstaged.txt"
assert_eq "source staged count" "$(git -C "$OUTC/t14/src" diff --cached --name-only | wc -l | tr -d ' ')" "3"

echo "== 19. interactive full id selection + push + cleanup =="
build_case t19
RES="$({ wait_sha "$OUTC/t19/src_remote-1" "$(head_of "$OUTC/t19/src_remote")"; printf '1\n'; } | run_pick t19 "$OUTC/t19/src_remote" --time "2026-09-20 14:30:00,15:45:00" 2>&1)"
RC=$?
SHA1="$(first_committed_sha "$RES")"
assert_eq "push run exit code" "$RC" "0"
assert_sha "printed commit id" "$SHA1"
assert_contains "push marker" "$RES" "[pushed]"
assert_eq "bare origin head" "$(git -C "$OUTC/t19/origin.git" rev-parse refs/heads/main)" "$SHA1"
assert_eq "kept repo head" "$(head_of "$OUTC/t19/src_remote")" "$SHA1"
assert_exists "original in trash" "$OUTC/t19/home/.Trash/src_remote"
assert_exists "other copy in trash" "$OUTC/t19/home/.Trash/src_remote-2"
assert_gone "picked copy renamed" "$OUTC/t19/src_remote-1"
assert_contains "final line" "$RES" "Final: $OUTC/t19/src_remote  2026-09-20 14:30:00  $SHA1"
assert_eq "summary pushed" "$(sv "$RES" Pushed)" "1"
assert_eq "summary trashed" "$(sv "$RES" Trashed)" "2"
assert_eq "summary renamed" "$(sv "$RES" Renamed)" "1"
assert_eq "summary errors" "$(sv "$RES" Errors)" "0"

echo "== 20. --select index + --no-push + decoy safety =="
build_case t20
RES="$(run_pick t20 "$OUTC/t20/src" --time "2026-09-20 14:30:00,15:45:00" --yes --select 1 --no-push 2>&1)"
RC=$?
SHA1="$(first_committed_sha "$RES")"
assert_eq "index select exit code" "$RC" "0"
assert_contains "push skipped" "$RES" "[skipped] push"
assert_eq "kept repo head" "$(head_of "$OUTC/t20/src")" "$SHA1"
assert_gone "copy 2 removed" "$OUTC/t20/src-2"
assert_gone "copy 1 renamed" "$OUTC/t20/src-1"
assert_exists "original in trash" "$OUTC/t20/home/.Trash/src"
assert_exists "copy 2 in trash" "$OUTC/t20/home/.Trash/src-2"
assert_exists "decoy sibling untouched" "$OUTC/t20/src-old"
assert_contains "decoy content" "$(cat "$OUTC/t20/src-old/keep.txt")" "do-not-delete"
assert_exists "bare origin untouched" "$OUTC/t20/origin.git"
assert_eq "summary created" "$(sv "$RES" "Copies created")" "2"
assert_eq "summary committed" "$(sv "$RES" Committed)" "2"

echo "== 21. selection by unique id prefix =="
build_case t21
RES="$({ printf '%s\n1\n' "$(wait_sha "$OUTC/t21/src-1" | cut -c1-7)"; } | run_pick t21 "$OUTC/t21/src" --time "2026-09-20 14:30:00,15:45:00" --no-push 2>&1)"
RC=$?
assert_eq "prefix select exit code" "$RC" "0"
assert_contains "prefix keeping line" "$RES" "Keeping:"
assert_exists "prefix kept repo" "$OUTC/t21/src"

echo "== 22. non-matching commit id =="
build_case t22
RES="$(run_pick t22 "$OUTC/t22/src" --time "2026-09-20 14:30:00" --yes --select "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" --no-push 2>&1)"
RC=$?
assert_eq "no match exit code" "$RC" "1"
assert_contains "no match message" "$RES" "No copy matches"
assert_exists "copy kept on failure" "$OUTC/t22/src-1"
assert_exists "original kept on failure" "$OUTC/t22/src"
assert_eq "trash empty on failure" "$(ls -A "$OUTC/t22/home/.Trash")" ""

echo "== 23. invalid selection then valid index =="
build_case t23
RES="$(printf 'zzz\n1\n1\n' | run_pick t23 "$OUTC/t23/src" --time "2026-09-20 14:30:00" --no-push 2>&1)"
RC=$?
assert_eq "recovery exit code" "$RC" "0"
assert_contains "invalid selection printed" "$RES" "Invalid selection"
assert_exists "recovered kept repo" "$OUTC/t23/src"

echo "== 24. confirmation cancel keeps everything =="
build_case t24
RES="$(printf '1\n2\n' | run_pick t24 "$OUTC/t24/src" --time "2026-09-20 14:30:00" --no-push 2>&1)"
RC=$?
assert_eq "confirm cancel exit code" "$RC" "0"
assert_contains "confirm cancel message" "$RES" "Cancelled"
assert_exists "copy kept" "$OUTC/t24/src-1"
assert_exists "original kept" "$OUTC/t24/src"
assert_eq "trash empty" "$(ls -A "$OUTC/t24/home/.Trash")" ""

echo "== 25. Trash collision naming =="
build_case t25
mkdir -p "$OUTC/t25/home/.Trash/src"
RES="$(run_pick t25 "$OUTC/t25/src" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "collision exit code" "$RC" "0"
assert_exists "collision trash entry" "$OUTC/t25/home/.Trash/src 2"
assert_exists "collision trash git dir" "$OUTC/t25/home/.Trash/src 2/.git"
assert_gone "picked copy renamed" "$OUTC/t25/src-1"

echo "== 26. push failure aborts before cleanup =="
build_case t26
RES="$(run_pick t26 "$OUTC/t26/src" --time "2026-09-20 14:30:00,15:45:00" --yes --select 1 2>&1)"
RC=$?
assert_eq "push failure exit code" "$RC" "1"
assert_contains "push failure message" "$RES" "Push failed"
assert_exists "copy 1 kept" "$OUTC/t26/src-1"
assert_exists "copy 2 kept" "$OUTC/t26/src-2"
assert_exists "original kept" "$OUTC/t26/src"
assert_eq "trash empty" "$(ls -A "$OUTC/t26/home/.Trash")" ""

echo "== 27. existing target aborts before copying =="
build_case t27
mkdir -p "$OUTC/t27/src-1"
RES="$(run_pick t27 "$OUTC/t27/src" --time "2026-09-20 14:30:00,15:45:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "target exists exit code" "$RC" "1"
assert_contains "target exists message" "$RES" "Target already exists"
assert_gone "later copy not created" "$OUTC/t27/src-2"

echo "== 28. Chinese output =="
build_case t28
RES="$(printf '2026-09-20 14:30:00\n\nc\n' | HOME="$OUTC/t28/home" "$SCRIPT" "$OUTC/t28/src" --language zh --no-push 2>&1)"
RC=$?
assert_eq "zh exit code" "$RC" "0"
assert_contains "zh committed marker" "$RES" "[已提交]"
assert_contains "zh cancel message" "$RES" "已取消选择"

echo "== 29. config round-trip =="
build_case t29
cat > "$OUTC/t29/cfg.json" <<EOF
{
  "language": "en",
  "repoPath": "$OUTC/t29/src",
  "times": ["2026-09-20 14:30:00"],
  "message": "Cfg commit",
  "push": false,
  "saveDir": ""
}
EOF
RES="$(run_pick t29 -c "$OUTC/t29/cfg.json" --yes --select 1 2>&1)"
RC=$?
assert_eq "config exit code" "$RC" "0"
assert_contains "config push skipped" "$RES" "[skipped] push"
assert_eq "config subject" "$(subject_of "$OUTC/t29/src")" "Cfg commit"
assert_eq "config kept author date" "$(at_of "$OUTC/t29/src")" "$(epoch_of 20260920143000)"

echo "== 30. --yes never writes config =="
build_case t30
RES="$(run_pick t30 "$OUTC/t30/src" --time "2026-09-20 14:30:00" --yes --select 1 --no-push --saveDir "$OUTC/t30" 2>&1)"
RC=$?
assert_eq "config write exit code" "$RC" "0"
assert_gone "no config written" "$OUTC/t30/git_commit_pick.config.json"

echo "== 31. full-width (Chinese IME) time input =="
build_case t31
RES="$(printf 'c\n' | run_pick t31 "$OUTC/t31/src" --time "２０２６－０９－２０ １４：３０：００" --no-push 2>&1)"
RC=$?
assert_eq "full-width exit code" "$RC" "0"
assert_eq "full-width author date" "$(at_of "$OUTC/t31/home/.Trash/src-1")" "$(epoch_of 20260920143000)"

echo "== 32. epoch input updates the reference date =="
build_case t32
RES="$(printf 'c\n' | run_pick t32 "$OUTC/t32/src" --time "1789885800,15:45:00" --no-push 2>&1)"
RC=$?
assert_eq "ref date exit code" "$RC" "0"
REF_DAY="$(date -r 1789885800 +%Y-%m-%d)"
assert_eq "time-only follows epoch date" "$(at_of "$OUTC/t32/home/.Trash/src-2")" "$(date -j -f "%Y-%m-%d %H:%M:%S" "$REF_DAY 15:45:00" +%s)"

echo "== 33. empty time prompt is rejected =="
build_case t33
RES="$(printf '\n2026-09-20 14:30:00\n\nc\n' | run_pick t33 "$OUTC/t33/src" --no-push 2>&1)"
RC=$?
assert_eq "empty time exit code" "$RC" "0"
assert_contains "empty time message" "$RES" "At least one time is required"
assert_eq "empty time author date" "$(at_of "$OUTC/t33/home/.Trash/src-1")" "$(epoch_of 20260920143000)"

echo "== 34. results table integrity =="
build_case t34
RES="$(printf 'c\n' | run_pick t34 "$OUTC/t34/src" --time "2026-09-20 14:30:00,15:45:00" --no-push 2>&1)"
ROWS="$(printf '%s\n' "$RES" | grep -cE '^  [0-9]+\) ')"
ROWS_WITH_SHA="$(printf '%s\n' "$RES" | grep -E '^  [0-9]+\) ' | grep -cE '[0-9a-f]{40}')"
assert_eq "result rows (two tables)" "$ROWS" "4"
assert_eq "rows carrying full commit ids" "$ROWS_WITH_SHA" "4"
SHA1="$(first_committed_sha "$RES")"
assert_sha "row commit id matches commit line" "$SHA1"
assert_contains "results title" "$RES" "===== Results ====="

echo "== 35. default commit message =="
build_case t35
RES="$(run_pick t35 "$OUTC/t35/src_remote" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "history repo exit code" "$RC" "0"
assert_contains "auto message line" "$RES" "Commit message: Update"
assert_eq "history repo subject" "$(subject_of "$OUTC/t35/src_remote")" "Update"

build_case t36
RES="$(run_pick t36 "$OUTC/t36/src_remote" --time "2026-09-20 14:30:00" --yes --select 1 --no-push -m "Custom message" 2>&1)"
RC=$?
assert_eq "explicit message exit code" "$RC" "0"
assert_contains "explicit message line" "$RES" "Commit message: Custom message"
assert_eq "explicit message subject" "$(subject_of "$OUTC/t36/src_remote")" "Custom message"

build_case t37
RES="$(run_pick t37 "$OUTC/t37/src" --time "2026-09-20 14:30:00" --yes --select 1 --no-push 2>&1)"
RC=$?
assert_eq "unborn repo exit code" "$RC" "0"
assert_contains "initial message line" "$RES" "Commit message: Initial commit"
assert_eq "unborn repo subject" "$(subject_of "$OUTC/t37/src")" "Initial commit"

echo "== 36. retry trashes copies and restarts from time entry =="
build_case t38
RES="$(printf '2026-09-20 14:30:00\n15:45:00\n\nr\n2026-10-01 09:00:00\n2026-10-02 10:00:00\n\n1\n1\n2\n' | run_pick t38 "$OUTC/t38/src" --no-push 2>&1)"
RC=$?
assert_eq "retry exit code" "$RC" "0"
assert_contains "retry message" "$RES" "Retry: moving all copies to the Trash"
assert_eq "retry asks for times twice" "$(printf '%s\n' "$RES" | grep -c 'Enter one commit time per line')" "2"
assert_exists "first attempt copy 1 trashed" "$OUTC/t38/home/.Trash/src-1"
assert_exists "first attempt copy 2 trashed" "$OUTC/t38/home/.Trash/src-2"
assert_exists "second attempt discarded copy trashed" "$OUTC/t38/home/.Trash/src-2 2"
assert_exists "original trashed" "$OUTC/t38/home/.Trash/src"
assert_gone "picked copy renamed" "$OUTC/t38/src-1"
assert_eq "kept repo uses new time" "$(at_of "$OUTC/t38/src")" "$(epoch_of 20261001090000)"
assert_eq "retry results tables" "$(printf '%s\n' "$RES" | grep -c '===== Results =====')" "3"
assert_eq "retry summary created" "$(sv "$RES" "Copies created")" "2"
assert_eq "retry summary committed" "$(sv "$RES" Committed)" "2"
assert_eq "retry summary trashed" "$(sv "$RES" Trashed)" "2"
assert_eq "retry summary errors" "$(sv "$RES" Errors)" "0"

echo "== 37. empty remote push sets upstream =="
build_case t39
RES="$(run_pick t39 "$OUTC/t39/src_empty_remote" --time "2026-09-20 14:30:00" --yes --select 1 2>&1)"
RC=$?
SHA1="$(first_committed_sha "$RES")"
assert_eq "empty remote push exit code" "$RC" "0"
assert_contains "empty remote push marker" "$RES" "[pushed]"
assert_eq "empty remote bare head" "$(git -C "$OUTC/t39/origin_empty.git" rev-parse refs/heads/main)" "$SHA1"
assert_eq "empty remote upstream set" "$(git -C "$OUTC/t39/src_empty_remote" rev-parse --abbrev-ref '@{u}')" "origin/main"
assert_eq "empty remote summary pushed" "$(sv "$RES" Pushed)" "1"
assert_eq "empty remote summary errors" "$(sv "$RES" Errors)" "0"

build_case t40
RES="$(printf '1\n1\n' | run_pick t40 "$OUTC/t40/src_empty_remote" --time "2026-09-20 14:30:00" 2>&1)"
RC=$?
assert_eq "empty remote confirm exit code" "$RC" "0"
assert_contains "confirm shows upstream command" "$RES" "git push -u origin main"

echo
echo "PASS: $PASS   FAIL: $FAIL"

chmod -R u+rwx "$OUT" 2>/dev/null
rm -rf "$OUT"
chmod -R u+rwx "$FIX" 2>/dev/null
rm -rf "$FIX"
echo "Test data cleaned."

[ "$FAIL" -eq 0 ] || exit 1
exit 0
