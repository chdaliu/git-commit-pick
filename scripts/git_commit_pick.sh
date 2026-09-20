#!/bin/bash
# git_commit_pick.sh
#
# Copies a git repository once per given commit time, creates a commit in
# every copy with the author and committer date backfilled to that time
# (staged content only), then lets you pick one copy by its full commit id:
# that copy is pushed (unless --no-push), every other copy created by this
# run and the original repository are moved to the Trash, and the picked
# copy is renamed to the original repository name. Cancelling the pick moves
# every copy to the Trash and keeps the original; retrying does the same and
# starts the time entry and copy/commit steps over.
#
# Usage:
#   ./git_commit_pick.sh <repoPath> --time "t1,t2,..." [options]
#
# bash 3.2 compatible (no associative arrays, no ${var,,} expansions).

# LC_ALL is intentionally NOT exported globally: a global "C" locale makes the
# terminal treat multi-byte input (Chinese) byte-by-byte, so backspace cannot
# erase a whole character. Commands that need byte/C semantics (tr, sed) set
# LC_ALL=C locally instead.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_CONFIG_NAME="git_commit_pick.config.json"
DEFAULT_MESSAGE="Initial commit"
DEFAULT_PUSH="yes"

# ---------------------------------------------------------------------------
# Configuration state
# ---------------------------------------------------------------------------
LANGUAGE="en"
REPO_PATH=""
TIMES_RAW=()
TIME_CANON=()
TIME_EPOCH=()
MESSAGE="$DEFAULT_MESSAGE"
MESSAGE_SET="no"
PUSH="$DEFAULT_PUSH"
SELECT_SHA=""
YES="no"
DRY_RUN="no"
SAVE_DIR=""
CONFIG_FILE=""
HAS_CONFIG="no"

CLI_REPO="no"
CLI_REPO_VAL=""
CLI_LANGUAGE="no"
CLI_LANGUAGE_VAL=""
CLI_TIMES="no"
CLI_TIMES_VALS=()
CLI_MESSAGE="no"
CLI_MESSAGE_VAL=""
CLI_PUSH="no"
CLI_PUSH_VAL=""
CLI_SELECT="no"
CLI_SELECT_VAL=""
CLI_SAVEDIR="no"
CLI_SAVEDIR_VAL=""

DEF_LANGUAGE="en"
DEF_MESSAGE="$DEFAULT_MESSAGE"
DEF_PUSH="$DEFAULT_PUSH"
DEF_SAVE_DIR=""

SNAP_LANGUAGE=""
SNAP_REPO=""
SNAP_TIMES=""
SNAP_MESSAGE=""
SNAP_PUSH=""
SNAP_SAVE_DIR=""

TIMES_RESOLVED="no"
REF_DATE=""
NORM=""
NORM_EPOCH=""
NORM_FULL="no"

REPO_C=""
REPO_PARENT=""
REPO_NAME=""
TRASH_DIR=""
TMPD=""

CREATED_N=0
COMMITTED_N=0
PUSHED_N=0
TRASHED_N=0
RENAMED_N=0
ERROR_N=0
START_SEC=0

COPY_PATHS=()
COPY_TIMES=()
COPY_SHAS=()

SELECTED_PATH=""
SELECTED_TIME=""
SELECTED_SHA=""

SYSTEM_GUARDS=(/System /Applications /Library /usr /bin /sbin /etc /private /var /Volumes /opt)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
lower() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

normalize_yn() {
  case "$(lower "$1")" in
    yes|y|true|1|on)  echo "yes";;
    no|n|false|0|off) echo "no";;
    *)                echo "$1";;
  esac
}

check_exit() {
  if [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "exit" ]; then
    echo "$(msg exit_msg)"
    exit 0
  fi
}

normalize_ascii() {
  printf '%s' "$1" | LC_ALL=C sed \
    -e 's/０/0/g;s/１/1/g;s/２/2/g;s/３/3/g;s/４/4/g;s/５/5/g;s/６/6/g;s/７/7/g;s/８/8/g;s/９/9/g' \
    -e 's/：/:/g;s/，/,/g;s/、/,/g;s/；/;/g;s/－/-/g;s/–/-/g;s/—/-/g;s/．/./g;s/／/\//g;s/　/ /g' \
    -e 's/ａ/a/g;s/ｂ/b/g;s/ｃ/c/g;s/ｄ/d/g;s/ｅ/e/g;s/ｆ/f/g;s/ｇ/g/g;s/ｈ/h/g;s/ｉ/i/g' \
    -e 's/ｊ/j/g;s/ｋ/k/g;s/ｌ/l/g;s/ｍ/m/g;s/ｎ/n/g;s/ｏ/o/g;s/ｐ/p/g;s/ｑ/q/g;s/ｒ/r/g' \
    -e 's/ｓ/s/g;s/ｔ/t/g;s/ｕ/u/g;s/ｖ/v/g;s/ｗ/w/g;s/ｘ/x/g;s/ｙ/y/g;s/ｚ/z/g' \
    -e 's/Ａ/A/g;s/Ｂ/B/g;s/Ｃ/C/g;s/Ｄ/D/g;s/Ｅ/E/g;s/Ｆ/F/g;s/Ｇ/G/g;s/Ｈ/H/g;s/Ｉ/I/g' \
    -e 's/Ｊ/J/g;s/Ｋ/K/g;s/Ｌ/L/g;s/Ｍ/M/g;s/Ｎ/N/g;s/Ｏ/O/g;s/Ｐ/P/g;s/Ｑ/Q/g;s/Ｒ/R/g' \
    -e 's/Ｓ/S/g;s/Ｔ/T/g;s/Ｕ/U/g;s/Ｖ/V/g;s/Ｗ/W/g;s/Ｘ/X/g;s/Ｙ/Y/g;s/Ｚ/Z/g'
}

canonicalize_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

jq_bool() {
  if [ "$1" = "yes" ]; then echo "true"; else echo "false"; fi
}

join_times() {
  local out="" t
  for t in "${TIMES_RAW[@]}"; do
    out="$out|$t"
  done
  printf '%s' "$out"
}

target_path() {
  printf '%s/%s-%s\n' "$REPO_PARENT" "$REPO_NAME" "$1"
}

