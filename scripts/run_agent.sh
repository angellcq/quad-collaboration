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

AGENT="${1:?用法: run_agent.sh <agent> <project_dir> <prompt> [--background] [--add-dir <dir>] [--add-root <type>]}"
PROJECT_DIR="${2:?缺 project_dir}"
PROMPT="${3:?缺 prompt}"
MODE="foreground"
DRY_RUN=0
SANDBOX_ROOT=""
ADD_ROOT=""
# 解析可选参数：--background / --add-dir <dir> / --add-root <type> / --dry-run（可任意顺序）
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --background) MODE="background"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --add-dir) SANDBOX_ROOT="${2:?--add-dir 需要 <dir>}"; shift 2 ;;
    --add-root) ADD_ROOT="${2:?--add-root 需要 <type>}"; shift 2 ;;
    *) echo "❌ 未知参数: $1"; exit 9 ;;
  esac
done

_THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR_CANON="$(cd "$PROJECT_DIR" && pwd)"

# =====================================================================
# 自动源码根对准 —— 根治"实现了却无处落盘"（quad 并行 worktree 历史大坑）
#
# 背景：codex 的 workspace-write 可写区默认只绑到 project_dir（或绑错的 --add-dir），
#   真实源码树在可写区外 → codex 能执行却写不进源码（Access denied →"退出但无产出"）。
# 方案：启动前确定项目的"各类型源码根"，把相关根全加进可写区（--add-dir），不硬编码、不靠人记。
#
# 源码根来源（file-first）：
#   优先读 <project>/.orchestration/source_roots.json（人工可改，文件不存在才自动探查）：
#     { "backend":[...], "frontend":[...], "other":[...] }  绝对路径数组
#   文件不存在时调用 scripts/probe_src_roots.sh 自动探查，并把结果**写回**该文件
#   （下次直接读文件，人工改一次即可覆盖，永久生效）。
#
# 可写根解析优先级：
#   1) --add-dir <dir>：用户显式给根 → 直接用，不读文件、不探查（尊重显式意图）。
#   2) --add-root <type>：从 source_roots.json(或探查)取该类型根加入可写区。
#   3) ENV EXPLICIT_ADD_ROOTS=1：取全部类型(backend/frontend/other)根加入。
#   4) 默认：仅后端源码根(backend)（后端 Java 是多数 quad 目标，最安全）。
#  类型判定见 scripts/probe_src_roots.sh（pom.xml/package.json/build.gradle/csproj/src 自动分类）
# =====================================================================
ORCH_DIR="$PROJECT_DIR_CANON/.orchestration"
SRC_ROOTS_FILE="$ORCH_DIR/source_roots.json"

# —— 决策：需要读源码根集合吗？——
NEED_ROOTS=0
TARGET_TYPE=""
if [ -z "$SANDBOX_ROOT" ]; then
  NEED_ROOTS=1
  if [ -n "$ADD_ROOT" ]; then
    TARGET_TYPE="$ADD_ROOT"
    # EXPLICIT_ADD_ROOTS=1 或 ADD_ROOT=all → 全类型；否则用用户指定的类型
    if [ "${EXPLICIT_ADD_ROOTS:-0}" = "1" ] || [ "$ADD_ROOT" = "all" ]; then
      TARGET_TYPE="all"
    fi
  elif [ "${EXPLICIT_ADD_ROOTS:-0}" = "1" ]; then
    TARGET_TYPE="all"
  else
    TARGET_TYPE="backend"
  fi
fi

# —— 读取/生成源码根集合 ——
# 返回值：ROOTS_BY_TYPE 是 declare -A 关联数组，键为 backend/frontend/other，值为空格分隔的绝对路径
declare -A ROOTS_BY_TYPE=()
USING_FILE=0
if [ "$NEED_ROOTS" = "1" ] && [ -f "$SRC_ROOTS_FILE" ]; then
  if command -v node >/dev/null 2>&1; then
    # 用 node 解析（剥离 // 注释后 JSON.parse；文件含中文注释也可解析）
    J_FILE="$SRC_ROOTS_FILE"
    parsed="$(J_FILE="$J_FILE" node -e 'const fs=require("fs");
      let raw;try{raw=fs.readFileSync(process.env.J_FILE,"utf8")}catch(e){process.exit(0)}
      // 去注释：逐行剥离 // 注释，保留引号内 // （简单处理，够用）
      let clean="";
      const lines=raw.split(/\r?\n/);
      for(const ln of lines){ let s=ln; const ci=s.indexOf("//"); if(ci>=0)s=s.slice(0,ci); clean+=s+"\n"; }
      let f;try{f=JSON.parse(clean)}catch(e){process.exit(0)}
      for(const t of["backend","frontend","other"])(Array.isArray(f[t])?f[t]:[]).forEach(p=>console.log(t+":"+p));' 2>/dev/null)"
    if [ -n "$parsed" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        type="${line%%:*}"; path="${line#*:}"
        case "$type" in backend|frontend|other) ROOTS_BY_TYPE["$type"]="${ROOTS_BY_TYPE[$type]:-} $path" ;; esac
      done <<< "$parsed"
      USING_FILE=1
    fi
  fi
  [ "$USING_FILE" = "1" ] && echo "📂 读到源码根文件: $SRC_ROOTS_FILE（可人工编辑覆盖）" >&2
