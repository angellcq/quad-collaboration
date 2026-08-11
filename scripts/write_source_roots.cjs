#!/usr/bin/env node
// write_source_roots.cjs — 以带中文注释的 JSON 格式写回 source_roots.json
// 供 run_agent.sh 调用，规避在 bash 内嵌 node -e 的多层引号/反斜杠转义问题。
// 输入（环境变量）：PROBED(探查行集)、PJROOT(项目根)、SRC_FILE(输出文件)
'use strict';
const fs = require('fs');

const PROBED = process.env.PROBED || '';
const PJROOT = process.env.PJROOT || '';
const SRC_FILE = process.env.SRC_FILE || '';
if (!SRC_FILE) { process.exit(0); }

const roots = { backend: [], frontend: [], other: [] };
for (const line of PROBED.split(/\r?\n/)) {
  if (!line) continue;
  const i = line.indexOf(':');
  if (i < 0) continue;
  const t = line.slice(0, i), p = line.slice(i + 1);
  if (roots[t]) roots[t].push(p);
}

const B = ['backend', 'frontend', 'other'];
const esc = s => String(s || '').replace(/\\/g, '/').replace(/"/g, '\\"');
const desc = {
  backend: '后端源码根（Java/Maven 等，含 pom.xml / build.gradle / *.java）——默认加入 codex 可写区',
  frontend: '前端源码根（前端 / 含 package.json + src 或 *.vue/*.jsx/*.tsx）——--add-root frontend 时加入',
  other: '其他源码根（非后端/前端，如脚本库/工具链）——归入 other 仍会加入可写区'
};

let out = '{\n';
out += '  // ===================================================================\n';
out += '  // 源码根配置文件（source_roots.json）\n';
out += '  // 用途：quad 流水线启动 codex 时，决定把哪些目录加入可写区（--add-dir）。\n';
out += '  // 生成：由 probe_src_roots.sh 自动探查生成；下次优先读本文件。\n';
out += '  // 修改：可直接编辑下方数组覆盖自动探查结果（改一次永久生效）。\n';
out += '  // 重新探查：删除本文件，下次启动 codex 时自动重新探查并重新生成。\n';
out += '  // 注意：本文件含 // 注释，读取端已支持剥离注释解析；标准 JSON 解析器会失败，属预期。\n';
out += '  // ===================================================================\n\n';
out += '  // —— 元信息（仅供人读，机器忽略）——\n';
out += '  "meta": { "generated_by": "probe_src_roots.sh", "project_root": "' + esc(PJROOT) + '", "tip": "可人工编辑；删除本文件后下次启动会重新自动探查" },\n\n';

for (let i = 0; i < B.length; i++) {
  const t = B[i];
  out += '  // —— ' + t + '：' + desc[t] + ' ——\n';
  out += '  "' + t + '": [\n';
  const arr = roots[t] || [];
  for (let j = 0; j < arr.length; j++) {
    out += '    "' + esc(arr[j]) + '"' + (j < arr.length - 1 ? ',' : '') + '\n';
  }
  out += '  ]' + (i < B.length - 1 ? ',' : '') + '\n\n';
}
out += '}\n';

fs.writeFileSync(SRC_FILE, out, 'utf8');