# ---------------------------------------------------------------------------
# Message tables (English / Chinese)
# ---------------------------------------------------------------------------
msg_en() {
  case "$1" in
    lang_prompt)         echo "Display language";;
    lang_supported)      echo "Supported language inputs:";;
    lang_en)             echo "English";;
    lang_zh)             echo "Chinese";;
    repo_prompt)         echo "Repository path (a git work tree with pending changes)";;
    no_repo)             echo "No repository path provided (required).";;
    repo_not_dir)        echo "Path does not exist or is not a directory.";;
    repo_unsafe)         echo "Refusing to use a critical system path as the repository: %s";;
    repo_not_git)        echo "Not a git repository (no .git directory): %s";;
    repo_gitfile)        echo ".git is a file (linked worktree or submodule); refusing to copy it: %s";;
    repo_not_toplevel)   echo "Path is not the repository top level; the repository root is: %s";;
    repo_no_pending)     echo "git status is empty: there is nothing to commit.";;
    repo_no_staged)      echo "Nothing is staged; run git add first (only staged content is committed).";;
    repo_no_identity)    echo "Git user identity is unavailable (set user.name and user.email).";;
    times_intro)         echo "Enter one commit time per line (empty line finishes, 'clear' resets):";;
    times_current)       echo "Current times:";;
    times_cleared)       echo "Time list cleared.";;
    times_empty)         echo "At least one time is required.";;
    time_formats)        echo "Accepted time formats (seconds precision, local time):";;
    fmt_full)            echo "  YYYY-MM-DD HH:MM:SS      e.g. 2026-09-20 14:30:00";;
    fmt_minute)          echo "  YYYY-MM-DD HH:MM         seconds default to 00";;
    fmt_compact)         echo "  YYYYMMDDHHMM[SS][.SS]    e.g. 20260920143000 or 202609201430.00";;
    fmt_epoch)           echo "  epoch seconds/ms         e.g. 1758300000 or 1758300000000";;
    fmt_timeonly)        echo "  HH:MM[:SS]               uses the last full date, default today";;
    time_prompt)         echo "Time";;
    time_invalid)        echo "Invalid time format: %s";;
    time_added)          echo "Added: %s  ->  %s";;
    time_resolved)       echo "%s  ->  %s";;
    no_times)            echo "No commit times provided (required).";;
    select_title)        echo "Select the copy to keep:";;
    select_prompt)       echo "Copy to keep (index / full commit id / c=cancel / r=retry)";;
    select_invalid)      echo "Invalid selection.";;
    select_ambiguous)    echo "Commit id prefix matches more than one copy.";;
    select_nomatch)      echo "No copy matches: %s";;
    select_uncommitted)  echo "That copy has no successful commit and cannot be selected.";;
    select_required)     echo "Non-interactive mode requires --select <full commit id>.";;
    select_ok)           echo "Keeping: %s  (%s)";;
    select_cancelled)    echo "Selection cancelled.";;
    cancel_discarded)    echo "Every copy created by this run was moved to the Trash; the original repository is kept.";;
    cancel_aborted)      echo "Cancel aborted: a copy could not be moved to the Trash (items already in the Trash can be restored).";;
    select_redo)         echo "Retry: moving all copies to the Trash and keeping the original, so new times can be entered.";;
    redo_aborted)        echo "Retry aborted: a copy could not be moved to the Trash (items already in the Trash can be restored).";;
    no_commits)          echo "No copy was committed successfully; nothing can be selected.";;
    copy_exists)         echo "Target already exists: %s";;
    copy_exists_abort)   echo "Aborting before copying anything.";;
    copied)              echo "[created]";;
    committed)           echo "[committed]";;
    message_using)       echo "Commit message: %s";;
    copy_failed)         echo "[error] copy failed: %s";;
    commit_failed)       echo "[error] commit failed: %s";;
    dry_plan)            echo "[plan] copy %s -> %s  (%s)";;
    dry_run_on)          echo "DRY-RUN: no copy, commit, push, trash or rename will be performed.";;
    dry_run_done)        echo "Dry-run finished; nothing was changed.";;
    confirm_title)       echo "About to perform:";;
    confirm_push)        echo "push %s  (git push)";;
    confirm_no_push)     echo "push: skipped (--no-push)";;
    confirm_trash)       echo "move to Trash: %s";;
    confirm_rename)      echo "rename %s -> %s";;
    confirm_menu)        echo "1) Proceed  2) Cancel";;
    confirm_prompt)      echo "Your choice";;
    cancelled)           echo "Cancelled; nothing was changed.";;
    pushing)             echo "Pushing %s ...";;
    pushed)              echo "[pushed]";;
    push_skip)           echo "[skipped] push (--no-push)";;
    push_failed)         echo "Push failed; aborting. No copies were trashed and the original was not renamed.";;
    trashed)             echo "[trashed]";;
    trash_failed)        echo "[error] trash failed: %s";;
    trash_skip_missing)  echo "[skip] not found: %s";;
    trash_guard)         echo "[error] safety check failed, not trashing: %s";;
    trash_dir_failed)    echo "Could not create the Trash directory: %s";;
    cleanup_aborted)     echo "Aborted: the original repository and the picked copy were not touched (items already moved can be restored from the Trash).";;
    orig_changed)        echo "[error] the original repository no longer matches; not trashing: %s";;
    renamed)             echo "[renamed]";;
    rename_failed)       echo "Rename failed: %s -> %s (the original is in the Trash and can be restored manually).";;
    results_title)       echo "===== Results =====";;
    kept_mark)           echo "(kept)";;
    commit_failed_mark)  echo "(commit failed)";;
    final_label)         echo "Final";;
    summary_title)       echo "===== Execution Summary =====";;
    summary_created)     echo "Copies created";;
    summary_committed)   echo "Committed";;
    summary_pushed)      echo "Pushed";;
    summary_trashed)     echo "Trashed";;
    summary_renamed)     echo "Renamed";;
    summary_errors)      echo "Errors";;
    summary_elapsed)     echo "Elapsed";;
    cfg_repo)            echo "Repository path";;
    cfg_times)           echo "Times";;
    cfg_message)         echo "Commit message";;
    cfg_push)            echo "Push";;
    cfg_language)        echo "Language";;
    cfg_save_dir)        echo "Config save dir";;
    cfg_none)            echo "(none)";;
    save_ask)            echo "Configuration changed. Update or save it?";;
    save_ask_new)        echo "Configuration changed. Save it?";;
    save_update)         echo "Update the original config file";;
    save_new)            echo "Save as a new config";;
    save_dont)           echo "Don't save";;
    save_prompt)         echo "Your choice";;
    config_saved)        echo "Configuration saved to";;
    config_not_saved)    echo "Configuration not saved.";;
    config_no_change)    echo "Configuration unchanged - not saved.";;
    config_missing)      echo "Config file not found: %s";;
    invalid_input)       echo "Invalid input.";;
    invalid_language)    echo "Unsupported language: %s";;
    too_many_repos)      echo "Only one repository path is accepted: %s";;
    retry_or_exit)       echo "Too many invalid attempts. Retry or exit? (r=retry, e=exit)";;
    exit_msg)            echo "Exiting.";;
    input_closed)        echo "Input closed (EOF). Exiting.";;
    done)                echo "Done.";;
    jq_missing)          echo "jq command not found. Please install jq and retry.";;
    default_hint)        echo "[default: %s]";;
  esac
}