fi

# 解析失败或文件不存在 → 自动探查 + 写回文件
if [ "$USING_FILE" = "0" ]; then
  if [ -f "$SRC_ROOTS_FILE" ]; then
    echo "⚠️  source_roots.json 存在但解析失败，转自动探查覆盖..." >&2
  fi
  mkdir -p "$ORCH_DIR"
  PROBED="$("$_THIS_DIR/probe_src_roots.sh" "$PROJECT_DIR_CANON" 2>/dev/null)"
  PROBED="$PROBED" PJROOT="$PROJECT_DIR_CANON" SRC_FILE="$SRC_ROOTS_FILE" node "$_THIS_DIR/write_source_roots.cjs" 2>/dev/null
  # 从探查结果填充 ROOTS_BY_TYPE
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    type="${line%%:*}"; path="${line#*:}"
    case "$type" in backend|frontend|other) ROOTS_BY_TYPE["$type"]="${ROOTS_BY_TYPE[$type]:-} $path" ;; esac
  done <<< "$PROBED"
fi

# —— 按 TARGET_TYPE 组装 ADD_DIRS ——
# （NEED_ROOTS=1 才有可写根集合；否则走 --add-dir 显式分支）
if [ "$NEED_ROOTS" = "1" ]; then
  ADD_DIRS=()
  for t in backend frontend other; do
    [ "$TARGET_TYPE" != "all" ] && [ "$t" != "$TARGET_TYPE" ] && continue
    for r in ${ROOTS_BY_TYPE[$t]:-}; do
      rp="$(cd "$r" 2>/dev/null && pwd)" && [ -n "$rp" ] && ADD_DIRS+=("$rp")
    done
  done
  [ ${#ADD_DIRS[@]} -eq 0 ] && ADD_DIRS=("$PROJECT_DIR_CANON")
else
  # 显式 --add-dir：直接用
  SANDBOX_ROOT="$(cd "$SANDBOX_ROOT" && pwd)"
  ADD_DIRS=("$SANDBOX_ROOT")
fi
SANDBOX_ROOT="${ADD_DIRS[0]}"

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
  #   --add-dir …               → 把"真实源码树根"加进可写区（可多个，逐个 --add-dir）
  # 并行 git worktree 时，PROJECT_DIR 传 worktree 根，自动探查会把 worktree 内后端/前端源码根加进来，
  # 使 codex 按相对源码根路径写入的目标落在可写区内，避免只能写在 cwd 而源码树 `Access denied`。
  #
  # -c model_reasoning_effort=<high|medium|low>：codex 推理努力，默认 high（实现/重构任务受益于高推理），
  #   用环境变量 CODEX_REASONING 覆盖（想省 token/降速可设 medium）。
  codex)
    CMD=("$CLI_BIN" -C "$PROJECT_DIR_CANON" exec --sandbox workspace-write --skip-git-repo-check -m gpt-5-codex -c "model_reasoning_effort=${CODEX_REASONING:-high}")
    for ad in "${ADD_DIRS[@]}"; do CMD+=("--add-dir" "$ad"); done
    CMD+=("$PROMPT")
    ;;
  opencode) CMD=("$CLI_BIN" run --dir "$PROJECT_DIR_CANON" --auto "$PROMPT") ;;
  *) echo "❌ 未知 agent: $AGENT"; exit 3 ;;
esac

# —— 启动前打印完整 codex/opencode 命令（排查"退出但无产出"/可写区对不对时一眼核对）——
# 拼回人类可读的命令行（仅用于展示，不影响实际执行）
print_cmd() {
  local out=""
  for tok in "${CMD[@]}"; do
    # 含空格的 token（如任务卡多行内容、含空格路径）用单引号包起来，便于复制回终端复跑
    if [[ "$tok" == *[[:space:]]* ]]; then
      out+="'${tok}' "
    else
      out+="$tok "
    fi
  done
  printf '%s\n' "$out"
}

echo "▶️ 启动 $AGENT（mode=$MODE, reasoning=${CODEX_REASONING:-high}, add-dir: ${ADD_DIRS[*]}）"
echo "▶️ 完整命令:"
print_cmd

# —— dry-run：只打印不执行，用于排查可写区/模型/沙箱配置是否正确 ——
if [ "$DRY_RUN" = "1" ]; then
  echo "⏸️  --dry-run 模式：不执行，仅预览命令。"
  exit 0
fi

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

"${CMD[@]}"
EXIT_CODE=$?
echo ""
if [ $EXIT_CODE -eq 0 ]; then echo "✅ $AGENT 完成（exit 0）"; else echo "⚠️  $AGENT 结束，exit code = $EXIT_CODE"; fi
exit $EXIT_CODE
