#!/usr/bin/env node
// 契约校验的 node 实现。入口是 validate_contract.sh（本文件被同一目录的 .sh 调用）。
"use strict";
const fs = require("fs");
const path = require("path");

const [PROJECT_DIR, CONTRACT] = process.argv.slice(2);
let failures = 0, checks = 0;
const pass = () => checks++;
const fail = (m) => { failures++; console.log("❌ " + m); };
const note = (m) => console.log("ℹ️  " + m);
// 输出里带 "net fail" 时外层换算
const outFails = () => failures;

try {
  const c = JSON.parse(fs.readFileSync(CONTRACT, "utf8"));
  note("任务: " + (c.meta && c.meta.name ? c.meta.name : "<未命名>"));

  // 0) 契约版本过期检测：与 state.json 里记录的 contract_version 比对
  const contractVer = (c.meta && c.meta.version ? c.meta.version : "").toString().trim();
  if (!contractVer) {
    note("⚠️  contract.json 未声明 meta.version（应在 .orchestration/contract.json 写入 v1/v2/...）");
  } else {
    const statePath = path.join(PROJECT_DIR, ".orchestration", "state.json");
    let stateVer = "";
    if (fs.existsSync(statePath)) {
      try {
        const st = JSON.parse(fs.readFileSync(statePath, "utf8"));
        stateVer = (st.contract_version || "").toString().trim();
      } catch (e) { /* state 损坏则忽略 */ }
    }
    if (stateVer && stateVer !== contractVer) {
      note(`⚠️  契约版本不匹配：contract.json=${contractVer} 但 state.json=${stateVer}。疑似 codex/opencode 读到过期契约，建议核对。`);
    } else {
      note(`契约版本: ${contractVer}（state 一致）`);
    }
  }

  // 1) 文件存在性
  const files = (c.files || []).filter(x => x && x.path);
  for (const { path: rel } of files) {
    pass();
    const p = path.join(PROJECT_DIR, rel);
    if (fs.existsSync(p)) console.log("✅ 文件存在: " + rel);
    else fail("文件缺失: " + rel);
  }

  // 2) 接口签名一致性
  const ifs = (c.interfaces || []).filter(x => x && x.symbol);
  for (const { source, symbol, kind } of ifs) {
    pass();
    const p = path.join(PROJECT_DIR, source);
    if (!fs.existsSync(p)) { console.log("❌ 接口检查: 源文件不存在 " + source + "（跳过符号 " + symbol + "）"); fail("@@@"); continue; }
    const txt = fs.readFileSync(p, "utf8");
    const present = txt.includes(symbol);
    if (kind === "absent") {
      if (present) { console.log("❌ 接口检查: 应删除的符号仍存在 " + symbol + " @ " + source); fail("@@@"); }
      else console.log("✅ 符号已移除: " + symbol + " @ " + source);
    } else {
      if (present) console.log("✅ 接口存在: " + symbol + " @ " + source);
      else { console.log("❌ 接口缺失: " + symbol + "（应在 " + source + "）"); fail("@@@"); }
    }
  }

  // 3) 验收标准（Accept Criteria）：强制为带类型的机器可校验清单，编码方与验收方共用同一把尺子
  const ac = (c.acceptance || []).filter(x => x && typeof x === "object");
  if (ac.length === 0) {
    console.log("❌ 验收标准为空：contract.json 的 acceptance 至少需 1 条。");
    console.log("   说明：这是跨模型协作的『同一把尺子』。没有机器可验的验收标准，流水线不得进入阶段 2。");
    process.exit(1);
  }
  // 编号规整：AC-01, AC-02 ...（兼容已写死 id 的条目）
  ac.forEach((a, i) => {
    const id = (a.id || "").toString().trim() || ("AC-" + String(i + 1).padStart(2, "0"));
    const type = (a.type || "").toString().trim().toLowerCase();
    const title = a.title || a.expect || "";
    pass();
    let failReason = "";
    const runCmd = (cmd) => {
      try { return require("child_process").execSync(cmd, { cwd: PROJECT_DIR, stdio: ["ignore", "pipe", "inherit"] }); return true; }
      catch (e) { return false; }
    };
    switch (type) {
      case "test_cmd": {
        if (!a.cmd) { failReason = "缺少 cmd 字段"; break; }
        const ok = runCmd(a.cmd);
        if (ok) console.log(`✅ [${id}] 命令通过: ${a.cmd}`);
        else { console.log(`❌ [${id}] 命令未通过: ${a.cmd}`); failReason = "@@@"; }
        break;
      }
      case "file_exists": {
        const p = path.join(PROJECT_DIR, a.path || "");
        if (fs.existsSync(p)) console.log(`✅ [${id}] 文件存在: ${a.path}`);
        else { console.log(`❌ [${id}] 文件缺失: ${a.path}`); failReason = "@@@"; }
        break;
      }
      case "contains": {
        const p = path.join(PROJECT_DIR, a.file || "");
        if (!fs.existsSync(p)) { console.log(`❌ [${id}] 源文件缺失: ${a.file}`); failReason = "@@@"; break; }
        const txt = fs.readFileSync(p, "utf8");
        const text = (a.text || "").toString();
        if (txt.includes(text)) console.log(`✅ [${id}] ${a.file} 含文本: ${text.slice(0, 40)}`);
        else { console.log(`❌ [${id}] ${a.file} 缺文本: ${text.slice(0, 40)}`); failReason = "@@@"; }
        break;
      }
      case "absent":
      case "subjective": {
        console.log(`ℹ️  [${id}] 主观标准（阶段 4 人工核）: ${title || type}`);
        break;
      }
      default: {
        console.log(`ℹ️  [${id}] 未知类型 '${type}'，按主观标准处理（阶段 4 人工核）: ${title}`);
        break;
      }
    }
    if (failReason) fail(failReason);
  });
  note("验收标准 " + ac.length + " 条（机器可验的已自动跑通，subjective 留给阶段 4 人工核）");

  console.log("");
  if (failures === 0) { console.log("✅ 契约校验通过（净通过 " + checks + " 项）"); process.exit(0); }
  console.log("❌ 契约校验失败： " + failures + " 项未过");
  process.exit(1);
} catch (e) {
  console.log("❌ 契约文件解析失败: " + e.message);
  console.log("   检查 " + CONTRACT + " 是否为合法 JSON");
  process.exit(2);
}