msg_zh() {
  case "$1" in
    lang_prompt)         echo "选择显示语言";;
    lang_supported)      echo "支持的语言输入：";;
    lang_en)             echo "英文";;
    lang_zh)             echo "中文";;
    repo_prompt)         echo "仓库路径（有未提交内容的 git 工作区）";;
    no_repo)             echo "未提供仓库路径（必填）。";;
    repo_not_dir)        echo "路径不存在或不是目录。";;
    repo_unsafe)         echo "拒绝使用关键系统路径作为仓库：%s";;
    repo_not_git)        echo "不是 git 仓库（没有 .git 目录）：%s";;
    repo_gitfile)        echo ".git 是文件（链接工作区或子模块），拒绝复制：%s";;
    repo_not_toplevel)   echo "路径不是仓库顶层，仓库根目录是：%s";;
    repo_no_pending)     echo "git status 为空：没有待提交内容。";;
    repo_no_staged)      echo "没有已暂存内容；请先 git add（只提交已暂存内容）。";;
    repo_no_identity)    echo "缺少 git 用户身份（请配置 user.name 与 user.email）。";;
    times_intro)         echo "逐行输入提交时间（空行结束，clear 清空重来）：";;
    times_current)       echo "当前时间列表：";;
    times_cleared)       echo "时间列表已清空。";;
    times_empty)         echo "至少需要输入一个时间。";;
    time_formats)        echo "支持的时间格式（精确到秒，本地时区）：";;
    fmt_full)            echo "  YYYY-MM-DD HH:MM:SS      例：2026-09-20 14:30:00";;
    fmt_minute)          echo "  YYYY-MM-DD HH:MM         秒默认补 00";;
    fmt_compact)         echo "  YYYYMMDDHHMM[SS][.SS]    例：20260920143000 或 202609201430.00";;
    fmt_epoch)           echo "  时间戳（秒/毫秒）        例：1758300000 或 1758300000000";;
    fmt_timeonly)        echo "  HH:MM[:SS]               使用最近一个完整日期，默认今天";;
    time_prompt)         echo "时间";;
    time_invalid)        echo "时间格式无效：%s";;
    time_added)          echo "已添加：%s  ->  %s";;
    time_resolved)       echo "%s  ->  %s";;
    no_times)            echo "未提供提交时间（必填）。";;
    select_title)        echo "选择要保留的副本：";;
    select_prompt)       echo "保留的副本（序号 / 完整提交id / c=取消 / r=重试）";;
    select_invalid)      echo "选择无效。";;
    select_ambiguous)    echo "提交id前缀匹配到多个副本。";;
    select_nomatch)      echo "没有副本匹配：%s";;
    select_uncommitted)  echo "该副本没有成功提交，无法选择。";;
    select_required)     echo "非交互模式必须提供 --select <完整提交id>。";;
    select_ok)           echo "保留：%s（%s）";;
    select_cancelled)    echo "已取消选择。";;
    cancel_discarded)    echo "本次创建的所有副本已移入废纸篓，母本保留。";;
    cancel_aborted)      echo "取消失败：有副本无法移入废纸篓（已移入的项可恢复）。";;
    select_redo)         echo "重试：把所有副本移入废纸篓并保留母本，以便重新输入时间。";;
    redo_aborted)        echo "重试已中止：有副本无法移入废纸篓（已移入的项可恢复）。";;
    no_commits)          echo "没有任何副本提交成功，无法选择。";;
    copy_exists)         echo "目标已存在：%s";;
    copy_exists_abort)   echo "在复制任何内容前中止。";;
    copied)              echo "[已创建]";;
    committed)           echo "[已提交]";;
    message_using)       echo "提交信息：%s";;
    copy_failed)         echo "[错误] 复制失败：%s";;
    commit_failed)       echo "[错误] 提交失败：%s";;
    dry_plan)            echo "[计划] 复制 %s -> %s（%s）";;
    dry_run_on)          echo "干跑模式：不会执行任何复制、提交、push、回收或改名。";;
    dry_run_done)        echo "干跑结束：未做任何修改。";;
    confirm_title)       echo "即将执行：";;
    confirm_push)        echo "push %s（git push）";;
    confirm_no_push)     echo "push：跳过（--no-push）";;
    confirm_trash)       echo "移入废纸篓：%s";;
    confirm_rename)      echo "改名 %s -> %s";;
    confirm_menu)        echo "1) 确认  2) 取消";;
    confirm_prompt)      echo "你的选择";;
    cancelled)           echo "已取消：未做任何修改。";;
    pushing)             echo "正在 push %s …";;
    pushed)              echo "[已推送]";;
    push_skip)           echo "[跳过] push（--no-push）";;
    push_failed)         echo "push 失败，已中止：未回收任何副本，母本也未改名。";;
    trashed)             echo "[已回收]";;
    trash_failed)        echo "[错误] 移入废纸篓失败：%s";;
    trash_skip_missing)  echo "[跳过] 不存在：%s";;
    trash_guard)         echo "[错误] 安全检查未通过，不回收：%s";;
    trash_dir_failed)    echo "无法创建废纸篓目录：%s";;
    cleanup_aborted)     echo "已中止：母本与选中副本未动（已移入废纸篓的项可恢复）。";;
    orig_changed)        echo "[错误] 母本已变化，不回收：%s";;
    renamed)             echo "[已改名]";;
    rename_failed)       echo "改名失败：%s -> %s（母本已在废纸篓，可手动恢复）。";;
    results_title)       echo "══════ 结果 ══════";;
    kept_mark)           echo "（保留）";;
    commit_failed_mark)  echo "（提交失败）";;
    final_label)         echo "最终";;
    summary_title)       echo "══════ 执行总结 ══════";;
    summary_created)     echo "已创建副本";;
    summary_committed)   echo "已提交";;
    summary_pushed)      echo "已push";;
    summary_trashed)     echo "已回收";;
    summary_renamed)     echo "已改名";;
    summary_errors)      echo "错误";;
    summary_elapsed)     echo "耗时";;
    cfg_repo)            echo "仓库路径";;
    cfg_times)           echo "时间列表";;
    cfg_message)         echo "提交信息";;
    cfg_push)            echo "push";;
    cfg_language)        echo "语言";;
    cfg_save_dir)        echo "配置保存目录";;
    cfg_none)            echo "（无）";;
    save_ask)            echo "配置已修改，是否更新或另存？";;
    save_ask_new)        echo "配置已修改，是否保存？";;
    save_update)         echo "更新原配置文件";;
    save_new)            echo "另存为新配置";;
    save_dont)           echo "不保存";;
    save_prompt)         echo "你的选择";;
    config_saved)        echo "配置已保存到";;
    config_not_saved)    echo "配置未保存。";;
    config_no_change)    echo "配置未变化，未保存。";;
    config_missing)      echo "配置文件不存在：%s";;
    invalid_input)       echo "输入无效。";;
    invalid_language)    echo "不支持的语言：%s";;
    too_many_repos)      echo "只接受一个仓库路径：%s";;
    retry_or_exit)       echo "连续输入无效。重试还是退出？（r=重试，e=退出）";;
    exit_msg)            echo "退出。";;
    input_closed)        echo "输入已关闭（EOF），退出。";;
    done)                echo "完成。";;
    jq_missing)          echo "未找到 jq 命令，请安装 jq 后重试。";;
    default_hint)        echo "[默认: %s]";;
  esac
}

