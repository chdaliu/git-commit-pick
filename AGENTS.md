# AGENTS.md — Reproducible build spec

Authoritative spec for rebuilding **GitCommitPick** from scratch with an AI
agent. `AGENTS.zh-CN.md` is the Chinese mirror of this file.

## 1. Project layout

```
scripts/
  git_commit_pick.sh        # the tool (executable)
docs/
  README.md                 # English
  README.zh-CN.md           # Chinese
tests/
  create_test_fixture.sh    # build the fixture repositories (executable)
  run_tests.sh              # automated assertions (executable)
AGENTS.md                   # this spec
AGENTS.zh-CN.md             # Chinese spec
opencode.json               # registers AGENTS.zh-CN.md as instructions
LICENSE                     # MIT
.gitignore
```

No Makefile and no CI. The only gates are `bash -n`, `tests/run_tests.sh`
(all PASS) and a working `--help`.

## 2. Hard constraints

- `#!/bin/bash`; compatible with the bash 3.2 shipped with macOS. No
  associative arrays, no `${var,,}`, no `mapfile`, no namerefs. Use indexed
  arrays, `tr` for case conversion, `while read`, `[[ =~ ]]`.
- Do not export `LC_ALL` globally (it breaks multi-byte input editing). Set
  `LC_ALL=C` per command for `tr`/`sed` only.
- No code comments beyond the file header and `# ---` section markers.
- Dependencies: `git`, `jq`, `date` (BSD), `cp`, `mv`, `mkdir`, `basename`,
  `dirname`.
- Bilingual messages: parallel `msg_en` / `msg_zh` `case` tables with
  identical `snake_case` keys; `msg key [printf args]` dispatches. Every key
  referenced by `msg`/`ask` must exist in both tables (the test suite
  verifies this). The `usage()` help text is English-only.
- Prompts go through `ask` reading from duplicated stdin fd 9 (`exec 9<&0`),
  so piped input works. EOF prints `input_closed` and exits 1.
- No `set -e`; every failure is checked and counted in `ERROR_N`.
- No colors, no log files. Results are printed to stdout only.
- Paths printed to the user are canonical (`pwd -P`).

## 3. Model

State globals: `REPO_PATH`/`REPO_C`/`REPO_PARENT`/`REPO_NAME`, `TIMES_RAW[]`,
`TIME_CANON[]` (`YYYY-MM-DD HH:MM:SS`), `TIME_EPOCH[]`, `MESSAGE`,
`MESSAGE_SET`, `PUSH`, `SELECT_SHA`, `YES`, `DRY_RUN`, `SAVE_DIR`,
`CONFIG_FILE`, `LANGUAGE`, `CLI_*` "was given" flags plus `CLI_*_VAL`,
`DEF_*` defaults, counters
`CREATED_N/COMMITTED_N/PUSHED_N/TRASHED_N/RENAMED_N/ERROR_N`, and the
index-aligned arrays `COPY_PATHS[]`, `COPY_TIMES[]`, `COPY_SHAS[]`.

Flow: `parse_args` -> `load_config` -> `apply_cli` -> `config_snapshot` ->
language prompt -> repo resolve+validate -> `detect_message` -> times resolve
-> target pre-check -> (dry-run exits here) -> copy+commit -> results -> pick
-> confirm -> push -> cleanup -> results+summary -> config save flow.

Precedence: CLI > config file > defaults. `--yes` skips all prompts, requires
`--select`, and never writes a config.

## 4. Time parsing

`parse_time` accepts, after full-width normalization and trimming:

- 10-digit epoch seconds, 13-digit epoch milliseconds (truncated to seconds)
- `YYYY-MM-DD HH:MM[:SS]` and `YYYY-MM-DDTHH:MM[:SS]` (seconds default 00)
- `YYYYMMDDHHMM[SS]`, `YYYYMMDDHHMM.SS` (touch style)
- `HH:MM[:SS]` — combined with the reference date

It sets `NORM` (canonical local `YYYY-MM-DD HH:MM:SS`), `NORM_EPOCH` and
`NORM_FULL` (`yes` when the input carries a date). Validation: build the
compact `YYYYMMDDHHMMSS`, parse with `date -j -f "%Y%m%d%H%M%S" +%s`, then
round-trip with `date -r` and compare; mismatch means an impossible date.
Time-only inputs use `REF_DATE`, initialized to today and updated by every
full input in list order. Interactive entry validates each line immediately;
non-interactive invalid input exits 1.

## 5. Copy and commit

- Pre-check every `repo-i` target in the parent directory; any existing path
  aborts before copying.
- `cp -Rp "$REPO_C" "$dst"`; on success append to `COPY_PATHS`/`COPY_TIMES`.
  On copy failure with a partial directory left behind, record it too (it is
  still a script-created path and gets cleaned later).
- Commit with `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` set to
  `YYYY-MM-DDTHH:MM:SS` (local), `git commit -q -m "$MESSAGE"`, no `git add`.
  Store the 40-character `rev-parse HEAD` in `COPY_SHAS`; on failure store an
  empty string and count an error.
- `detect_message` runs after repo validation: when no message was given
  (`MESSAGE_SET=no`) and the repository already has a commit (`rev-parse
  --verify -q HEAD` non-empty) the message becomes `Update`, otherwise
  `Initial commit`. It refreshes `SNAP_MESSAGE` so the auto-detected value is
  never treated as a config change. The chosen message is printed once.
