#!/usr/bin/env bash
# ensure_deps.sh — 检查本技能依赖的外部工具，缺失则自动安装
# 本技能依赖的外部命令：
#   codex    → npm i -g @openai/codex@latest        AI 智能体（实现者）
#   opencode → npm i -g opencode-ai@latest          AI 智能体（测试/文档）
#   node     → 校验脚本(validate_contract)、state.sh 的 JSON 读写依赖 node
#   npm      → 上述 npm 安装命令的前置（装了 node 基本就有）
#   git      → 并行模式 git worktree 隔离用
#   sha256sum → state.sh files-hash 计算产物指纹（无则退回 node 计算，不强依赖）
#   jq       → 可选，validate_contract.sh 是纯 node 实现，不需要 jq
#
# 用法:
#   scripts/ensure_deps.sh                     # 全量检查
#   scripts/ensure_deps.sh codex               # 只检查/装 codex
#   scripts/ensure_deps.sh opencode
# 退出: 全部就绪 exit 0；任一安装失败 exit 1
set -uo pipefail

[[ "${1:-}" =~ ^(codex|opencode|all)?$ ]] || { echo "❌ 用法: ensure_deps.sh [codex|opencode|all]"; exit 3; }
_TARGET="${1:-all}"
FAILED=0

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_npm() {
  if ! have_cmd npm; then echo "❌ 缺少 npm。请先安装 Node.js ≥18（https://nodejs.org）后重试。"; return 1; fi
  if ! have_cmd node; then echo "⚠️  node 命令不可见（通常与 npm 同装）。用 npm 定位："; npm -v >/dev/null 2>&1 || { echo "❌ npm 也无法运行"; return 1; }; fi
}

ensure_codex() {
  if have_cmd codex; then echo "✅ codex 已安装 ($(codex --version 2>/dev/null || echo ?))"; return 0; fi
  echo "ℹ️  未检测到 codex，自动安装 npm 包 @openai/codex@latest ..."
  if ensure_npm; then
    npm i -g @openai/codex@latest && { echo "✅ codex 安装完成 ($(codex --version 2>/dev/null || echo ?))"; return 0; }
  fi
  echo "❌ codex 自动安装失败。可手动执行：npm i -g @openai/codex@latest"; return 1
}

ensure_opencode() {
  if have_cmd opencode; then echo "✅ opencode 已安装 ($(opencode --version 2>/dev/null || echo ?))"; return 0; fi
  echo "ℹ️  未检测到 opencode，自动安装 npm 包 opencode-ai@latest ..."
  if ensure_npm; then
    npm i -g opencode-ai@latest && { echo "✅ opencode 安装完成 ($(opencode --version 2>/dev/null || echo ?))"; return 0; }
  fi
  echo "❌ opencode 自动安装失败。可手动执行：npm i -g opencode-ai@latest"; return 1
}

# 并行/顺序模式都依赖 git（并行用 worktree，顺序也可作为产物基线）
if [ "$_TARGET" = "codex" ] || [ "$_TARGET" = "all" ]; then ensure_codex || FAILED=1; fi
if [ "$_TARGET" = "opencode" ] || [ "$_TARGET" = "all" ]; then ensure_opencode || FAILED=1; fi
if [ "$_TARGET" = "all" ]; then
  have_cmd npm && have_cmd node || { echo "⚠️  前置校验：脚本需要 npm+node"; }
  have_cmd git || echo "⚠️  git 未安装（并行 worktree 模式将无法用，建议安装）"
  # sha256sum 缺失时 state.sh 会自动退回 node 计算，不影响
fi

echo ""
if [ $FAILED -eq 0 ]; then echo "✅ 外部依赖就绪"; exit 0; else echo "❌ 部分依赖安装失败"; exit 1; fi
