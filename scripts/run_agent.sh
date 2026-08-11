#!/usr/bin/env bash
# run_agent.sh — 启动 codex/opencode，前台阻塞或后台 `--background` 模式
# 用法: scripts/run_agent.sh <agent> <project_dir> "<prompt或任务卡路径>" [--background] [--add-dir <dir>]
#   agent: codex | opencode
#   --background: 后台启动，写日志到 <project_dir>/.orchestration/logs/<agent>.log，立即返回 PID
#   默认(无 --background)：前台阻塞，等待 agent 跑完返回 exit code（适合脚本联调用）
#   --add-dir <dir>: 【可选】给 codex 追加一个"可写目录"（映射 codex exec 的 --add-dir）。默认 = <project_dir>。
#       用于【并行 git worktree】场景：-C 设 working root，--add-dir 追加 worktree 内"真实源码树根"
#       （例如 /path/wt-1/c-fi-hlj-ljkf-be），使 `workspace-write` 可写区同时覆盖 codex 要改的源码路径，
#       避免只能写在 cwd 而源码树 `Access denied` 导致"退出但无产出"。
#       codex exec 的 --add-dir 说明：Additional directories that should be writable alongside the primary workspace.
# 启动前先确保该 agent 已安装（缺失则自动 npm 安装，见 ensure_deps.sh）

set -uo pipefail

AGENT="${1:?用法: run_agent.sh <agent> <project_dir> <prompt> [--background] [--add-dir <dir>]}"
PROJECT_DIR="${2:?缺 project_dir}"
PROMPT="${3:?缺 prompt}"
MODE="foreground"
SANDBOX_ROOT=""
# 解析可选参数：--background / --add-dir <dir>（可任意顺序）
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --background) MODE="background"; shift ;;
    --add-dir) SANDBOX_ROOT="${2:?--add-dir 需要 <dir>}"; shift 2 ;;
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
  # codex 的"可写区" = workspace-write 沙箱，默认只覆盖 -C 指定目录。
  # 用法（关键）：
  #   -C "$PROJECT_DIR_CANON"   → working root（沙箱主可写区）
  #   --add-dir "$SANDBOX_ROOT" → 把"真实源码树根"加进可写区
  # 并行 git worktree 时，PROJECT_DIR 传 worktree 根，--add-dir 传 worktree 内实际源码根（如 <wt>/c-fi-hlj-ljkf-be），
  # 使 codex 按相对源码根路径写入的目标落在可写区内，避免只能写在 cwd 而源码树 `Access denied` 导致"退出但无产出"。
  codex)    CMD=("$CLI_BIN" -C "$PROJECT_DIR_CANON" exec --sandbox workspace-write --skip-git-repo-check -m gpt-5-codex --add-dir "$SANDBOX_ROOT" "$PROMPT") ;;
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

echo "▶️ 启动 $AGENT ... (add-dir: $SANDBOX_ROOT)"
"${CMD[@]}"
EXIT_CODE=$?
echo ""
if [ $EXIT_CODE -eq 0 ]; then echo "✅ $AGENT 完成（exit 0）"; else echo "⚠️  $AGENT 结束，exit code = $EXIT_CODE"; fi
exit $EXIT_CODE
