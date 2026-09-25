# Git 提交挑选（Git Commit Pick）

按给定的一组时间复制 git 仓库：每份副本用回填的时间（作者时间与提交时间）
创建一个 `Initial commit`（只提交已暂存内容），然后按完整提交 id 选中其中一份。
选中副本执行 `git push`（可用 `--no-push` 跳过），本次运行创建的其他所有副本
与母本一起移入废纸篓，最后把选中副本改名为母本原名。未选中任何副本时不会删除
任何东西。

```
scripts/
  git_commit_pick.sh        # 复制、回填提交、挑选、push、清理
docs/
  README.md                 # 英文
  README.zh-CN.md           # 中文
tests/
  create_test_fixture.sh    # 构造测试仓库
  run_tests.sh              # 自动化断言
AGENTS.md                   # 可重现构建说明（英文）
AGENTS.zh-CN.md             # 可重现构建说明（中文）
```

## 运行环境

- macOS（时间解析使用 BSD `date -j -f` / `date -r`）
- bash 3.2 及以上（兼容 macOS 自带 bash）
- `PATH` 中可用 `git` 与 `jq`

## 快速开始

```bash
# 先干跑：完整校验并打印计划
./scripts/git_commit_pick.sh ~/code/repo --time "14:30:00" --dry-run

# 交互：逐行输入时间，提交完成后在菜单里挑选副本
./scripts/git_commit_pick.sh ~/code/repo

# 三个时间生成三份副本，按序号选第 1 份，push 后回收其余副本与母本
./scripts/git_commit_pick.sh ~/code/repo \
    --time "2026-09-20 14:30:00,15:45:00,202609201700.00" --select 1

# 按完整提交 id 选中，跳过 push（回收与改名照常执行）
./scripts/git_commit_pick.sh ~/code/repo --time "2026-09-20 14:30:00" \
    --select 3b4e743071c37f5b96314bad57527aa589bd1bec --no-push
```

副本与原仓库同级，按时间顺序命名为 `repo-1`、`repo-2`……

## 工作原理

1. **校验。** 路径必须是目录、必须是仓库顶层（`.git` 必须是目录，链接工作区
   与子模块会被拒绝），`git status` 非空且存在已暂存内容。`/`、`$HOME`、
   `/System`、`/usr` 等关键系统路径会被拒绝。
2. **复制。** 每个时间执行一次 `cp -Rp`，按顺序生成 `repo-1 ... repo-N`。
   整个 `.git` 目录一并复制，因此每份副本的历史与索引完全一致。任一目标
   已存在时会在复制前整体中止。
3. **回填提交。** 每份副本执行 `git commit -m "<提交信息>"`，并把
   `GIT_AUTHOR_DATE`、`GIT_COMMITTER_DATE` 设为指定时间，`git log` 会显示
   该时间（本地时区）。提交信息可用 `-m` 指定；未指定时，若仓库还没有任何
   提交则默认 `Initial commit`，否则默认 `Update`。只提交已暂存内容，
   未跟踪文件保持未跟踪。母本不会被修改。
4. **挑选。** 菜单列出每份副本的序号、时间与完整 40 位提交 id。可输入序号、
   完整 id、唯一前缀（至少 7 位），或 `c` 取消。取消则把所有副本移入
   废纸篓、保留母本。输入 `r` 重试：把所有副本移入废纸篓、保留母本，然后
   重新输入时间并重新复制、提交。
5. **push。** 在选中副本推送：当前分支已有 upstream 时执行 `git push`；
   没有 upstream 但存在 remote（例如远端是空仓库）时执行
   `git push -u <remote> <branch>`（remote 优先 `origin`，分支取当前分支），
   从而建立 upstream。失败即中止：不回收任何目录、母本不改名。`--no-push`
   跳过此步。
6. **回收与改名。** 确认菜单（`--yes` 跳过）后，本次创建的其他所有副本与
   母本移入 `~/.Trash`（同名冲突按 Finder 规则改名为 `repo 2`、`repo 3`……），
   选中副本改名为母本原路径。

## 时间格式

时间精确到秒，按本地时区解释。

| 输入 | 示例 | 说明 |
|---|---|---|
| `YYYY-MM-DD HH:MM:SS` | `2026-09-20 14:30:00` | 也接受 ISO 的 `T` 分隔符 |
| `YYYY-MM-DD HH:MM` | `2026-09-20 14:30` | 秒默认补 `00` |
| `YYYYMMDDHHMM[SS][.SS]` | `20260920143000`、`202609201430.00` | `touch -t` 风格 |
| 时间戳 | `1789885800`、`1789885800123` | 10 位秒、13 位毫秒 |
| `HH:MM[:SS]` | `15:45:00` | 仅时分秒 |

仅时分秒的输入会与列表中最近一个完整日期（完整时间或时间戳）拼接；初始
参照日期是今天。例如 `--time "2026-09-20 14:30:00,15:45:00"` 生成
`2026-09-20 14:30:00` 与 `2026-09-20 15:45:00` 两份副本，而
`--time "15:45:00"` 使用今天。全角数字、冒号、横线、空格（中文输入法）
会先归一化再解析。

## 安全设计

- 只处理本次运行创建的确切路径与校验过的母本路径，绝不用通配符匹配，因此
  同级的 `repo-old`、`repo-backup` 等目录不会被误删。
- 每次移入废纸篓前都会复核：绝对路径、确为本次记录值、仍是目录、直接父目录
  符合预期；母本还会复核仍是同一仓库顶层。
- 回收使用 `mv` 移入 `~/.Trash`；失败（例如跨卷）只会报错中止，绝不退化为
  `rm`。
- push 失败或取消确认时，不删除任何目录。取消挑选（`c`）与重试（`r`）都只把
  副本移入废纸篓并保留母本；重试会重新要求输入时间。
- `--dry-run` 只做校验并打印计划，不复制、不提交、不 push、不回收、不改名。

## 配置

`-c/--config FILE` 读取（并按需更新）JSON 配置。命令行参数优先于配置；
`--yes` 从不写入配置。

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

运行中配置有变化时会询问：更新原配置文件、另存新的
`git_commit_pick.config.json`（保存到 `--saveDir`，默认脚本根目录）、或不保存。

## 非交互模式

```bash
./scripts/git_commit_pick.sh ~/code/repo \
    --time "2026-09-20 14:30:00,15:45:00" \
    --yes --select 3b4e743071c37f5b96314bad57527aa589bd1bec
```

`--yes` 跳过所有交互，因此必须提供 `--select`，且不会保存配置。
中文界面使用 `--language zh`。

## 测试

```bash
tests/create_test_fixture.sh   # 重建 tests/fixture
tests/run_tests.sh             # 自动化检查，失败时非零退出
```

测试在隔离目录与假 `HOME` 中执行 178 项检查，push 测试使用本地 bare
仓库 `origin.git` 与空远端 `origin_empty.git`。除 `tests/out` 与
`tests/fixture` 外不会修改任何内容。

## macOS 已知行为

- 路径会被规范化（`pwd -P`），因此 `/var/...` 会显示为
  `/private/var/...`，符号链接路径会解析为目标路径。
- 时间用 BSD `date -j -f` 解析，并通过 `date -r` 往返校验，2 月 30 日之类
  的不可能日期会被拒绝。
- git 会记录本地时区偏移，`git log` 显示的时间与你输入的完全一致。
- `~/.Trash` 同名冲突按 Finder 规则命名：`name 2`、`name 3`。