msg() {
  local key="$1" s
  shift
  if [ "$LANGUAGE" = "zh" ]; then s="$(msg_zh "$key")"; else s="$(msg_en "$key")"; fi
  if [ -z "$s" ]; then s="$key"; fi
  if [ $# -gt 0 ]; then printf "$s" "$@"; else printf '%s' "$s"; fi
}

ask() {
  local key="$1" def="$2" p
  shift 2
  p="$(msg "$key" "$@")"
  if [ -n "$def" ]; then p="$p $(msg default_hint "$def")"; fi
  p="$p: "
  if ! read -e -r -p "$p" ASK_VAL <&9; then
    echo ""
    echo "$(msg input_closed)"
    exit 1
  fi
  check_exit
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: git_commit_pick.sh <repoPath> --time "t1,t2,..." [options]

Copies the given git repository once per given time, creates a commit in
every copy with the author and committer date backfilled to that time
(staged content only), then lets you pick one copy by its full commit id:
that copy is pushed, every other copy created by this run and the original
repository are moved to the Trash, and the picked copy is renamed to the
original repository name. Cancelling moves every copy to the Trash and keeps
the original; retrying does the same and starts over from time entry.

Options:
  -t, --time LIST           Commit times, comma separated or repeated
                            (interactive: entered one per line when omitted)
  -m, --message TEXT        Commit message (default: "$DEFAULT_MESSAGE" for a
                            repository without commits yet, "Update" otherwise)
  --select SHA              Copy to keep, by full commit id (non-interactive)
  --push yes|no             Push the picked copy before cleanup (default: yes)
  --no-push                 Same as --push no; cleanup and rename still happen
  -c, --config FILE         JSON config file to read from / write to
  --language en|zh          Display language (default: en)
  --saveDir DIR             Directory for saving the config (default: script dir)
  --dry-run                 Validate and print the plan, change nothing
  --yes                     Non-interactive: requires --select, never saves config
  -h, --help                Show this help

Accepted times (seconds precision, local time):
  YYYY-MM-DD HH:MM:SS       e.g. 2026-09-20 14:30:00
  YYYY-MM-DD HH:MM          seconds default to 00
  YYYYMMDDHHMM[SS][.SS]     e.g. 20260920143000 or 202609201430.00
  epoch                     10-digit seconds or 13-digit milliseconds
  HH:MM[:SS]                uses the last full date given, default today

Selection:
  The menu lists every copy with its index, time and full commit id. Enter
  the index, the full 40-character commit id, a unique id prefix, or c to
  cancel: every copy is moved to the Trash and the original is kept. Enter r
  to retry: every copy is moved to the Trash, the original is kept, and the
  time entry and copy/commit steps start over.

Cleanup safety:
  Only the copies created by this run and the original repository are ever
  moved to the Trash; paths are never matched with wildcards. An existing
  copy target (e.g. repo-1) aborts the run before anything is copied.
EOF
}

# ---------------------------------------------------------------------------
# Time parsing
# ---------------------------------------------------------------------------
# Parse $1 into $NORM ("YYYY-MM-DD HH:MM:SS", local), $NORM_EPOCH (seconds)
# and $NORM_FULL ("yes" for inputs that carry a date). Returns 1 if invalid.
parse_time() {
  local in y m d h mi s compact ep back prefix
  in="$(normalize_ascii "$1")"
  in="$(printf '%s' "$in" | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$in" ] || return 1

  if [[ "$in" =~ ^[0-9]{10}$ ]]; then
    NORM="$(date -r "$in" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)" || return 1
    [ -n "$NORM" ] || return 1
    NORM_EPOCH="$in"
    NORM_FULL="yes"
    return 0
  fi

  if [[ "$in" =~ ^[0-9]{13}$ ]]; then
    prefix="${in:0:10}"
    NORM="$(date -r "$prefix" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)" || return 1
    [ -n "$NORM" ] || return 1
    NORM_EPOCH="$prefix"
    NORM_FULL="yes"
    return 0
  fi

  y=""; m=""; d=""; h=""; mi=""; s=""
  if [[ "$in" =~ ^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})[[:space:]T]([0-9]{1,2}):([0-9]{1,2})(:([0-9]{2}))?$ ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[7]}"
    [ -z "$s" ] && s=00
    NORM_FULL="yes"
  elif [[ "$in" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{2})$ ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
    NORM_FULL="yes"
  elif [[ "$in" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
    NORM_FULL="yes"
  elif [[ "$in" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s=00
    NORM_FULL="yes"
  elif [[ "$in" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]]; then
    y="${REF_DATE%%-*}"
    m="${REF_DATE#*-}"; d="${m#*-}"; m="${m%%-*}"
    h="${BASH_REMATCH[1]}"; mi="${BASH_REMATCH[2]}"; s="${BASH_REMATCH[4]}"
    [ -z "$s" ] && s=00
    NORM_FULL="no"
  else
    return 1
  fi

  compact="$(printf '%04d%02d%02d%02d%02d%02d' "$((10#$y))" "$((10#$m))" "$((10#$d))" "$((10#$h))" "$((10#$mi))" "$((10#$s))")"
  ep="$(date -j -f "%Y%m%d%H%M%S" "$compact" +%s 2>/dev/null)" || return 1
  [ -n "$ep" ] || return 1
  back="$(date -r "$ep" +%Y%m%d%H%M%S 2>/dev/null)" || return 1
  [ "$back" = "$compact" ] || return 1
  NORM="$(date -r "$ep" "+%Y-%m-%d %H:%M:%S")"
  NORM_EPOCH="$ep"
  return 0
}

resolve_times() {
  local i v
  TIME_CANON=()
  TIME_EPOCH=()
  REF_DATE="$(date +%Y-%m-%d)"
  for i in "${!TIMES_RAW[@]}"; do
    v="${TIMES_RAW[$i]}"
    if ! parse_time "$v"; then
      echo "$(msg time_invalid "$v")"
      return 1
    fi
    TIME_CANON=("${TIME_CANON[@]}" "$NORM")
    TIME_EPOCH=("${TIME_EPOCH[@]}" "$NORM_EPOCH")
    if [ "$NORM_FULL" = "yes" ]; then
      REF_DATE="${NORM%% *}"
      if [ "$NORM" != "$v" ]; then
        echo "$(msg time_resolved "$v" "$NORM")"
      fi
    else
      echo "$(msg time_resolved "$v" "$NORM")"
    fi
  done
  TIMES_RESOLVED="yes"
  return 0
}

print_time_formats() {
  echo "$(msg time_formats)"
  echo "$(msg fmt_full)"
  echo "$(msg fmt_minute)"
  echo "$(msg fmt_compact)"
  echo "$(msg fmt_epoch)"
  echo "$(msg fmt_timeonly)"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
prompt_language() {
  local attempts=0 val
  while :; do
    echo "$(msg lang_supported)"
    echo "  en / english        -> $(msg lang_en)"
    echo "  zh / chinese / 中文  -> $(msg lang_zh)"
    ask lang_prompt "$LANGUAGE"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")             return 0;;
      en|english)     LANGUAGE="en"; return 0;;
      zh|chinese|中文) LANGUAGE="zh"; return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_repo() {
  local attempts=0
  while :; do
    ask repo_prompt ""
    REPO_PATH="$ASK_VAL"
    if [ -z "$REPO_PATH" ]; then
      echo "$(msg no_repo)"
    elif validate_repo; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_times() {
  local attempts=0 val
  echo "$(msg times_intro)"
  print_time_formats
  REF_DATE="$(date +%Y-%m-%d)"
  while :; do
    ask time_prompt ""
    val="$(printf '%s' "$ASK_VAL" | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$(lower "$val")" in
      "")
        if [ "${#TIMES_RAW[@]}" -gt 0 ]; then
          TIMES_RESOLVED="yes"
          return 0
        fi
        echo "$(msg times_empty)"
        continue;;
      clear)
        TIMES_RAW=()
        TIME_CANON=()
        TIME_EPOCH=()
        TIMES_RESOLVED="no"
        REF_DATE="$(date +%Y-%m-%d)"
        echo "$(msg times_cleared)"
        continue;;
    esac
    if parse_time "$val"; then
      TIME_CANON=("${TIME_CANON[@]}" "$NORM")
      TIME_EPOCH=("${TIME_EPOCH[@]}" "$NORM_EPOCH")
      if [ "$NORM_FULL" = "yes" ]; then
        REF_DATE="${NORM%% *}"
      fi
      TIMES_RAW=("${TIMES_RAW[@]}" "$val")
      echo "$(msg time_added "$val" "$NORM")"
      attempts=0
    else
      echo "$(msg time_invalid "$val")"
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3 ]; then
        ask retry_or_exit ""
        [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
        attempts=0
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Repository validation
# ---------------------------------------------------------------------------
validate_repo() {
  local g home_c top
  if [ ! -d "$REPO_PATH" ]; then
    echo "$(msg repo_not_dir)"
    return 1
  fi
  REPO_C="$(canonicalize_dir "$REPO_PATH")"
  [ -n "$REPO_C" ] || { echo "$(msg repo_not_dir)"; return 1; }
  if [ "$REPO_C" = "/" ]; then
    echo "$(msg repo_unsafe "$REPO_C")"
    return 1
  fi
  for g in "${SYSTEM_GUARDS[@]}"; do
    if [ "$REPO_C" = "$g" ]; then
      echo "$(msg repo_unsafe "$REPO_C")"
      return 1
    fi
  done
  home_c="$(canonicalize_dir "$HOME")"
  if [ -n "$home_c" ] && [ "$REPO_C" = "$home_c" ]; then
    echo "$(msg repo_unsafe "$REPO_C")"
    return 1
  fi
  if [ ! -e "$REPO_C/.git" ]; then
    echo "$(msg repo_not_git "$REPO_C")"
    return 1
  fi
  if [ ! -d "$REPO_C/.git" ]; then
    echo "$(msg repo_gitfile "$REPO_C")"
    return 1
  fi
  top="$(git -C "$REPO_C" rev-parse --show-toplevel 2>/dev/null)"
  top="$(canonicalize_dir "$top")"
  if [ -z "$top" ] || [ "$top" != "$REPO_C" ]; then
    echo "$(msg repo_not_toplevel "${top:-?}")"
    return 1
  fi
  if [ -z "$(git -C "$REPO_C" status --porcelain 2>/dev/null)" ]; then
    echo "$(msg repo_no_pending)"
    return 1
  fi
  if git -C "$REPO_C" diff --cached --quiet >/dev/null 2>&1; then
    echo "$(msg repo_no_staged)"
    return 1
  fi
  if ! git -C "$REPO_C" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    echo "$(msg repo_no_identity)"
    return 1
  fi
  REPO_PARENT="$(dirname "$REPO_C")"
  REPO_NAME="$(basename "$REPO_C")"
  return 0
}

# Pick the commit message when the user did not specify one: "Initial commit"
# for a repository without any commit yet, "Update" otherwise. The snapshot is
# refreshed so an auto-detected message never counts as a config change.
detect_message() {
  if [ "$MESSAGE_SET" = "yes" ]; then
    return 0
  fi
  if [ -n "$(git -C "$REPO_C" rev-parse --verify -q HEAD 2>/dev/null)" ]; then
    MESSAGE="Update"
  else
    MESSAGE="$DEFAULT_MESSAGE"
  fi
  SNAP_MESSAGE="$MESSAGE"
  return 0
}

# ---------------------------------------------------------------------------
# Copy and commit
# ---------------------------------------------------------------------------
check_targets_free() {
  local i dst found=0
  for i in "${!TIME_CANON[@]}"; do
    dst="$(target_path "$((i + 1))")"
    if [ -e "$dst" ]; then
      echo "$(msg copy_exists "$dst")"
      found=1
    fi
  done
  if [ "$found" = "1" ]; then
    echo "$(msg copy_exists_abort)"
    return 1
  fi
  return 0
}

dry_run_plan() {
  local i dst
  for i in "${!TIME_CANON[@]}"; do
    dst="$(target_path "$((i + 1))")"
    echo "$(msg dry_plan "$REPO_C" "$dst" "${TIME_CANON[$i]}")"
  done
}

copy_and_commit() {
  local i dst t iso sha
  for i in "${!TIME_CANON[@]}"; do
    dst="$(target_path "$((i + 1))")"
    t="${TIME_CANON[$i]}"
    iso="${t/ /T}"
    if cp -Rp "$REPO_C" "$dst" 2>/dev/null; then
      CREATED_N=$((CREATED_N + 1))
      COPY_PATHS=("${COPY_PATHS[@]}" "$dst")
      COPY_TIMES=("${COPY_TIMES[@]}" "$t")
      echo "$(msg copied) $dst"
    else
      ERROR_N=$((ERROR_N + 1))
      echo "$(msg copy_failed "$dst")"
      if [ -e "$dst" ]; then
        COPY_PATHS=("${COPY_PATHS[@]}" "$dst")
        COPY_TIMES=("${COPY_TIMES[@]}" "$t")
        COPY_SHAS=("${COPY_SHAS[@]}" "")
      fi
      continue
    fi
    if GIT_AUTHOR_DATE="$iso" GIT_COMMITTER_DATE="$iso" \
        git -C "$dst" commit -q -m "$MESSAGE" >/dev/null 2>&1; then
      sha="$(git -C "$dst" rev-parse HEAD 2>/dev/null)"
      COPY_SHAS=("${COPY_SHAS[@]}" "$sha")
      COMMITTED_N=$((COMMITTED_N + 1))
      echo "$(msg committed) $dst  $t  $sha"
    else
      COPY_SHAS=("${COPY_SHAS[@]}" "")
      ERROR_N=$((ERROR_N + 1))
      echo "$(msg commit_failed "$dst")"
    fi
  done
}

show_results() {
  local i sha mark
  echo "$(msg results_title)"
  for i in "${!COPY_PATHS[@]}"; do
    sha="${COPY_SHAS[$i]}"
    mark=""
    if [ -z "$sha" ]; then
      sha="-"
      mark="$(msg commit_failed_mark)"
    fi
    if [ -n "$SELECTED_PATH" ] && [ "${COPY_PATHS[$i]}" = "$SELECTED_PATH" ]; then
      mark="$(msg kept_mark)"
    fi
    printf '  %d) %s  %s  %s  %s\n' "$((i + 1))" "${COPY_PATHS[$i]}" "${COPY_TIMES[$i]}" "$sha" "$mark"
  done
  if [ -n "$SELECTED_PATH" ] && [ "$RENAMED_N" -eq 1 ]; then
    echo "$(msg final_label): $SELECTED_PATH  $SELECTED_TIME  $SELECTED_SHA"
  fi
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------
list_copies() {
  local i sha
  for i in "${!COPY_PATHS[@]}"; do
    sha="${COPY_SHAS[$i]}"
    [ -n "$sha" ] || sha="-"
    printf '  %d) %s  %s  %s\n' "$((i + 1))" "${COPY_PATHS[$i]}" "${COPY_TIMES[$i]}" "$sha"
  done
}

resolve_selection_token() {
  local token i matches=()
  token="$(lower "$(normalize_ascii "$1")")"
  case "$token" in
    c|cancel) return 2;;
    r|redo)   return 3;;
  esac
  if [[ "$token" =~ ^[0-9]+$ ]]; then
    token=$((10#$token))
    if [ "$token" -lt 1 ] || [ "$token" -gt "${#COPY_PATHS[@]}" ]; then
      echo "$(msg select_invalid)"
      return 1
    fi
    i=$((token - 1))
    if [ -z "${COPY_SHAS[$i]}" ]; then
      echo "$(msg select_uncommitted)"
      return 1
    fi
    SELECTED_PATH="${COPY_PATHS[$i]}"
    SELECTED_TIME="${COPY_TIMES[$i]}"
    SELECTED_SHA="${COPY_SHAS[$i]}"
    return 0
  fi
  if [[ "$token" =~ ^[0-9a-f]{7,40}$ ]]; then
    for i in "${!COPY_SHAS[@]}"; do
      case "${COPY_SHAS[$i]}" in
        "$token"*) matches=("${matches[@]}" "$i");;
      esac
    done
    if [ "${#matches[@]}" -eq 0 ]; then
      echo "$(msg select_nomatch "$1")"
      return 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
      echo "$(msg select_ambiguous)"
      return 1
    fi
    i="${matches[0]}"
    SELECTED_PATH="${COPY_PATHS[$i]}"
    SELECTED_TIME="${COPY_TIMES[$i]}"
    SELECTED_SHA="${COPY_SHAS[$i]}"
    return 0
  fi
  echo "$(msg select_invalid)"
  return 1
}

prompt_selection() {
  local attempts=0 rc
  echo "$(msg select_title)"
  list_copies
  while :; do
    ask select_prompt ""
    if [ -z "$ASK_VAL" ]; then
      echo "$(msg select_invalid)"
    else
      resolve_selection_token "$ASK_VAL"
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$(msg select_ok "$SELECTED_PATH" "$SELECTED_SHA")"
        return 0
      fi
      if [ "$rc" -eq 2 ]; then
        echo "$(msg select_cancelled)"
        return 2
      fi
      if [ "$rc" -eq 3 ]; then
        echo "$(msg select_redo)"
        return 3
      fi
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

# ---------------------------------------------------------------------------
# Confirmation, push, cleanup
# ---------------------------------------------------------------------------
confirm_destructive() {
  local i p attempts=0
  echo "$(msg confirm_title)"
  if [ "$PUSH" = "yes" ]; then
    echo "  $(msg confirm_push "$SELECTED_PATH")"
  else
    echo "  $(msg confirm_no_push)"
  fi
  for i in "${!COPY_PATHS[@]}"; do
    p="${COPY_PATHS[$i]}"
    [ "$p" = "$SELECTED_PATH" ] && continue
    [ -d "$p" ] || continue
    echo "  $(msg confirm_trash "$p")"
  done
  echo "  $(msg confirm_trash "$REPO_C")"
  echo "  $(msg confirm_rename "$SELECTED_PATH" "$REPO_C")"
  echo "$(msg confirm_menu)"
  while :; do
    ask confirm_prompt "1"
    case "$(lower "$ASK_VAL")" in
      ""|1|y|yes) return 0;;
      2|n|no|c|cancel) return 1;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

do_push() {
  if [ "$PUSH" != "yes" ]; then
    echo "$(msg push_skip)"
    return 0
  fi
  echo "$(msg pushing "$SELECTED_PATH")"
  if git -C "$SELECTED_PATH" push; then
    PUSHED_N=1
    echo "$(msg pushed)"
    return 0
  fi
  echo "$(msg push_failed)"
  ERROR_N=$((ERROR_N + 1))
  return 1
}

collide_basename() {
  local dir="$1" base="$2" name ext n
  case "$base" in
    .*) name="$base"; ext="";;
    *.*) name="${base%.*}"; ext=".${base##*.}";;
    *) name="$base"; ext="";;
  esac
  if [ ! -e "$dir/$base" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  n=2
  while [ -e "$dir/$name $n$ext" ]; do
    n=$((n + 1))
  done
  printf '%s %s%s\n' "$name" "$n" "$ext"
}

ensure_trash() {
  local h
  h="${HOME:-}"
  [ -n "$h" ] || return 1
  h="$(canonicalize_dir "$h")"
  [ -n "$h" ] || return 1
  TRASH_DIR="$h/.Trash"
  if [ ! -d "$TRASH_DIR" ]; then
    mkdir -p "$TRASH_DIR" 2>/dev/null || return 1
  fi
  return 0
}

trash_one() {
  local p="$1" kind="$2" base target top
  case "$p" in
    /*) ;;
    *) echo "$(msg trash_guard "$p")"; return 1;;
  esac
  if [ ! -d "$p" ]; then
    echo "$(msg trash_skip_missing "$p")"
    return 0
  fi
  if [ "$(dirname "$p")" != "$REPO_PARENT" ]; then
    echo "$(msg trash_guard "$p")"
    return 1
  fi
  if [ "$kind" = "orig" ]; then
    top="$(canonicalize_dir "$p")"
    if [ "$top" != "$REPO_C" ]; then
      echo "$(msg orig_changed "$p")"
      return 1
    fi
  fi
  base="$(basename "$p")"
  target="$TRASH_DIR/$(collide_basename "$TRASH_DIR" "$base")"
  if mv "$p" "$target" 2>/dev/null; then
    TRASHED_N=$((TRASHED_N + 1))
    echo "$(msg trashed) $p -> $target"
    return 0
  fi
  echo "$(msg trash_failed "$p")"
  return 1
}

do_cleanup() {
  local i p
  if ! ensure_trash; then
    echo "$(msg trash_dir_failed "$HOME/.Trash")"
    ERROR_N=$((ERROR_N + 1))
    return 1
  fi
  for i in "${!COPY_PATHS[@]}"; do
    p="${COPY_PATHS[$i]}"
    [ "$p" = "$SELECTED_PATH" ] && continue
    if ! trash_one "$p" copy; then
      ERROR_N=$((ERROR_N + 1))
      echo "$(msg cleanup_aborted)"
      return 1
    fi
  done
  if ! trash_one "$REPO_C" orig; then
    ERROR_N=$((ERROR_N + 1))
    echo "$(msg cleanup_aborted)"
    return 1
  fi
  if [ -e "$REPO_C" ]; then
    echo "$(msg rename_failed "$SELECTED_PATH" "$REPO_C")"
    ERROR_N=$((ERROR_N + 1))
    return 1
  fi
  if mv "$SELECTED_PATH" "$REPO_C" 2>/dev/null; then
    echo "$(msg renamed) $SELECTED_PATH -> $REPO_C"
    for i in "${!COPY_PATHS[@]}"; do
      if [ "${COPY_PATHS[$i]}" = "$SELECTED_PATH" ]; then
        COPY_PATHS[$i]="$REPO_C"
      fi
    done
    SELECTED_PATH="$REPO_C"
    RENAMED_N=1
    return 0
  fi
  echo "$(msg rename_failed "$SELECTED_PATH" "$REPO_C")"
  ERROR_N=$((ERROR_N + 1))
  return 1
}

discard_copies() {
  local i p
  if ! ensure_trash; then
    echo "$(msg trash_dir_failed "$HOME/.Trash")"
    ERROR_N=$((ERROR_N + 1))
    return 1
  fi
  for i in "${!COPY_PATHS[@]}"; do
    p="${COPY_PATHS[$i]}"
    if ! trash_one "$p" copy; then
      ERROR_N=$((ERROR_N + 1))
      return 1
    fi
  done
  COPY_PATHS=()
  COPY_TIMES=()
  COPY_SHAS=()
  return 0
}

redo_attempt() {
  local i p
  if ! ensure_trash; then
    echo "$(msg trash_dir_failed "$HOME/.Trash")"
    ERROR_N=$((ERROR_N + 1))
    echo "$(msg redo_aborted)"
    return 1
  fi
  for i in "${!COPY_PATHS[@]}"; do
    p="${COPY_PATHS[$i]}"
    if ! trash_one "$p" copy; then
      ERROR_N=$((ERROR_N + 1))
      echo "$(msg redo_aborted)"
      return 1
    fi
  done
  COPY_PATHS=()
  COPY_TIMES=()
  COPY_SHAS=()
  SELECTED_PATH=""
  SELECTED_TIME=""
  SELECTED_SHA=""
  CREATED_N=0
  COMMITTED_N=0
  PUSHED_N=0
  TRASHED_N=0
  RENAMED_N=0
  ERROR_N=0
  TIMES_RAW=()
  TIME_CANON=()
  TIME_EPOCH=()
  TIMES_RESOLVED="no"
  return 0
}

show_summary() {
  echo "$(msg summary_title)"
  echo "  $(msg summary_created): $CREATED_N"
  echo "  $(msg summary_committed): $COMMITTED_N"
  echo "  $(msg summary_pushed): $PUSHED_N"
  echo "  $(msg summary_trashed): $TRASHED_N"
  echo "  $(msg summary_renamed): $RENAMED_N"
  echo "  $(msg summary_errors): $ERROR_N"
  echo "  $(msg summary_elapsed): $(( $(date +%s) - START_SEC ))s"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
load_config() {
  local v line
  [ -n "$CONFIG_FILE" ] || return 0
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(msg config_missing "$CONFIG_FILE")"
    exit 1
  fi
  HAS_CONFIG="yes"
  v="$(jq -r '.language // empty' "$CONFIG_FILE" 2>/dev/null)"
  [ -n "$v" ] && LANGUAGE="$v"
  v="$(jq -r '.repoPath // empty' "$CONFIG_FILE" 2>/dev/null)"
  [ -n "$v" ] && REPO_PATH="$v"
  v="$(jq -r '.message // empty' "$CONFIG_FILE" 2>/dev/null)"
  if [ -n "$v" ]; then
    MESSAGE="$v"
    MESSAGE_SET="yes"
  fi
  v="$(jq -r 'if has("push") then (.push | tostring) else "" end' "$CONFIG_FILE" 2>/dev/null)"
  case "$v" in
    true)  PUSH="yes";;
    false) PUSH="no";;
  esac
  v="$(jq -r '.saveDir // empty' "$CONFIG_FILE" 2>/dev/null)"
  [ -n "$v" ] && SAVE_DIR="$v"
  TIMES_RAW=()
  while IFS= read -r line; do
    [ -n "$line" ] && TIMES_RAW=("${TIMES_RAW[@]}" "$line")
  done < <(jq -r '.times[]? // empty' "$CONFIG_FILE" 2>/dev/null)
  return 0
}

apply_cli() {
  [ "$CLI_LANGUAGE" = "yes" ] && LANGUAGE="$CLI_LANGUAGE_VAL"
  [ "$CLI_REPO" = "yes" ] && REPO_PATH="$CLI_REPO_VAL"
  [ "$CLI_TIMES" = "yes" ] && TIMES_RAW=("${CLI_TIMES_VALS[@]}")
  [ "$CLI_MESSAGE" = "yes" ] && MESSAGE="$CLI_MESSAGE_VAL"
  [ "$CLI_PUSH" = "yes" ] && PUSH="$CLI_PUSH_VAL"
  [ "$CLI_SELECT" = "yes" ] && SELECT_SHA="$CLI_SELECT_VAL"
  [ "$CLI_SAVEDIR" = "yes" ] && SAVE_DIR="$CLI_SAVEDIR_VAL"
  return 0
}

config_snapshot() {
  SNAP_LANGUAGE="$LANGUAGE"
  SNAP_REPO="$REPO_PATH"
  SNAP_TIMES="$(join_times)"
  SNAP_MESSAGE="$MESSAGE"
  SNAP_PUSH="$PUSH"
  SNAP_SAVE_DIR="$SAVE_DIR"
}

config_changed() {
  [ "$LANGUAGE" != "$SNAP_LANGUAGE" ] && return 0
  [ "$REPO_PATH" != "$SNAP_REPO" ] && return 0
  [ "$(join_times)" != "$SNAP_TIMES" ] && return 0
  [ "$MESSAGE" != "$SNAP_MESSAGE" ] && return 0
  [ "$PUSH" != "$SNAP_PUSH" ] && return 0
  [ "$SAVE_DIR" != "$SNAP_SAVE_DIR" ] && return 0
  return 1
}

all_defaults() {
  [ "$LANGUAGE" = "$DEF_LANGUAGE" ] || return 1
  [ "$REPO_PATH" = "" ] || return 1
  [ "${#TIMES_RAW[@]}" -eq 0 ] || return 1
  [ "$MESSAGE" = "$DEF_MESSAGE" ] || return 1
  [ "$PUSH" = "$DEF_PUSH" ] || return 1
  [ "$SAVE_DIR" = "$DEF_SAVE_DIR" ] || return 1
  return 0
}

write_config() {
  local dest="$1" tmp times_json dir msg_out=""
  dir="$(dirname "$dest")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi
  if [ "$MESSAGE_SET" = "yes" ]; then
    msg_out="$MESSAGE"
  fi
  if [ "${#TIMES_RAW[@]}" -gt 0 ]; then
    times_json="$(printf '%s\n' "${TIMES_RAW[@]}" | jq -R . | jq -s -c .)"
  else
    times_json="[]"
  fi
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)"
  [ -n "$tmp" ] || tmp="${dest}.tmp.$$"
  if jq -n --arg language "$LANGUAGE" --arg repoPath "$REPO_PATH" --arg message "$msg_out" \
        --argjson push "$(jq_bool "$PUSH")" --arg saveDir "$SAVE_DIR" --argjson times "$times_json" \
        '{language:$language, repoPath:$repoPath, times:$times, message:$message, push:$push, saveDir:$saveDir}' \
        > "$tmp" 2>/dev/null; then
    if mv "$tmp" "$dest" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

resolve_save_default() {
  if [ -n "$SAVE_DIR" ]; then
    printf '%s/%s\n' "$SAVE_DIR" "$DEFAULT_CONFIG_NAME"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$DEFAULT_CONFIG_NAME"
  fi
}

save_config_flow() {
  local dest choice attempts=0
  [ "$YES" = "yes" ] && return 0
  if ! config_changed; then
    echo "$(msg config_no_change)"
    return 0
  fi
  if all_defaults; then
    echo "$(msg config_no_change)"
    return 0
  fi
  if [ "$HAS_CONFIG" = "yes" ]; then
    echo "$(msg save_ask)"
    echo "  1) $(msg save_update)"
    echo "  2) $(msg save_new)"
    echo "  3) $(msg save_dont)"
    while :; do
      ask save_prompt ""
      case "$(lower "$ASK_VAL")" in
        1|update) dest="$CONFIG_FILE"; break;;
        2|new) dest="$(resolve_save_default)"; break;;
        3|n|no|"") echo "$(msg config_not_saved)"; return 0;;
      esac
      echo "$(msg invalid_input)"
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3 ]; then
        ask retry_or_exit ""
        [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
        attempts=0
      fi
    done
  else
    echo "$(msg save_ask_new)"
    echo "  1) $(msg save_new)"
    echo "  2) $(msg save_dont)"
    while :; do
      ask save_prompt ""
      case "$(lower "$ASK_VAL")" in
        1|y|yes|new) dest="$(resolve_save_default)"; break;;
        2|n|no|"") echo "$(msg config_not_saved)"; return 0;;
      esac
      echo "$(msg invalid_input)"
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3 ]; then
        ask retry_or_exit ""
        [ "$(lower "$ASK_VAL")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
        attempts=0
      fi
    done
  fi
  if write_config "$dest"; then
    echo "$(msg config_saved) $dest"
  else
    echo "$(msg config_not_saved)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  local parts p
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2;;
      --language)
        case "$(lower "$2")" in
          en|english) LANGUAGE="en";;
          zh|chinese|中文) LANGUAGE="zh";;
          *) echo "$(msg invalid_language "$2")"; exit 1;;
        esac
        CLI_LANGUAGE="yes"
        CLI_LANGUAGE_VAL="$LANGUAGE"
        shift 2;;
      -t|--time)
        IFS=',' read -r -a parts <<< "$2"
        for p in "${parts[@]}"; do
          [ -n "$p" ] && CLI_TIMES_VALS=("${CLI_TIMES_VALS[@]}" "$p")
        done
        CLI_TIMES="yes"
        shift 2;;
      -m|--message)
        MESSAGE="$2"
        if [ -n "$MESSAGE" ]; then
          MESSAGE_SET="yes"
        else
          MESSAGE_SET="no"
        fi
        CLI_MESSAGE="yes"
        CLI_MESSAGE_VAL="$MESSAGE"
        shift 2;;
      --select)
        SELECT_SHA="$2"
        CLI_SELECT="yes"
        CLI_SELECT_VAL="$2"
        shift 2;;
      --push)
        PUSH="$(normalize_yn "$2")"
        if [ "$PUSH" != "yes" ] && [ "$PUSH" != "no" ]; then
          echo "$(msg invalid_input)"
          exit 1
        fi
        CLI_PUSH="yes"
        CLI_PUSH_VAL="$PUSH"
        shift 2;;
      --no-push)
        PUSH="no"
        CLI_PUSH="yes"
        CLI_PUSH_VAL="no"
        shift;;
      --saveDir)
        SAVE_DIR="$2"
        CLI_SAVEDIR="yes"
        CLI_SAVEDIR_VAL="$2"
        shift 2;;
      --dry-run)
        DRY_RUN="yes"
        shift;;
      --yes)
        YES="yes"
        shift;;
      -h|--help)
        usage
        exit 0;;
      -*)
        echo "Unknown option: $1"
        exit 1;;
      *)
        if [ "$CLI_REPO" = "yes" ]; then
          echo "$(msg too_many_repos "$1")"
          exit 1
        fi
        CLI_REPO="yes"
        CLI_REPO_VAL="$1"
        REPO_PATH="$1"
        shift;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local rc
  exec 9<&0
  TMPD="$(mktemp -d 2>/dev/null)" || TMPD="/tmp/git_commit_pick_$$"
  trap 'rm -rf "$TMPD"' EXIT

  if ! command -v jq >/dev/null 2>&1; then
    echo "$(msg jq_missing)"
    exit 1
  fi

  parse_args "$@"
  load_config
  apply_cli
  config_snapshot

  if [ "$CLI_LANGUAGE" = "no" ] && [ "$YES" != "yes" ]; then
    prompt_language
  fi

  if [ "$YES" = "yes" ] && [ "$DRY_RUN" != "yes" ] && [ -z "$SELECT_SHA" ]; then
    echo "$(msg select_required)"
    exit 1
  fi

  if [ -z "$REPO_PATH" ]; then
    if [ "$YES" = "yes" ]; then
      echo "$(msg no_repo)"
      exit 1
    fi
    prompt_repo
  else
    validate_repo || exit 1
  fi

  detect_message
  echo "$(msg message_using "$MESSAGE")"

  while :; do
    REF_DATE="$(date +%Y-%m-%d)"
    if [ "${#TIMES_RAW[@]}" -eq 0 ] && [ "$YES" != "yes" ]; then
      prompt_times
    fi
    if [ "${#TIMES_RAW[@]}" -eq 0 ]; then
      echo "$(msg no_times)"
      exit 1
    fi
    if [ "$TIMES_RESOLVED" != "yes" ]; then
      resolve_times || exit 1
    fi

    if ! check_targets_free; then
      exit 1
    fi

    if [ "$DRY_RUN" = "yes" ]; then
      echo "$(msg dry_run_on)"
      dry_run_plan
      echo "$(msg dry_run_done)"
      exit 0
    fi

    START_SEC="$(date +%s)"
    copy_and_commit
    show_results

    if [ "$COMMITTED_N" -eq 0 ]; then
      echo "$(msg no_commits)"
      exit 1
    fi

    if [ -n "$SELECT_SHA" ]; then
      resolve_selection_token "$SELECT_SHA" || exit 1
      echo "$(msg select_ok "$SELECTED_PATH" "$SELECTED_SHA")"
      break
    fi

    prompt_selection
    rc=$?
    if [ "$rc" -eq 3 ]; then
      if ! redo_attempt; then
        exit 1
      fi
      continue
    fi
    if [ "$rc" -eq 2 ]; then
      if ! discard_copies; then
        echo "$(msg cancel_aborted)"
        show_summary
        exit 1
      fi
      echo "$(msg cancel_discarded)"
      show_summary
      exit 0
    fi
    break
  done

  if [ "$YES" != "yes" ]; then
    if ! confirm_destructive; then
      echo "$(msg cancelled)"
      exit 0
    fi
  fi

  if ! do_push; then
    show_results
    show_summary
    exit 1
  fi

  if ! do_cleanup; then
    show_results
    show_summary
    exit 1
  fi

  show_results
  show_summary
  save_config_flow
  echo "$(msg done)"

  if [ "$ERROR_N" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
