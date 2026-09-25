# AGENTS.zh-CN.md — 可重现构建说明

本文件是 **GitCommitPick** 的可重现构建规范，供 AI 代理从零重建项目使用；
英文版见 `AGENTS.md`。

## 1. 项目布局

```
scripts/
  git_commit_pick.sh        # 主脚本（可执行）
docs/
  README.md                 # 英文
  README.zh-CN.md           # 中文
tests/
  create_test_fixture.sh    # 构造测试仓库（可执行）
  run_tests.sh              # 自动化断言（可执行）
AGENTS.md                   # 英文规范
AGENTS.zh-CN.md             # 本文件
opencode.json               # 注册 AGENTS.zh-CN.md 为指令文件
LICENSE                     # MIT
.gitignore
```

没有 Makefile、没有 CI。唯一验收标准：`bash -n` 通过、`tests/run_tests.sh`
全部 PASS、`--help` 正常渲染。

## 2. 硬性约束

- `#!/bin/bash`，兼容 macOS 自带 bash 3.2：不用关联数组、不用 `${var,,}`、
  不用 `mapfile`、不用 nameref；使用索引数组、`tr` 转大小写、`while read`、
  `[[ =~ ]]`。
- 不全局导出 `LC_ALL`（会破坏多字节输入的编辑）。仅在 `tr`/`sed` 等命令上
  局部设置 `LC_ALL=C`。
- 除文件头和 `# ---` 分节标记外不写注释。
- 依赖：`git`、`jq`、BSD `date`、`cp`、`mv`、`mkdir`、`basename`、`dirname`。
- 双语消息：`msg_en` / `msg_zh` 两个 `case` 表，键名（snake_case）完全一致；
  `msg key [printf 参数]` 分发。凡被 `msg`/`ask` 引用的键必须在两个表中都
  存在（测试套件会校验）。`usage()` 帮助文本仅英文。
- 所有提示通过 `ask` 从复制出的 fd 9（`exec 9<&0`）读取，保证管道输入可用；
  EOF 时打印 `input_closed` 并 exit 1。
- 不使用 `set -e`；每个失败都要检查并计入 `ERROR_N`。
- 不使用颜色，不写日志文件，结果只打印到 stdout。
- 展示给用户的路径都是规范路径（`pwd -P`）。

## 3. 模型

全局状态：`REPO_PATH`/`REPO_C`/`REPO_PARENT`/`REPO_NAME`、`TIMES_RAW[]`、
`TIME_CANON[]`（`YYYY-MM-DD HH:MM:SS`）、`TIME_EPOCH[]`、`MESSAGE`、
`MESSAGE_SET`、`PUSH`、`SELECT_SHA`、`YES`、`DRY_RUN`、`SAVE_DIR`、
`CONFIG_FILE`、`LANGUAGE`、`CLI_*`（是否由命令行给出）及 `CLI_*_VAL`、
`DEF_*` 默认值、计数器
`CREATED_N/COMMITTED_N/PUSHED_N/TRASHED_N/RENAMED_N/ERROR_N`，以及下标对齐的
`COPY_PATHS[]`、`COPY_TIMES[]`、`COPY_SHAS[]`。

流程：`parse_args` -> `load_config` -> `apply_cli` -> `config_snapshot` ->
语言提示 -> 仓库解析与校验 -> `detect_message` -> 时间解析 -> 目标预检 ->
（干跑在此退出）-> 复制并提交 -> 打印结果 -> 挑选 -> 确认 -> push -> 回收 ->
结果与汇总 -> 配置回存。

优先级：命令行 > 配置文件 > 默认值。`--yes` 跳过所有交互，必须提供
`--select`，且从不写配置。

## 4. 时间解析

`parse_time` 在全角归一化与首尾去空白后接受：

- 10 位时间戳（秒）、13 位时间戳（毫秒，截断到秒）
- `YYYY-MM-DD HH:MM[:SS]` 与 `YYYY-MM-DDTHH:MM[:SS]`（秒默认 00）
- `YYYYMMDDHHMM[SS]`、`YYYYMMDDHHMM.SS`（touch 风格）
- `HH:MM[:SS]`——与参照日期拼接

函数设置 `NORM`（本地规范 `YYYY-MM-DD HH:MM:SS`）、`NORM_EPOCH`、
`NORM_FULL`（输入是否自带日期）。校验方式：拼出 `YYYYMMDDHHMMSS`，用
`date -j -f "%Y%m%d%H%M%S" +%s` 解析，再用 `date -r` 往返比较；不一致即为
不可能日期。仅时分秒输入使用 `REF_DATE`，初始为今天，按列表顺序被每个完整
输入更新。交互输入逐行即时校验；非交互遇到非法输入直接 exit 1。

## 5. 复制与提交

- 先预检父目录下每个 `repo-i` 目标；任一已存在则整体中止，不复制任何内容。
- `cp -Rp "$REPO_C" "$dst"`；成功后追加到 `COPY_PATHS`/`COPY_TIMES`。复制
  失败但留下了部分目录时也要记录（它是脚本创建的路径，后续同样回收）。
- 提交：`GIT_AUTHOR_DATE`、`GIT_COMMITTER_DATE` 设为本地
  `YYYY-MM-DDTHH:MM:SS`，执行 `git commit -q -m "$MESSAGE"`，不执行
  `git add`。成功后把 40 位 `rev-parse HEAD` 存入 `COPY_SHAS`；失败存空串
  并计入错误。
- `detect_message` 在仓库校验之后运行：未指定提交信息（`MESSAGE_SET=no`）
  且仓库已有提交（`rev-parse --verify -q HEAD` 非空）时用 `Update`，否则用
  `Initial commit`。它会同步刷新 `SNAP_MESSAGE`，避免自动检测被当成配置
  变更。选定的提交信息会打印一次。