- The original repository is never modified.

## 6. Selection

The menu lists all copies with index, path, time and full commit id. Accepted
input: index (decimal), full 40-character id, unique id prefix (>= 7 hex
characters), `c`/`cancel`, `r`/`redo` (retry). Non-interactive: `--select`
value. Cancel moves every copy to the Trash (keeping the original) and exits
0. Retry moves every copy to the Trash (keeping the original), resets the
attempt state, and loops back to time entry and copy+commit. A Trash failure
aborts with exit 1. If no copy committed successfully, exit 1.

## 7. Push

Unless `--no-push`/`push=false`, push the selected copy. `prepare_push_cmd`
runs after selection (so the confirmation can show the real command) and sets
`PUSH_ARGV`/`PUSH_CMD`: when the current branch already has an upstream
(`rev-parse --abbrev-ref --symbolic-full-name '@{u}'` non-empty) it is plain
`git push`; when it has none but a remote exists it is
`git push -u <remote> <branch>`, with `origin` preferred and otherwise the
first `git remote` entry, and the branch from `symbolic-ref --short HEAD`
(never hard-coded). No remote or detached HEAD keeps plain `git push`. Run
`git -C "$SELECTED_PATH" "${PUSH_ARGV[@]}"` with no redirection, so the user
sees git's output. On failure print `push_failed` and abort: nothing is
trashed, the original is not renamed, exit 1.

## 8. Cleanup safety

- The removal set is exactly `COPY_PATHS` minus the picked path, plus the
  validated `REPO_C`; on cancel (no pick) it is the whole `COPY_PATHS`. Never
  glob (`repo-*` is forbidden).
- Before each Trash move re-check: absolute path, still a directory, parent
  equals `REPO_PARENT`; the original is additionally re-checked as the same
  repository top level.
- `mv` into `$HOME/.Trash` (create if missing) with Finder-style collision
  names via `collide_basename` (`name 2`, `name 3`, hidden files keep their
  whole name). Failure aborts; never fall back to `rm`.
- Order: other copies -> original -> `mv picked REPO_C`. On rename failure the
  original is already in the Trash and the message says it can be restored
  manually. After a successful rename update the `COPY_PATHS` entry and
  `SELECTED_PATH` to the new path.

## 9. Config

Schema: `language`, `repoPath`, `times` (array of raw input strings),
`message`, `push` (boolean), `saveDir`. A non-empty `message` counts as
specified (`MESSAGE_SET=yes`); `write_config` stores an empty message when the
value was auto-detected, so the auto rule survives a round trip. Read with
`jq`; note that jq's `//`
operator treats `false` as empty, so test `has("push")` and compare
`tostring` instead. Write atomically (mktemp + mv). Save flow: skip under
`--yes`; skip when nothing changed or everything is default; existing config
offers update/save-new/don't; no config offers save-new/don't. Default save
path is `$SAVE_DIR/git_commit_pick.config.json`, else the script root.

## 10. Tests (reproducibility gate)

`tests/run_tests.sh` uses hand-rolled assertions (`ok`/`bad`/`assert_*`), a
`build_case` helper that copies the fixture into `tests/out/<tag>` with a fake
`HOME` containing `.gitconfig` and `.Trash`, and `run_pick` which runs the
script with that HOME. Fixture (`tests/create_test_fixture.sh`): `src` (no
remote, staged files + untracked file), `src_remote` (base commit pushed to
the bare `origin.git` with `../origin.git` as remote and an upstream branch,
plus a staged change), `src_empty_remote` (base commit, `../origin_empty.git`
as remote, no upstream, staged change), `clean`, `unstaged`, `nongit`,
`gitfile` (`.git` is a file), `src-old` decoy, `sample_config.json`.

Coverage: syntax checks; message-table key completeness (extract keys with
grep, eval the two `case` functions, require both non-empty); every
validation error; dry-run side-effect freedom; time formats and reference
date inheritance; author/committer epochs and subject; default message
(`Initial commit` on an unborn repository, `Update` when history exists) and
explicit/config messages; staged-only commit and
untracked leftovers; source untouched; interactive full-id and prefix
selection; index selection; push success against the bare repository;
empty-remote push setting the upstream (`git push -u origin main`); push
failure abort; no-match and invalid selections; cancel (copies moved to the
Trash, original kept); retry (copies moved to the Trash, time entry restarts,
final summary reflects the last attempt); Trash collision naming; target-exists
pre-check; Chinese output; config round-trip; `--yes` never writes config;
full-width input; results-table integrity. Cleanup removes `tests/out` and
`tests/fixture` at the end. Expected result: `PASS: 178   FAIL: 0`.

## 11. Reproduce checklist

1. Write `scripts/git_commit_pick.sh` per sections 2-9.
2. Write the two test scripts per section 10.
3. `chmod +x` all three scripts.
4. `bash -n` every shell file.
5. `tests/run_tests.sh` must print `PASS: 178   FAIL: 0`.
6. `./scripts/git_commit_pick.sh --help` must render.
7. Write `docs/README.md`, `docs/README.zh-CN.md`, `AGENTS.md`,
   `AGENTS.zh-CN.md`, `opencode.json`, `LICENSE`, `.gitignore`.
