#!/usr/bin/env bash
# feedback_loop.sh — 处理 agent 的反馈/阻塞，带熔断防死循环
# 当一个 agent 报告 contact.html 问题（.orchestration/feedback.md 非空）时，Claude 调用本脚本：
#   1) 判断是否有新反馈、是否已超重试上限
#   2) 输出裁决结果（继续打回 / 升级给用户 / 终止）
# 本脚本只负责"读状态+判定"，不直接改 codex/opencode，真正的裁决动作由 Claude 执行。
#
# 用法:
#   scripts/feedback_loop.sh <project_dir>            # 判断是否有新反馈 & 是否超熔断
#   scripts/feedback_loop.sh <project_dir> consume    # 消耗(清空) feedback.md，重试计数+1
#   scripts/feedback_loop.sh <project_dir> reset      # 手动重置熔断计数
# 退出: 0=可继续处理反馈; 1=已超熔断需升级用户/终止; 2=无反馈
set -uo pipefail

PROJECT_DIR="${1:?用法: feedback_loop.sh <project_dir> [consume|reset]}"
CMD="${2:-check}"
STATE="$PROJECT_DIR/.orchestration/state.json"
FEEDBACK="$PROJECT_DIR/.orchestration/feedback.md"
MAX="${MAX_FEEDBACK_LOOPS:-3}"   # 熔断上限，默认 3 轮，可用环境变量覆盖
mkdir -p "$PROJECT_DIR/.orchestration"
[ -f "$STATE" ] || echo '{}' > "$STATE"

# 读 state.json 某键
getk() { node -e 'const s=require(process.argv[1]);console.log(s[process.argv[2]]||"")' "$STATE" "$1" 2>/dev/null; }
# 写 state.json 某键
setk() { node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));s[process.argv[2]]=process.argv[3];fs.writeFileSync(process.argv[1],JSON.stringify(s,null,2))' "$STATE" "$1" "$2"; }

case "$CMD" in
  check)
    # 1) 有反馈文件内容?
    if [ ! -s "$FEEDBACK" ]; then echo "ℹ️  无新反馈。"; exit 2; fi
    # 2) 是否超熔断?
    loops=$(getk "feedback_loops")
    loops=${loops:-0}
    if [ "$loops" -ge "$MAX" ]; then
      echo "❌ 反馈已累计 $loops 轮（上限 $MAX），判定为死循环风险。停止当前打回，升级给用户人工裁决。"
      exit 1
    fi
    echo "ℹ️  有反馈，已重试 $loops/$MAX 轮，可继续处理。反馈内容："
    sed 's/^/   /' "$FEEDBACK"
    exit 0
    ;;
  consume)
    # 消耗反馈并 +1 计数（每消耗一次算一轮尝试）
    loops=$(getk "feedback_loops"); loops=${loops:-0}; loops=$((loops+1))
    setk "feedback_loops" "$loops"
    : > "$FEEDBACK"   # 清空
    echo "✅ 已消耗反馈，重试计数 → $loops/$MAX"
    if [ "$loops" -ge "$MAX" ]; then
      echo "⚠️  已到上限，后续请升级给用户，不要再自动打回。"
    fi
    exit 0
    ;;
  reset)
    setk "feedback_loops" 0
    : > "$FEEDBACK"
    echo "✅ 已重置熔断计数与反馈。"
    exit 0
    ;;
  *) echo "❌ 未知命令: $CMD (check|consume|reset)"; exit 3;;
esac