- 母本全程不被修改。

## 6. 挑选

菜单列出所有副本的序号、路径、时间与完整提交 id。可输入：序号（十进制）、
完整 40 位 id、唯一前缀（至少 7 位十六进制）、`c`/`cancel`、`r`/`redo`。
非交互用 `--select`。取消会把所有副本移入废纸篓（保留母本）并 exit 0。
重试会把所有副本移入废纸篓（保留母本），重置本次尝试状态，然后回到时间输入与
复制提交流程。废纸篓操作失败则中止并 exit 1。若没有任何副本提交成功则 exit 1。

## 7. push

除非 `--no-push`/`push=false`，push 选中副本。`prepare_push_cmd` 在挑选之后运行
（使确认界面能显示真实命令）并设置 `PUSH_ARGV`/`PUSH_CMD`：当前分支已有
upstream（`rev-parse --abbrev-ref --symbolic-full-name '@{u}'` 非空）时为普通
`git push`；没有 upstream 但存在 remote 时为 `git push -u <remote> <branch>`，
remote 优先 `origin`，否则取 `git remote` 的第一项，branch 取自
`symbolic-ref --short HEAD`（绝不硬编码）。无 remote 或 detached HEAD 保持普通
`git push`。执行 `git -C "$SELECTED_PATH" "${PUSH_ARGV[@]}"`（不重定向，让用户
看到 git 输出）。失败时打印 `push_failed` 并中止：不回收、母本不改名，exit 1。

## 8. 回收安全

- 回收集合严格等于 `COPY_PATHS` 去掉选中项，再加校验过的 `REPO_C`；取消
  （未选中）时为整个 `COPY_PATHS`。禁止通配符匹配（不得使用 `repo-*`）。
- 每次移入废纸篓前复核：绝对路径、仍是目录、父目录等于 `REPO_PARENT`；母本
  额外复核仍是同一仓库顶层。
- 用 `mv` 移入 `$HOME/.Trash`（不存在则创建），同名冲突用
  `collide_basename` 生成 Finder 风格名字（`name 2`、`name 3`；隐藏文件保留
  完整名字）。失败即中止，绝不退化为 `rm`。
- 顺序：其他副本 -> 母本 -> `mv 选中副本 REPO_C`。改名失败时母本已在废纸篓，
  提示可手动恢复。改名成功后更新 `COPY_PATHS` 对应项与 `SELECTED_PATH`。

## 9. 配置

Schema：`language`、`repoPath`、`times`（原始输入字符串数组）、`message`、
`push`（布尔）、`saveDir`。`message` 非空视为已指定（`MESSAGE_SET=yes`）；
自动检测得到的值在 `write_config` 中写为空字符串，使自动规则可跨配置往返
保留。用 `jq` 读取；注意 jq 的 `//` 会把 `false` 当作
空，必须用 `has("push")` 判断后比较 `tostring`。写入采用 mktemp + mv 原子
替换。回存流程：`--yes` 跳过；无变化或全为默认值时跳过；已有配置提供
更新/另存/不保存；无配置提供另存/不保存。默认保存路径为
`$SAVE_DIR/git_commit_pick.config.json`，否则为脚本根目录。

## 10. 测试（可重现门槛）

`tests/run_tests.sh` 使用手写断言（`ok`/`bad`/`assert_*`）、`build_case`
（把 fixture 复制到 `tests/out/<tag>`，并创建含 `.gitconfig` 与 `.Trash` 的
假 `HOME`）与 `run_pick`（用该 HOME 运行脚本）。Fixture
（`tests/create_test_fixture.sh`）：`src`（无 remote，已暂存文件 + 未跟踪
文件）、`src_remote`（基础提交已 push 到 bare `origin.git`，remote 为
`../origin.git` 且配置了 upstream，另有已暂存改动）、`src_empty_remote`
（基础提交，remote 为 `../origin_empty.git`，无 upstream，另有已暂存改动）、
`clean`、`unstaged`、`nongit`、`gitfile`（`.git` 是文件）、干扰目录
`src-old`、`sample_config.json`。

覆盖：语法检查；消息表键完整性（grep 提取键名，eval 两个 `case` 函数，要求
均非空）；全部校验错误；干跑零副作用；时间格式与参照日期继承；作者/提交
epoch 与提交信息；默认提交信息（无提交的仓库用 `Initial commit`，已有历史用
`Update`）与显式/配置指定的信息；只提交已暂存内容与未跟踪遗留；母本不变；
交互式完整 id 与前缀挑选；序号挑选；对 bare 仓库 push 成功；空远端 push 设置
upstream（`git push -u origin main`）；push 失败中止；
不匹配与非法挑选；取消（副本移入废纸篓、保留母本）；重试（副本移入废纸篓、
时间输入重新开始、最终汇总只反映最后一次尝试）；废纸篓冲突命名；目标已存在
预检；中文输出；配置往返；`--yes` 不写配置；全角输入；结果表完整性。结束时
清理 `tests/out` 与 `tests/fixture`。预期结果：`PASS: 178   FAIL: 0`。

## 11. 复现清单

1. 按第 2-9 节编写 `scripts/git_commit_pick.sh`。
2. 按第 10 节编写两个测试脚本。
3. 为三个脚本添加可执行权限。
4. 对所有 shell 文件执行 `bash -n`。
5. `tests/run_tests.sh` 必须输出 `PASS: 178   FAIL: 0`。
6. `./scripts/git_commit_pick.sh --help` 必须正常渲染。
7. 编写 `docs/README.md`、`docs/README.zh-CN.md`、`AGENTS.md`、
   `AGENTS.zh-CN.md`、`opencode.json`、`LICENSE`、`.gitignore`。
