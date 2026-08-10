#!/usr/bin/env bash
# state.sh — 读写 .orchestration/state.json，做进度恢复 + 防陈旧读取
# 为什么需要它：跨进程没有消息总线，Claude 中断/恢复或拿旧文件当新结果时最易出错。
# 用 state.json 记录"进度到了哪、各方读了哪个契约、各方产物 hash"，恢复时据此判断。
#
# 用法:
#   scripts/state.sh <project_dir> get <key>            # 读单个键
#   scripts/state.sh <project_dir> set <key> <value>    # 写单个键(原子写)
#   scripts/state.sh <project_dir> files-hash <filename># 打印文件当前 sha256(空则 missing)
#   scripts/state.sh <project_dir> status               # 打印整个状态
#
# 键约定（扁平命名，下划线分隔，避免路径解析歧义）：
#   phase                    当前阶段 "0|1|2|3|4"
#   codex_read_contract      codex 读取过的契约版本
#   opencode_read_contract   opencode 读取过的契约版本
#   contract_version         当前契约版本
#   codex_done / opencode_done  是否完成 (0/1)
#   codex_out_hash           codex 产物文件 hash（防陈旧读取）
set -uo pipefail

PROJECT_DIR="${1:?用法: state.sh <project_dir> <cmd> [args]}"
CMD="${2:?缺少命令: get|set|files-hash|status}"
STATE_DIR="$PROJECT_DIR/.orchestration"
STATE="$STATE_DIR/state.json"

mkdir -p "$STATE_DIR"
[ -f "$STATE" ] || echo '{}' > "$STATE"

# node 做扁平 JSON 读写（state 仅为扁平 KV，node 保证转义与原子写）
case "$CMD" in
  get)
    KEY="${3:?get 需要 key}"
    node -e 'const s=require(process.argv[1]);const k=process.argv[2];const v=s[k];console.log(v==null?"":(typeof v==="object"?JSON.stringify(v):v))' "$STATE" "$KEY"
    ;;
  set)
    KEY="${3:?set 需要 key}"; VAL="${4:?set 需要 value}"
    # 校验 key 只含字母数字下划线，防注入
    [[ "$KEY" =~ ^[A-Za-z0-9_]+$ ]] || { echo "❌ 非法 key: $KEY（仅允许 字母/数字/下划线）"; exit 4; }
    node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));s[process.argv[2]]=process.argv[3];fs.writeFileSync(process.argv[1],JSON.stringify(s,null,2))' "$STATE" "$KEY" "$VAL"
    ;;
  files-hash)
    F="${3:?files-hash 需要文件名}"
    P="$PROJECT_DIR/$F"
    if [ -f "$P" ]; then
      node -e 'const c=require("crypto"),fs=require("fs");console.log(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$P"
    else echo "missing"; fi
    ;;
  status)
    echo "── .orchestration/state.json ──"
    node -e 'const s=require(process.argv[1]);console.log(JSON.stringify(s,null,2))' "$STATE" 2>/dev/null || cat "$STATE"
    ;;
  *)
    echo "❌ 未知命令: $CMD (get|set|files-hash|status)"; exit 3;;
esac
