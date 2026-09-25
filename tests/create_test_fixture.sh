#!/bin/bash
# create_test_fixture.sh
#
# Builds the test fixture for git_commit_pick.sh:
#   src          repository with staged changes (a.txt, sub/b.txt, 中文.txt)
#                and an untracked file (unstaged.txt); no remote
#   src_remote   repository with a base commit pushed to origin.git and an
#                upstream branch configured, plus a staged change
#   src_empty_remote
#                repository with a base commit and an origin remote pointing
#                at the empty origin_empty.git, no upstream, staged change
#   clean        repository with a commit and no pending changes
#   unstaged     repository with a modified tracked file, nothing staged
#   nongit       plain directory (not a repository)
#   gitfile      directory whose .git is a file (linked worktree shape)
#   origin.git   bare repository used as the push target
#   origin_empty.git
#                empty bare repository used as an empty-remote push target
#   src-old      decoy sibling that must never be trashed
#   sample_config.json   example configuration
#
# Usage:
#   tests/create_test_fixture.sh [output_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${1:-$SCRIPT_DIR/fixture}"

GIT_AUTHOR_NAME="GitCommitPick Fixture"
GIT_AUTHOR_EMAIL="fixture@example.com"
GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

mk() { mkdir -p "$1"; }
writef() { printf '%s\n' "$2" > "$1"; }
git_init() {
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
}
git_ident() {
  git -C "$1" config user.name "$GIT_AUTHOR_NAME"
  git -C "$1" config user.email "$GIT_AUTHOR_EMAIL"
}

if [ -e "$FIXTURE_DIR" ]; then
  echo "Removing existing fixture..."
  find "$FIXTURE_DIR" -depth -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$FIXTURE_DIR"
fi

echo "Building test fixture at: $FIXTURE_DIR"

# --- src: staged changes, untracked file, no remote ------------------------
mk "$FIXTURE_DIR/src/sub"
git_init "$FIXTURE_DIR/src"
git_ident "$FIXTURE_DIR/src"
writef "$FIXTURE_DIR/src/a.txt" "a"
writef "$FIXTURE_DIR/src/sub/b.txt" "b"
writef "$FIXTURE_DIR/src/中文.txt" "cn"
writef "$FIXTURE_DIR/src/unstaged.txt" "u"
git -C "$FIXTURE_DIR/src" add a.txt sub/b.txt "中文.txt"

# --- clean: commit, no pending changes ------------------------------------
mk "$FIXTURE_DIR/clean"
git_init "$FIXTURE_DIR/clean"
git_ident "$FIXTURE_DIR/clean"
writef "$FIXTURE_DIR/clean/x.txt" "x"
git -C "$FIXTURE_DIR/clean" add x.txt
git -C "$FIXTURE_DIR/clean" commit -q -m "base"

# --- unstaged: modification, nothing staged --------------------------------
mk "$FIXTURE_DIR/unstaged"
git_init "$FIXTURE_DIR/unstaged"
git_ident "$FIXTURE_DIR/unstaged"
writef "$FIXTURE_DIR/unstaged/x.txt" "x"
git -C "$FIXTURE_DIR/unstaged" add x.txt
git -C "$FIXTURE_DIR/unstaged" commit -q -m "base"
writef "$FIXTURE_DIR/unstaged/x.txt" "changed"

# --- nongit -----------------------------------------------------------------
mk "$FIXTURE_DIR/nongit"
writef "$FIXTURE_DIR/nongit/f.txt" "hi"

# --- gitfile: .git is a file ------------------------------------------------
mk "$FIXTURE_DIR/gitfile"
writef "$FIXTURE_DIR/gitfile/.git" "gitdir: ../nowhere"
writef "$FIXTURE_DIR/gitfile/f.txt" "hi"

# --- decoy sibling ----------------------------------------------------------
mk "$FIXTURE_DIR/src-old"
writef "$FIXTURE_DIR/src-old/keep.txt" "do-not-delete"

# --- origin.git + src_remote ------------------------------------------------
git init -q --bare "$FIXTURE_DIR/origin.git"
git -C "$FIXTURE_DIR/origin.git" symbolic-ref HEAD refs/heads/main
mk "$FIXTURE_DIR/src_remote"
git_init "$FIXTURE_DIR/src_remote"
git_ident "$FIXTURE_DIR/src_remote"
writef "$FIXTURE_DIR/src_remote/base.txt" "base"
git -C "$FIXTURE_DIR/src_remote" add base.txt
git -C "$FIXTURE_DIR/src_remote" commit -q -m "base"
git -C "$FIXTURE_DIR/src_remote" remote add origin ../origin.git
git -C "$FIXTURE_DIR/src_remote" push -q -u origin main
writef "$FIXTURE_DIR/src_remote/base.txt" "changed"
git -C "$FIXTURE_DIR/src_remote" add base.txt

# --- origin_empty.git + src_empty_remote ------------------------------------
git init -q --bare "$FIXTURE_DIR/origin_empty.git"
git -C "$FIXTURE_DIR/origin_empty.git" symbolic-ref HEAD refs/heads/main
mk "$FIXTURE_DIR/src_empty_remote"
git_init "$FIXTURE_DIR/src_empty_remote"
git_ident "$FIXTURE_DIR/src_empty_remote"
writef "$FIXTURE_DIR/src_empty_remote/base.txt" "base"
git -C "$FIXTURE_DIR/src_empty_remote" add base.txt
git -C "$FIXTURE_DIR/src_empty_remote" commit -q -m "base"
git -C "$FIXTURE_DIR/src_empty_remote" remote add origin ../origin_empty.git
writef "$FIXTURE_DIR/src_empty_remote/base.txt" "changed"
git -C "$FIXTURE_DIR/src_empty_remote" add base.txt

# --- sample config ----------------------------------------------------------
cat > "$FIXTURE_DIR/sample_config.json" <<EOF
{
  "language": "en",
  "repoPath": "$FIXTURE_DIR/src",
  "times": ["2026-09-20 14:30:00", "15:45:00"],
  "message": "Initial commit",
  "push": false,
  "saveDir": ""
}
EOF

echo
echo "Fixture created at: $FIXTURE_DIR"
echo "Sample config: sample_config.json"
