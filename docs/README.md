# Git Commit Pick（Git 提交挑选）

Copies a git repository once per given commit time, creates an `Initial
commit` in every copy with the author and committer date backfilled to that
time (staged content only), then lets you pick one copy by its full commit
id. The picked copy is pushed (unless `--no-push`), every other copy created
by the run and the original repository are moved to the Trash, and the picked
copy is renamed to the original repository name. Without a pick nothing is
removed.

```
scripts/
  git_commit_pick.sh        # copy, backdated commits, pick, push, cleanup
docs/
  README.md                 # English
  README.zh-CN.md           # Chinese
tests/
  create_test_fixture.sh    # build the fixture repositories
  run_tests.sh              # automated assertions
AGENTS.md                   # reproducible build spec (English)
AGENTS.zh-CN.md             # reproducible build spec (Chinese)
```

## Requirements

- macOS (BSD `date -j -f` / `date -r` are used for time parsing)
- bash 3.2 or newer (the script is compatible with the bash shipped with macOS)
- `git` and `jq` on `PATH`

## Quick start

```bash
# dry run first: validate everything and print the plan
./scripts/git_commit_pick.sh ~/code/repo --time "14:30:00" --dry-run

# interactive: enter times one per line, pick a copy from the menu
./scripts/git_commit_pick.sh ~/code/repo

# three copies, pick copy 1 by index, push it, trash the rest + original
./scripts/git_commit_pick.sh ~/code/repo \
    --time "2026-09-20 14:30:00,15:45:00,202609201700.00" --select 1

# pick by full commit id, skip the push (cleanup and rename still happen)
./scripts/git_commit_pick.sh ~/code/repo --time "2026-09-20 14:30:00" \
    --select 3b4e743071c37f5b96314bad57527aa589bd1bec --no-push
```

Every copy lands next to the original: `repo-1`, `repo-2`, ... in the same
order as the times you entered.

## How it works

1. **Validation.** The path must be a directory, the top level of a git
   repository (`.git` must be a directory, so linked worktrees and submodules
   are refused), `git status` must be non-empty and something must be staged.
   Critical system paths (`/`, `$HOME`, `/System`, `/usr`, ...) are refused.
2. **Copies.** One `cp -Rp` per time, in order, into `repo-1 ... repo-N`.
   The whole `.git` directory is copied, so every copy starts from the same
   history and index. If any target already exists the run aborts before
   anything is copied.
3. **Backdated commits.** Each copy gets `git commit -m "<message>"` with
   `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` set to the requested time, so
   `git log` shows that exact time in your local timezone. The message can be
   set with `-m`; when omitted it defaults to `Initial commit` for a
   repository without any commit yet and to `Update` otherwise. Only staged
   content is committed; untracked files stay untracked. The original
   repository is never modified.
4. **Pick.** The menu lists every copy with its index, time and full
   40-character commit id. Enter the index, the full id, a unique id prefix,
   or `c` to cancel. Cancelling moves every copy to the Trash and keeps the
   original. `r` retries the run: every copy is moved to the Trash, the
   original is kept, and the time entry and copy/commit steps start over.
5. **Push.** The picked copy is pushed: when its current branch already has an
   upstream it runs `git push`; when it has none but a remote exists (for
   example an empty remote) it runs `git push -u <remote> <branch>` (the
   remote is `origin` when present, the branch is the current one), setting
   the upstream. On failure the run aborts: nothing is trashed and the
   original is not renamed. `--no-push` skips this step.
6. **Cleanup and rename.** After a confirmation menu (skipped with `--yes`),
   every other copy created by this run and the original repository are moved
   to `~/.Trash` with Finder-style collision names (`repo 2`, `repo 3`, ...),
   and the picked copy is renamed to the original path.

## Time formats

Times are precise to seconds and interpreted in the local timezone.

| Input | Example | Notes |
|---|---|---|
| `YYYY-MM-DD HH:MM:SS` | `2026-09-20 14:30:00` | ISO `T` separator also accepted |
| `YYYY-MM-DD HH:MM` | `2026-09-20 14:30` | seconds default to `00` |
| `YYYYMMDDHHMM[SS][.SS]` | `20260920143000`, `202609201430.00` | `touch -t` style |
| epoch | `1789885800`, `1789885800123` | 10-digit seconds, 13-digit milliseconds |
| `HH:MM[:SS]` | `15:45:00` | time only |

A time-only input is combined with the last full date in the list (a full
datetime or an epoch). The initial reference date is today, so
`--time "2026-09-20 14:30:00,15:45:00"` creates copies at
`2026-09-20 14:30:00` and `2026-09-20 15:45:00`, while `--time "15:45:00"`
uses today. Full-width digits, colons, dashes and spaces (Chinese IME) are
normalized before parsing.

## Safety

- Only the exact paths created by the run and the validated original path are
  ever touched. Paths are never matched with wildcards, so a sibling like
  `repo-old` or `repo-backup` is never removed.
- Before every Trash move the path is re-checked: absolute, recorded by this
  run, still a directory, directly inside the expected parent; the original
  is additionally re-checked as the same repository top level.
- The Trash move is a plain `mv` to `~/.Trash`. If it fails (for example a
  cross-volume move) the script aborts; it never falls back to `rm`.
- If the push fails or the confirmation is cancelled, nothing is removed.
  Cancelling the selection (`c`) and retrying (`r`) both move only the copies
  to the Trash, keeping the original; retry asks for the times again.
- `--dry-run` performs validation and prints the plan without copying,
  committing, pushing, trashing or renaming.

## Config

`-c/--config FILE` reads (and optionally updates) a JSON config. CLI options
override config values; `--yes` never writes a config.

```json
{
  "language": "en",
  "repoPath": "/Users/me/code/repo",
  "times": ["2026-09-20 14:30:00", "15:45:00"],
  "message": "Initial commit",
  "push": true,
  "saveDir": ""
}
```

When a run changed the config, the script asks whether to update the original
file, save a new `git_commit_pick.config.json` (in `--saveDir`, default the
script root) or not save.

## Non-interactive mode

```bash
./scripts/git_commit_pick.sh ~/code/repo \
    --time "2026-09-20 14:30:00,15:45:00" \
    --yes --select 3b4e743071c37f5b96314bad57527aa589bd1bec
```

`--yes` skips every prompt, so `--select` is required; it never saves a
config. Use `--language zh` for the Chinese interface.

## Testing

```bash
tests/create_test_fixture.sh   # rebuild tests/fixture
tests/run_tests.sh             # automated checks, non-zero exit on failure
```

The suite runs 178 checks in isolated case directories with a fake `HOME`,
including a bare `origin.git` and an empty `origin_empty.git` for the push
tests. Nothing outside `tests/out` and `tests/fixture` is modified.

## Known macOS behavior

- `validate_repo` canonicalizes paths (`pwd -P`), so `/var/...` is reported
  as `/private/var/...` and symlinked paths resolve to their target.
- Times are parsed with BSD `date -j -f` and validated with a round trip
  through `date -r`, so impossible dates such as February 30 are rejected.
- Git stores the local timezone offset in the commit, so `git log` displays
  exactly the time you entered.
- `~/.Trash` collision names follow Finder conventions: `name 2`, `name 3`.
