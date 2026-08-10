#!/usr/bin/env bash
# run_agent.sh — 启动 codex/opencode，前台阻塞或后台 `--background` 模式
# 用法: scripts/run_agent.sh <agent> <project_dir> "<prompt或任务卡路径>" [--background] [--sandbox-root <dir>]
#   agent: codex | opencode
#   --background: 后台启动，写日志到 <project_dir>/.orchestration/logs/<agent>.log，立即返回 PID
#   默认(无 --background)：前台阻塞，等待 agent 跑完返回 exit code（适合脚本联调用）
#   --sandbox-root <dir>: 【可选】给 codex 指定"可写沙箱根目录"。默认 = <project_dir>。
#       用于【并行 git worktree】场景：worktree 的真实源码树在 <worktree>/c-fi-hlj-ljkf-be/...，
#       而沙箱可写根若只绑定到 <worktree> 根的嵌套子目录会导致"退出但无处可写"。
#       此时应传 --sandbox-root <worktree 内实际源码树根>（例如 /path/wt-1/c-fi-hlj-ljkf-be），
#       显式把可写区对准源码树，避免 codex 只能写在 cwd 嵌套目录、真实文件落盘失败。
# 启动前先确保该 agent 已安装（缺失则自动 npm 安装，见 ensure_deps.sh）

set -uo pipefail

AGENT="${1:?用法: run_agent.sh <agent> <project_dir> <prompt> [--background] [--sandbox-root <dir>]}"
PROJECT_DIR="${2:?缺 project_dir}"
PROMPT="${3:?缺 prompt}"
MODE="foreground"
SANDBOX_ROOT=""
# 解析可选参数：--background / --sandbox-root <dir>（可任意顺序）
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --background) MODE="background"; shift ;;
    --sandbox-root) SANDBOX_ROOT="${2:?--sandbox-root 需要 <dir>}"; shift 2 ;;
    *) echo "❌ 未知参数: $1"; exit 9 ;;
  esac
done
# 默认沙箱根 = project_dir
SANDBOX_ROOT="${SANDBOX_ROOT:-$PROJECT_DIR}"
# 归一化（去掉尾部斜杠、解析 . / ..），确保 -C 与沙箱根不因路径写法不同而失配
SANDBOX_ROOT="$(cd "$SANDBOX_ROOT" && pwd)"
PROJECT_DIR_CANON="$(cd "$PROJECT_DIR" && pwd)"

# 确保外部依赖（agent 未装会自动安装）
_THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! bash "$_THIS_DIR/ensure_deps.sh" "$AGENT"; then
  echo "❌ $AGENT 缺失且自动安装失败，终止流水线。"
  echo "   可手动安装：$([ "$AGENT" = codex ] && echo 'npm i -g @openai/codex@latest' || echo 'npm i -g opencode-ai@latest')"
  exit 5
fi

cd "$PROJECT_DIR_CANON" || { echo "❌ 无法进入目录: $PROJECT_DIR"; exit 1; }

find_cli() {
  local name="$1" p
  p="$(command -v "$name" 2>/dev/null)"
  if [ -x "$p" ]; then echo "$p"; return 0; fi
  for base in "$HOME/AppData/Roaming/npm" "/c/Users/$(whoami)/AppData/Roaming/npm"; do
    if [ -f "$base/$name" ]; then echo "$base/$name"; return 0; fi
  done
  echo ""
}

CLI_BIN="$(find_cli "$AGENT")"
if [ -z "$CLI_BIN" ]; then echo "❌ 找不到 $AGENT，跳过。"; exit 2; fi

case "$AGENT" in
  # --sandbox-root 把 codex 的"可写区"对准真实源码树根；配合 -C（cwd）让 codex 的
  # 相对路径写入（c-fi-hlj-ljkf-be/...）落到可写区内，避免（并行 worktree 时）只能写在
  # cwd 的嵌套目录里、真实文件 `Access denied` 导致"退出但无产出"。
  # 注意：dummy 占位 `--` 后拼接，避免 codex 把 --sandbox-root 当自身参数理解错位。
  codex)    CMD=("$CLI_BIN" -C "$PROJECT_DIR_CANON" exec --sandbox workspace-write --skip-git-repo-check -m gpt-5-codex "$PROMPT" -- --sandbox-root "$SANDBOX_ROOT") ;;
  opencode) CMD=("$CLI_BIN" run --dir "$PROJECT_DIR_CANON" --auto "$PROMPT") ;;
  *) echo "❌ 未知 agent: $AGENT"; exit 3 ;;
esac

if [ "$MODE" = "background" ]; then
  LOG_DIR="$PROJECT_DIR_CANON/.orchestration/logs"
  mkdir -p "$LOG_DIR"
  LOG="$LOG_DIR/$AGENT.log"
  "${CMD[@]}" > "$LOG" 2>&1 &
  PID=$!
  echo "◐ $AGENT 已后台启动 (PID $PID)。日志: $LOG"
  echo "   ◈ 查看进度: tail -f '$LOG'"
  echo "◈ PID 已输出，请在 Claude 侧保存 PID 以等待完成。"
  exit 0
fi

echo "▶️ 启动 $AGENT ... (sandbox-root: $SANDBOX_ROOT)"
"${CMD[@]}"
EXIT_CODE=$?
echo ""
if [ $EXIT_CODE -eq 0 ]; then echo "✅ $AGENT 完成（exit 0）"; else echo "⚠️  $AGENT 结束，exit code = $EXIT_CODE"; fi
exit $EXIT_CODE
