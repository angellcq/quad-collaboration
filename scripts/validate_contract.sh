#!/usr/bin/env bash
# validate_contract.sh — 校验 .orchestration/contract.json（node 实现，无 jq 依赖）
# 这把"同一把尺子"——编码方(codex)、测试方(opencode)、验收方(Claude)全部照这份契约干活。
#   1) 约定文件存在性
#   2) 接口签名一致性  → 源码须包含契约声明的符号；kind=absent 则必须不包含
#   3) 验收标准(acceptance) 强制非空；带 type 的条目当场机器执行：
#        test_cmd / file_exists / contains 自动判 PASS|FAIL
#        subjective / 未知型 → 留给阶段 4 人工核
# 用法: scripts/validate_contract.sh <project_dir>
# 退出: 全过 exit 0；有未过项 exit 1；验收标准为空 exit 1（卡住流水线）
set -uo pipefail

PROJECT_DIR="${1:?用法: validate_contract.sh <project_dir>}"
CONTRACT="$PROJECT_DIR/.orchestration/contract.json"

if [ ! -f "$CONTRACT" ]; then
  echo "❌ 缺少契约文件: $CONTRACT"
  echo "   说明: 这是预防『任务理解错误』的第一道闸。请先在阶段1生成 contract.json 再启动 agent。"
  exit 1
fi

# node 一次性完成所有校验，输出带 exit 语义
node "/c/Users/luchunqing/.claude/skills/quad-collaboration/scripts/validate_contract.cjs" "$PROJECT_DIR" "$CONTRACT"
exit $?
