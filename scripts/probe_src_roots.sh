#!/usr/bin/env bash
# probe_src_roots.sh — 自动探查项目的"源码根"，按 backend/frontend/other 三类分类。
#
# 目的（背景）：
#   quad 的 codex 使用 --sandbox workspace-write，其可写区默认只绑到传入的 project_dir。
#   当真实源码树在可写区外时会"实现了却无处落盘"（历史并行 worktree 大坑）。本脚本负责
#   自动找出"编码单元"（源码根），供 run_agent.sh 把相关根注入 codex 可写区（--add-dir）。
#
# 通用性原则（不绑死任何具体项目）：
#   · 判定"是否是源码根"靠【客观信号 + 多语言清单】，不靠记住某项目的目录名。
#   · 类型只分三档：backend(后端) / frontend(前端) / other(其他)。拿不准一律归 other，
#     宁多勿错 —— other 同样会被加进可写区，归类错误只是影响 --add-root 的过滤粒度。
#   · 探不到任何根时，由调用方 run_agent.sh 回退到 project_dir 本身，本脚本不去猜。
#
# 探查范围：project_dir 自身 + 其【一层】直接子目录（默认 Q2=A，浅探足够，快且不误抓
#   node_modules/.git 等深层工程）。
#
# 类型判定（弱启发，逐条命中即判，多条件按加权取最高置信）：
#   工程/构建清单入口（高置信，命中即判）：
#     backend : pom.xml 或 build.gradle/settings.gradle 或以 .java 源文件显著（含量 ≥ 3）
#     frontend: package.json 且目录下有 src/ 源码结构；或*.vue/*.jsx/*.tsx 显著
#     保守兜底: 之上都不命中但目录是源码根（含 src/ 或其他源文件）→ other
#
# 用法：
#   probe_src_roots.sh <search_root>
#   输出：每行一个已判定根，格式 `类型:绝对路径`
#   例：backend:/repo/backend、frontend:/repo/web、other:/repo/tools

set -uo pipefail

SEARCH_ROOT="${1:?用法: probe_src_roots.sh <search_root>}"
SEARCH_ROOT="$(cd "$SEARCH_ROOT" && pwd)"

# 只看 search_root 自身 + 一层直接子目录（浅探），跳过明显无关目录
declare -a TARGETS=("$SEARCH_ROOT")
while IFS= read -r d; do
  base="${d##*/}"
  case "$base" in
    \.*|node_modules|.git|target|dist|build|logs|coverage|doc|generated-code|deployment|disk|web-home|yms-home|Yuyimoxing) continue ;;
  esac
  TARGETS+=("$d")
done < <(find "$SEARCH_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

# 多语言工程清单：工程/清单入口文件 -> 该入口通常出现的目录才算编码单元
contain_file() { # $1=dir $2=glob  (success if any match)
  [ -n "$(find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | head -1)" ]
}

# 统计目录内某类源文件数量（一层，maxdepth 1；只认直接挂在该目录下的源码）
count_src() { # $1=dir $2=ext  e.g. java
  find "$1" -maxdepth 1 -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}
has_src_dir() { # 目录是否含常见源码子目录且里面有文件
  for sub in src lib app core tests server client; do
    [ -d "$1/$sub" ] && [ -n "$(find "$1/$sub" -type f 2>/dev/null | head -1)" ] && return 0
  done
  return 1
}
any_source_file() { # 目录顶层是否有任何"源代码扩展名"文件
  for ext in java js ts jsx tsx vue py go rs c cpp h hpp cs php rb kt scala dart sql sh; do
    [ -n "$(find "$1" -maxdepth 1 -type f -name "*.$ext" 2>/dev/null | head -1)" ] && return 0
  done
  return 1
}

is_backend() { # 高置信后端信号
  contain_file "$1" "pom.xml" && return 0
  contain_file "$1" "build.gradle" && return 0
  contain_file "$1" "settings.gradle" && return 0
  [ "$(count_src "$1" java)" -ge 3 ] && return 0
  return 1
}
is_frontend() {
  # package.json 是 monorepo 兜底易误判，结合 src/ 源码结构才给 frontend
  if contain_file "$1" "package.json" && has_src_dir "$1"; then return 0; fi
  # *.vue / *.jsx / *.tsx 显著
  v_n=$(find "$1" -maxdepth 1 -type f \( -name "*.vue" -o -name "*.jsx" -o -name "*.tsx" \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$v_n" -ge 1 ] && return 0
  return 1
}

declare -A SEEN=()
emit() {
  local type="$1" path="$2"
  [ -n "${SEEN[$path]:-}" ] && return
  SEEN[$path]=1
  echo "$type:$path"
}

for root in "${TARGETS[@]}"; do
  canon="$(cd "$root" 2>/dev/null && pwd)" || continue
  # 前提：是编码单元才有分类必要
  is_eng=false
  contain_file "$canon" "pom.xml" && is_eng=true
  contain_file "$canon" "build.gradle" && is_eng=true
  contain_file "$canon" "package.json" && is_eng=true
  contain_file "$canon" "go.mod" && is_eng=true
  contain_file "$canon" "Cargo.toml" && is_eng=true
  contain_file "$canon" "*.csproj" && is_eng=true
  contain_file "$canon" "*.sln" && is_eng=true
  contain_file "$canon" "requirements.txt" && is_eng=true
  contain_file "$canon" "pyproject.toml" && is_eng=true
  if [ "$is_eng" = false ]; then
    # 无工程/清单入口：仍可能是源码根（纯脚本/源码散落），看看有没有 src/ 或顶层源文件
    has_src_dir "$canon" && { emit other "$canon"; continue; }
    any_source_file "$canon" && { emit other "$canon"; continue; }
    continue   # 既无工程入口也无源码信号 → 不是编码单元，跳过
  fi

  # 有工程入口：分类
  if is_backend "$canon"; then emit backend "$canon"; continue; fi
  if is_frontend "$canon"; then emit frontend "$canon"; continue; fi
  emit other "$canon"
done
