---
name: quad-collaboration
description: 多智能体流水线协作：Claude 规划→codex 实现→opencode 测试/文档→Claude 严格验收。默认顺序，复杂时自动切并行；异常时引入冲突解决 agent。触发词：/quad、多智能体协作、用 codex+opencode 一起干。
---

# Quad Collaboration — 多智能体分工流水线

**版本 v5.0**：v4 修复并行 worktree「codex 退出但无产出」；v4.1 将 run_agent.sh 的可写区参数规范为 `--add-dir`；**v5 新增「源码根自动对准」**——新增 `probe_src_roots.sh` 自动探查 backend/frontend/scripts/other 各类型源码根，run_agent.sh 据此把相关根自动注入 codex 可写区（`--add-dir`），不再依赖人为记忆传对目录，主目录/并行 worktree/顺序模式一律生效（详见「阶段 2 并行 worktree 的正确跑法」）。

> ⚠️ **并行 worktree 必读（v4 踩坑 + v5 根治）**：`run_agent.sh` 对 codex 使用 `--sandbox workspace-write`，其可写区由 `probe_src_roots.sh` 自动注入（默认后端 `backend`）。请勿再手写 `--add-dir`，否则覆盖自动对准逻辑。

将 **Claude Code**（我）、**codex**、**opencode** 组成一条严格分工流水线：默认**顺序**，遇独立子任务自动切**并行**；配合**冲突解决 agent** 处理并行合并冲突。每次任务按固定阶段执行，不得跳过、不得私自替代。

> **设计原理（协调架构/通信机制/知识共享/异常协同四维度）见 `README.md`。** 本文件是执行手册，README 是设计说明书。

## 外部依赖与自动安装

本技能启动前会**自动检查并安装**缺失的外部工具，实施时无需手动先装（发现缺了也能继续，除非安装失败）。

| 依赖 | 用途 | 自动安装命令 | 缺失时 |
|------|------|------------|--------|
| `codex` | 实现者(阶段2) | `npm i -g @openai/codex@latest` | `run_agent.sh` 自动 npm 装 |
| `opencode` | 测试/文档(阶段3) | `npm i -g opencode-ai@latest` | 同上 |
| `node` | validate_contract / state.sh 的 JSON 解析 | 需 Node.js ≥18（随 npm 装） | 提示先装 Node |
| `npm` | 上述 npm 安装的前置 | 随 Node | 提示先装 Node |
| `git` | 并行模式 git worktree 隔离 | — | 并行不可用，顺序可用 |
| `sha256sum` | state.sh 产物指纹 | —(可选) | 自动退回 node 计算 |
| `jq` | 校验参考 | —(可选) | 不需要，纯 node 实现 |

**自动安装触发点**：
- `scripts/ensure_deps.sh [codex|opencode|all]` —— 统一检测+安装，缺啥装啥
- `scripts/run_agent.sh codex|opencode ...` —— 启动 agent 前自动调用 ensure_deps 对应项，未装则装、装失败则终止并给出手动命令

> 各阶段开始前可先 `scripts/ensure_deps.sh` 一次，确保 npm+node+git 就绪，避免中途才发现缺工具。

## 配套脚本（scripts/）

| 脚本 | 作用 |
|------|------|
| `ensure_deps.sh` | 【新增】检查 codex/opencode/node/npm/git，缺失自动 npm 安装 |
| `probe_src_roots.sh` | 【v5】自动探查并分类各"源码根"（backend=含pom.xml / frontend=含package.json / backend-gradle / backend-dotnet / scripts / other=含src），输出 `类型:绝对路径`，不硬编码路径。供 run_agent.sh 把相关根注入 codex 可写区 |
| `run_agent.sh` | 启动 codex/opencode 前自动 ensure_deps，支持 `--background` 后台+日志/前台阻塞，等完成收集 exit code；启动 codex 时按 `--add-root <type>` 或默认(backend)/`EXPLICIT_ADD_ROOTS=1`(all) 自动把探查出的源码根注入 `--add-dir` |
| `validate_contract.sh` (+`.cjs`) | 校验 `contract.json`：文件存在性 + 接口签名一致（`call`必须含/`absent`必须无）+ 强制非空的验收标准(可机器执行 test_cmd/file_exists/contains) + 契约版本过期检测。exit0 契约一致，exit1 有偏差，exit2 JSON 损坏 |
| `state.sh` | 读写 `.orchestration/state.json`：`set/get <扁平键> <值>`、`files-hash <文件>`（sha256）、`status`。用于进度恢复 + 防陈旧读取 |
| `feedback_loop.sh` | 【新增】检查 agent 的 `feedback.md`，裁决阻塞归属，带熔断(默认3轮)防死循环：`check`/`consume`/`reset` |

## 角色与职责矩阵

| 代号 | 工具 | 唯一职责 | 禁止 |
|------|------|---------|------|
| **Claude**（编排者+验收者） | 本体 Claude Code | 需求拆解、任务卡生成、整合打补丁、**独立验收、写验收报告** | 禁止直接实现核心功能（可做胶水/接口层，但业务逻辑必须委派） |
| **codex**（实现者） | `codex exec` | 读任务卡，实现主功能/业务逻辑/后端/算法，可执行、跑自测 | 禁止修改测试和文档相关文件（由 opencode 产出）；自测仅作过程参考，不替代阶段4验收 |
| **opencode**（测试/文档者） | `opencode run` | 为 codex 产出写单测、跑测试、补 README/注释 | 禁止修改业务实现代码（只能读） |

## 触发条件

用户输入以下任一句即激活此技能：
- `/quad <需求描述>`
- "用多智能体"
- "codex opencode 一起干"
- "三智能体协作"

## 运行模式：顺序（默认） vs 并行

**默认顺序流水线（下方阶段 0-4）。** 但 Claude 须在阶段 1 拆解时判一次"该顺序还是并行"：

| 判定 | 顺序（默认） | 并行 |
|------|------------|------|
| 判断标准 | 子任务间有依赖、需链式产出（实现→测试）、需求边界不清 | 子任务**互相独立**、改**不同文件**、无共享状态 |
| 流程 | 阶段0→1→2(codex)→3(opencode)→4 | 阶段0→1→ **N 条独立流水线各跑 codex→opencode** →4 |
| 冲突风险 | 低 | 高（需冲突解决 agent） |

**并行的精髓（务必理解，避免误用）**：
- 由于实现→测试是**链式依赖**，parallel **不是"codex 和 opencode 同时跑"**（opencode 要先拿到 codex 的实现才能写测试）。
- 并行 = **拆出 N 个互相独立的子任务，每条子任务都是一个独立的 codex→opencode 子流水线，N 条子流水线同时进行**。例如"功能A"和"功能B"改动不同文件，各自都走自己的 codex + opencode。
- 更常见的并行是**两个 codex 分支**各自实现两个独立功能，测试文档随后各自补。
- **opencode 始终依赖同一流的 codex 产出**，不会跨流配对。

**进出并行的规则：**
- **进**：拆解出 ≥2 个独立子任务（如"实现功能A"和"实现功能B"改不同文件），各自独立、无先后依赖 → **并行跑 N 条 codex→opencode 子流水线**。
- **出**：任一子任务产出被其他子任务依赖 → 必须等它完成再继续，不能提前聚合。
- **并行时用 git worktree 隔离**每个子流水线的工作副本，避免直接改主目录互相覆盖（worktree 由 Claude 在执行前手工 `git worktree add` 创建，独立副本提交后再 merge）。
- **并行 worktree 启动 codex 时，必须给 `run_agent.sh` 传 `--add-dir <wt>/<实际源码根>`**（见「阶段 2 并行 worktree 的正确跑法」），否则 codex 可写区绑错导致"退出但无产出"。

## 五阶段流水线

**顺序模式严格按序；并行模式阶段 2 与 3 同时进行，其余同。** 前一阶段未完成不得进入下一阶段。

### 阶段 0：需求理解（Claude）

1. 读取用户需求，明确：目标、约束、技术栈、输入/输出
2. **【API 签名前置勘察】** 若需求涉及调用第三方/平台接口，**先 grep 现有同类用法 2-3 处**确认真实签名：
   - 例：调用 `billRepository.insert(单实体)` → 先 `grep -rn "billRepository.insert" <项目>/src/main/java/.../impl/` 看实际签名（往往 `IBillRepository` 只有 `List<T>` 重载）
   - 例：调用 `gzwBatchReportUtil.sendSingleReport` → 找同类 caller 确认参数结构（request 字段命名、必填项）
   - 例：HTTP 调用工具类 → 找现有实现确认请求/响应结构
   - **目的**：把真实签名/参数写到任务卡里，避免 codex 现查现改浪费时间。代价：2-3 个 grep；收益：单文件改动任务省 5-10 分钟
3. 判断是否适合流水线（过于简单的任务可由 Claude 直接完成，但要向用户说明跳过理由）
4. 输出：一段话确认理解，等待用户确认（或自动继续，取决于用户偏好）

### 阶段 1：拆解分工（Claude）

在项目根目录创建：
```
.orchestration/
├── contract.json          # 【新增】机器可校验的接口契约（阶段1首件事）
├── codex_task.md          # 给 codex 的实现任务卡
├── opencode_task.md       # 给 opencode 的测试/文档任务卡
├── state.json             # 【新增】进度+版本状态机（脚本 state.sh 维护）
└── acceptance_report.md   # 最终验收报告（阶段 4 写入）
```

**先写 `contract.json`（这是预防"任务理解错误"的第一道闸，不是可选项）：**
```json
{
  "meta": {
    "name": "历史运行记录功能",
    "version": "v1"
  },
  "files": [
    { "path": "src/history.js" },
    { "path": "README.md" }
  ],
  "interfaces": [
    { "source": "src/history.js", "symbol": "historyExport", "kind": "call" },
    { "source": "src/history.js", "symbol": "deprecated_old", "kind": "absent" }
  ],
  "acceptance": [
    { "id": "AC-01", "type": "test_cmd", "cmd": "node --test test/*.test.js", "title": "全部单测通过，0 fail" },
    { "id": "AC-02", "type": "file_exists", "path": "src/history.js", "title": "实现文件生成" },
    { "id": "AC-03", "type": "contains", "file": "README.md", "text": "## 使用", "title": "README 含使用说明" },
    { "id": "AC-04", "type": "subjective", "title": "刷新页面后历史记录仍可见" }
  ]
}
```
字段含义：
- `meta.name` — 任务名称
- `meta.version` — **契约版本号**（必填）。约定：首次 `v1`，接口变更时升为 `v2/v3/...`。`validate_contract.sh` 会读取此字段，与 `state.json` 的 `contract_version` 比对，不一致时**输出警告**，提醒可能读到了过期契约。
- `files[].path` — 预期最终会存在的文件（校验时会逐条 `ls`）
- `interfaces[]` — 接口签名断言：`source`=源码相对路径，`symbol`=函数/字段名，`kind`：`call`=源码必须含该符号；`absent`=源码不得含该符号
- `acceptance` — **验收标准清单（Accept Criteria）**，编码方与验收方共用的同一把尺子。**每条必须带 `type`，机器在交接时当场执行：**
  - `test_cmd`：跑 `cmd`，退出码 0=过（把"必须过测试"变成 exit code）。**注意：Windows 下 `node --test <目录>` 会静默通过而不真正跑测试**，务必给**具体文件**（`node --test test/*.test.js`）或裸 glob，不要传目录。
  - `file_exists`：断言 `path` 文件存在
  - `contains`：断言 `file` 内容含 `text` — **写最小公共子串，预留 5-10% 弹性**：
    - ❌ 反模式1：`text: "billRepository.insert(bill)"` —— 实现层若选 `Collections.singletonList(bill)` 即不匹配
    - ❌ 反模式2：`text: "DELETE FROM \"foo\".\"bar\""` —— Java 源内必然转义成 `\"foo\".\"bar\"`
    - ❌ 反模式3：`text: "log.info(\"xxx\")"` —— 实现层若用 `log.error` 或拼写略改即不匹配
    - ✅ 推荐：`text: "billRepository.insert("` / `text: "foo.bar"` / `text: "logger.error("` —— 抓**类名.方法名(** 或 **表名** 或 **字段名**这类稳定子串
    - 当 AC 涉及 **Java/SQL/JSON 字面量**时，外层包装（List /括号 /字符串转义）极不可控，写子串避免误报
  - `subjective`：无法自动判，留待阶段 4 人工核
  - 每条自动编号：写 `id` 优先，否则按 `AC-01/AC-02…` 补齐
- **`acceptance` 必须非空**：为空时 `validate_contract.sh` 直接 exit 1，**卡住流水线，不得进入阶段 2**——你不写验收标准，工作流根本不启动。

**关键调校点**：无论 codex/opencode 哪一方推进，**在交接前务必先把 contract.json 定稿**。若运行中被某 agent 改了接口，必须回到本阶段更新 contract.json——**契约是唯一真相，代码跟契约走，不是契约跟代码走**。

**任务卡（必须引用同一份验收编号，杜绝"各拿各的尺子"）：**
- **codex_task.md 必须包含：** 功能需求、**逐条列出须满足的 `AC-0x` 编号**（对齐 contract.json 的 acceptance）、禁止事项（不改测试）、文件输出路径
- **opencode_task.md 必须包含：** 需测试的函数/接口及路径、测试框架要求（`node:test`）、覆盖要求（边界用例）、**文档须覆盖 `AC-03` 之类验收项**、禁止事项（不改业务实现）

**任务卡须按运行 OS 动态注入「运行环境提示」（防跨平台写文件失败）：**
- codex/opencode 常默认按 bash/Linux 生成命令（`cat << 'EOF'` heredoc、把整段补丁塞进 `apply_patch` 命令行参数）。若实际执行 shell 是 **Windows PowerShell**，这些命令会失败：heredoc 报 `Missing file specification after redirection operator`，apply_patch 塞参数报 `requires a UTF-8 PATCH argument`
- **Claude 编排时判断当前 OS**：Windows（win32）→ 在**每份任务卡标题下**加 `## ⚠️ 运行环境提示（Windows / PowerShell）` 段，指明实际 shell 是 PowerShell、别用 bash heredoc、别用 apply_patch 塞参数、写文件用 `@'...'@ | Set-Content -Path <路径> -Encoding UTF8`；Linux/macOS → 不加
- 为保持技能**跨 OS 通用**，**不要**把 Windows 提示硬编码进 `run_agent.sh` 等脚本——由编排者按当前 OS 注入任务卡（技能脚本保持平台无关）
- **【改既有文件的推荐策略】**（Windows 下避免长时间兜圈的关键）：
  - 不要用 `apply_patch` 整段补丁塞参数（PowerShell 会报 `requires a UTF-8 PATCH argument`）
  - 不要 `Write-Output` 整段重写既有文件（易引入 CRLF / BOM / GBK 编码问题，javac 报「未结束的字符文字」）
  - **正确做法**：定位旧锚点 → `Get-Content -Replace "<old>","<new>"` 一次替换一段 → `Set-Content -Encoding UTF8`，多次小步替换而非一次大改
- **【自测责任分工】**（避免 codex 在 javac/mvn 上兜圈）：
  - codex 的"自测"仅在**前端类**项目（`npm test` / `node --test`）有意义，后端 Maven 项目的 `mvn compile` / `javac` 由阶段 4 Claude 独立跑
  - 后端 Maven 项目任务卡明文写**「编译验证由阶段 4 跑，codex 不要自行 javac/mvn」**，节省 5-10 分钟
  - 实测：单文件后端改动任务，codex 在 javac 自测上平均耗时 10-15 分钟（编码仅 5 分钟），收益为负

**每份任务卡末尾都必须附上【执行反馈】段（不改就丢了上报通道）：**
```
【执行反馈】运行中若遇到：需求与设计不符、技术难点超出本任务、需要额外决策/信息，
请【立即停止】当前操作，不要硬扛或敷衍通过。把你的问题写进 .orchestration/feedback.md：
- 你卡在哪（对应任务卡哪一条）
- 你认为正确的做法 / 需要的决策
- 你的建议方案
然后正常结束（exit 0 代表"完成或有反馈"，不要用 exit 1 表示"有反馈"）。
如果没有任何阻塞，正常完成即可，不需要写 feedback.md。
```

**并行/顺序判定后，把决策也写进 `state.json`：**
```bash
scripts/state.sh <project> set run_mode sequential   # 或 parallel
scripts/state.sh <project> set contract_version v1   # 必须与 contract.json 中 meta.version 一致
```

> `state.sh` 签名：`state.sh <project_dir> set <key> <value>` / `get <key>` / `files-hash <file>` / `status`。写入时 value 是**单个参数**，不要多传空格分隔。

### 阶段 2：codex 实现

**后台启动 codex（用 run_agent.sh 封装，缺 codex 会自动 npm 安装）：**

```bash
cd <project-dir> && scripts/run_agent.sh codex . "$(cat .orchestration/codex_task.md)" --background
```

- `--background`：后台启动 → 日志写入 `.orchestration/logs/codex.log`，**立即返回 PID**。
- **过程监控**：`tail -f .orchestration/logs/codex.log` 直播进度；用户说"看进度"就用这个。
- **等待完成**：轮询 `kill -0 <PID>` 直到消失，或直接改用**前台模式**（去掉 `--background`，阻塞到 agent 跑完返回 exit code）。
- codex 通常会自测，但**不以自测结果为验收依据**。codex 自测仅作过程参考，可选择跳过，**跳过不影响流水线推进**——验收只看阶段 4 的独立测试。

> 等价于手动前台：`codex -C . exec --sandbox workspace-write --skip-git-repo-check -m gpt-5-codex "$(cat .orchestration/codex_task.md)"`
>
> **统一建议**：脚本联调/验收用**前台**（阻塞拿 exit code 最稳）；人工跟进度用**后台 + tail**。两者行为一致，只是是否阻塞。

#### 并行 worktree 的正确跑法（v4，防"退出但无产出"）＋【源码根自动对准】

并行时每个分支在独立 git worktree 中实现。**所有源码根（后端/前端/其他）由脚本自动探查并加入 codex 可写区**，不再依赖人为传对 `--add-dir`：

- `scripts/probe_src_roots.sh <search_root>` —— 自动探查 `search_root`（通常为 worktree 根或仓库根）下各类型源码根，按 `pom.xml`(backend)/`package.json`(frontend)/`build.gradle`(backend-gradle)/`*.csproj|*.sln`(backend-dotnet)/`scripts/*.sh|sql|py`(scripts)/含`src`(other) 分类，输出 `类型:绝对路径`（每行一个）。不硬编码路径。
- `run_agent.sh` 接收该探查结果，**可写区解析优先级**：
  1. 显式 `--add-dir <dir>` → 用用户给的，不自动探查（尊重显式意图）；
  2. 显式 `--add-root <type>` → 自动探查，仅把该类型根加入可写区（并行时 codex 往往只改某一类）；
  3. 环境变量 `EXPLICIT_ADD_ROOTS=1` → 自动探查，所有类型根全加入（整仓前后端一起改）；
  4. **默认** → 自动探查，仅把**后端(backend)源码根**加入（后端 Java 是多数 quad 任务目标，最安全）。
  - 无论哪种，`-C` 主目录（worktree/仓库根）始终可写，且首个可写根集合自动传入多个 `--add-dir`。
  - 启动日志打印 `add-dir: <真实路径>`，一眼核对。

**Claude 侧统一约定（写进本 SKILL，不依赖 CLAUDE.md）**：所有 `run_agent.sh codex` 启动**不要手动指定 --add-dir**（交给自动探查）；仅在"只改前端"时加 `--add-root frontend`、"整仓一起改"时加 `--add-root all`。并行 worktree 与顺序模式同样适用。

```bash
# 1) 创建 worktree（在项目根）
git worktree add <wt-1>   # 例如 .worktrees/feat-a
# 2) 后台启动该分支的 codex —— 源码根自动对准（默认后端；只改前端加 --add-root frontend）
cd <project-dir> && scripts/run_agent.sh codex <wt-1> "$(cat .orchestration/codex_task_feat_a.md)" --background --add-root backend
```

> `--add-root`（与 `--background`）可任意顺序出现；`--add-root backend|frontend|all` 让脚本只把对应类型源码根注入可写区。不需要手写 `--add-dir`。

**并行跑法检查清单（V5 新增，逐条核对）：**
- [ ] 每个分支 worktree 已 `git worktree add`（用完整路径，别用 `.orchestration/wt-*` 这类让 run_agent 继续嵌套的路径）
- [ ] 每个分支 `run_agent.sh` 用 `--add-root <type>` 或默认(后端)；**不要手写 `--add-dir`**（源码根由 `probe_src_roots.sh` 自动探查注入）
- [ ] 每份任务卡里的目标文件路径，相对项目源码根（如 `c-fi-hlj-ljkf-be/...`）正确
- [ ] 日志能查到 `add-dir: <真实源码根>`（前台/后台均打印），确认可写区对准源码树
- [ ] 分支完成后该 worktree 的 `git status --short` 显示预期变更（而非空），才说明真正落盘
- [ ] 若某节点 `probe_src_roots.sh` 未探到该类型根（回退到 project_dir），需确认任务卡路径与可写根是否一致

**codex 完成后 Claude 立即做一次轻量检查（不是最终验收）：**
- **先处理反馈（全新环节，必须在跑契约前）：**
  ```bash
  scripts/feedback_loop.sh <project> check    # exit 0=有反馈; 1=超熔断; 2=无反馈
  ```
  - **有反馈（exit 0）**：进入**阻塞协商**，读 `feedback.md` 后走 §反馈处理流程，**不再继续当普通完成处理**。
  - **超熔断（exit 1）**：停止自动打回，升级给用户人工裁决，整条流水线暂停等用户。
  - **无反馈（exit 2）**：正常继续轻量检查。
- 预期文件是否都已生成
- 是否越权修改了不该碰的文件
- **记录契约版本与产物 hash：**
  ```bash
  scripts/state.sh <project> set codex_read_contract <契约版本>
  scripts/state.sh <project> set codex_out_hash "$(scripts/state.sh <project> files-hash <关键产物>)"
  ```
- **跑契约校验（交接前的闸门，提前拦截理解偏差）**：
  ```bash
  scripts/validate_contract.sh <project>    # exit 0=契约一致；exit1=有偏差，记录后进阶段3
  ```
  校验失败会明确报出"接口缺失/应删未删/文件缺失"，据此决定是继续（轻微偏差阶段4兜底）还是回阶段 2（接口大改）。
- 若发现严重问题（如文件缺失/越权），记录后继续进入阶段 3（阶段 4 会拦截）

### 阶段 3：opencode 测试/文档

**后台启动 opencode（用 run_agent.sh 封装，缺 opencode 会自动 npm 安装）：**

```bash
cd <project-dir> && scripts/run_agent.sh opencode . "$(cat .orchestration/opencode_task.md)" --background
```

- 后台模式写日志到 `.orchestration/logs/opencode.log`；前台模式（去 `--background`）阻塞到完成。
- **过程监控**：`tail -f` 对应日志，「看进度」用它。

> 等价于前台手动：`opencode run --dir . --auto "$(cat .orchestration/opencode_task.md)"`

**opencode 完成后同样先处理反馈**（同阶段2）：
```bash
scripts/feedback_loop.sh <project> check
```
有反馈 → 阻塞协商；超熔断 → 升级用户；无反馈 → 继续轻量检查。

**过程监控：** 同上，tail 日志直播进度。

**opencode 完成后 Claude 做轻量检查：**
- 测试文件和 README 是否已生成
- 是否越权修改了业务实现文件
- **记录 + 防陈旧读取：**
  ```bash
  scripts/state.sh <project> set opencode_read_contract <当前契约版本>
  ```
  若 `opencode_read_contract` 落后于 `contract_version`（opencode 依据旧契约写测试），需打回本阶段重读新契约再写。
- **再次跑契约校验**（阶段 3 退出条件）：`scripts/validate_contract.sh <project>` 应 exit 0。
- **更新 state 到阶段 4**：`scripts/state.sh <project> set phase 4`

### 阶段 4：Claude 严格验收（不可跳过）

**这是整个流水线最关键的环节。Claude 独立执行，不信任任何一方的自测结果。**

#### 4.1 独立运行测试

```bash
# 根据项目类型选择对应命令
cd <project-dir> && node --test test/
# 或 pytest / cargo test / go test 等
```

必须亲眼看到 **全部绿色（0 fail）才算过**。若 fail → 记录失败原因，交给 opencode 修正，再重跑，直到全绿。

#### 4.2 逐条核验验收标准（Accept Criteria）——同一把尺子

按 `contract.json` 的 `acceptance` **逐条对照同一个 AC 编号**打分，不是凭感觉：

- **机器可验条目（`test_cmd`/`file_exists`/`contains`）**：已由 `validate_contract.sh` 在交接时自动跑过，阶段 4 复跑确认。
- **`subjective` 条目**：这部分才需要手动验证，逐一执行并把结论**机器写回** `state.json`，形成可追溯记录：
  ```bash
  scripts/state.sh <project> set ac_04 true    # AC-01 通过
  scripts/state.sh <project> set ac_04 false   # 或 false，表示该条未过
  # 按每条 AC 编号分别记录
  ```
  - 命令行工具：直接运行并检查输出
  - Web 界面：curl 或启动后检查响应
  - 库/模块：写一个小脚本 import 并调用

#### 4.3 写验收报告

将结果写入 `.orchestration/acceptance_report.md`，**验收结论必须落在同一组 AC 编号上**，与契约完全对齐：

```markdown
# 验收报告
日期：<时间>
任务：<需求摘要>
契约版本：v1

## 验收标准逐条核验（contract.json acceptance）
- [x] AC-01 命令通过：node --test test/ → 0 fail
- [x] AC-02 文件存在：src/history.js
- [x] AC-03 README 含"## 使用"
- [x] AC-04 [人工] 刷新后历史记录仍可见
- 结果：4/4 通过

## codex 实现
- [x] 文件已生成：src/xxx.js
- [x] 未越权修改其他文件
- [x] 功能验证通过：描述...

## opencode 测试/文档
- [x] 测试文件已生成：test/xxx.js
- [x] 测试结果：14/14 通过
- [x] README 已生成
- [x] 未越权修改实现代码

## 总结
✅ 交付合格 / ❌ 需修正：<具体问题>
```

#### 4.4 不合格处理

若验收不通过，先用**客观规则**定归属，避免凭主观来回打回：

1. **判定归属（客观判据）**：
   - 先跑 `scripts/validate_contract.sh <project>` 看 `interfaces` 断言是否通过。
   - **codex 实现不符合 `interfaces` 断言** → 问题在**实现**，回阶段 2。
   - **codex 实现符合 `interfaces` 断言**，但测试失败 → 问题在**测试/文档**，回阶段 3。
   - **接口与测试都通过，仅 `subjective` 项不满足** → 需求偏差，Claude 修正任务卡/契约，回阶段 2。
2. 判断后记录失败原因。
3. 重试轮数：实现回退最多 2 轮，测试/文档回退最多 2 轮，**分开计数**（避免"先改测试再改实现"消耗同一份额度）。
4. 超过上限仍未通过 → 向用户报告阻塞原因，停止流水线。

## 反馈处理流程（防死循环）

当 agent 写 `.orchestration/feedback.md`（任务卡【执行反馈】段触发）或验收打回重试超限时，走此流程。**核心目标：每轮反馈必须"推进状态 + 熔断计数"，绝不原地重复同一裁决。**

```
agent 完成
   │ feedback_loop.sh check
   ▼
exit 2 (无反馈) → 正常继续
exit 1 (超熔断) → 升级用户，暂停流水线（不再自动打回）
exit 0 (有反馈) → 读 feedback.md，Claude 裁决
   │
   ├─ 采纳 agent 方案 → consume 后回对应阶段（这是合法前进）
   ├─ 澄清后继续(不需要改接口) → consume 后回原阶段
   ├─ 确为需求错误 → 改契约/任务卡(升 version) → consume 后回阶段1/2（状态已变）
   └─ 若连续 2 次裁决是"同一问题、无新信息" → 直接升级用户，不消耗第 3 轮
```

**防死循环的三道闸（缺一不可）：**
1. **熔断计数**：每消耗一次反馈（`consume`）`feedback_loops` +1，达到 `MAX_FEEDBACK_LOOPS`（默认 3，可用环境变量覆盖）即 `check` 返回 exit 1，**必须升级给用户，禁止再自动打回**。
2. **状态必须前进**：每次反馈处理都必须改变状态——改契约、改任务卡、升版本或回不同阶段。**禁止"看同一个 feedback.md、做同样的裁决"连续两次**；发现就升级用户。
3. **重试轮次分离**：反馈重试与验收重试（阶段4各自2轮）**独立计数**，互不挤占；但反馈熔断是总闸，超限则整条停。

**Claude 裁决后再 `consume`**（清空 feedback + 计数+1），确保"同一个问题"不会反复读到：
```bash
scripts/feedback_loop.sh <project> consume   # 清空反馈、重试+1
scripts/feedback_loop.sh <project> reset     # 需求真正澄清后可手动重置计数
```

> **不会死循环的原因**：任何一轮反馈后要么升级到用户（有上限），要么状态变更后再回退（非原地重复），要么消耗计数直到触顶。三者必居其一，绝无"无限自动同裁决"路径。

## 冲突解决 agent（异常协同的可选增强）

**何时引入**：并行模式下，两个 agent 的产出在合并时产生**文件冲突**，或它们的实施方案**互相矛盾**（如对同一接口的签名/语义理解不一致）。

**由谁当**：默认由 **Claude（我）** 直接担任冲突解决者。若冲突规模大、争议深，可额外再派一个独立的 codex 实例当"中立方"评审冲突双方。

**处理流程：**
1. **识别冲突**：合并 git worktree 分支提示 conflict，或验收时发现"两个模块对同一函数假设不一致"。
2. **归属判定**（关键决策）：判断冲突属于哪一方职责——
   - 业务逻辑冲突 → 归 codex
   - 测试与实现的接口约定冲突 → 归实现方 codex（测试以实现为准）
   - 文档与行为冲突 → 归 opencode
3. **出具裁决书**：写一份 `conflicts/conflict-NNN.md`，列出：冲突点、双方各自立场、裁决决定、哪个文件按谁改。
4. **指派修复**：把裁决书作为新任务卡，交给被判"该改"的 agent 或 Claude 直接修（Claude 只做胶水级合并可免除委派）。
5. **重验收**：修复后回到阶段 4 重新独立验证。记录在验收报告的"冲突处理"小节。
6. **熔断**：同一批冲突修复 2 轮无解 → 降级为顺序模式重跑，并向用户说明原因。

**预防优先**：能在拆解时通过"一人一文件、接口先定"避免的冲突，不要等发生——任务卡里把**接口签名/数据格式**提前钉死，让各方照同一契约实现。

## 完整触发示例

```
用户：/quad 给启动界面加一个"历史运行记录"功能，存到 localStorage，页面刷新后还能看到

Claude 执行：
1. 阶段 0：拆解——前端加 localStorage 持久化 + 历史列表 UI
2. 阶段 1：判断顺序/并行。此例"实现"与"测试/文档"有依赖 → 顺序
         写 .orchestration/codex_task.md 和 opencode_task.md
3. 阶段 2：codex 实现（后台启动，直播进度）
4. 阶段 3：opencode 补测试+文档（后台启动）
5. 阶段 4：Claude 独立验证→全绿→写验收报告→告知用户"✅ 交付合格"
```

## 注意事项

- **不要绕过流水线**：Claude 不得因为"很简单"就自己把 codex/opencode 的活干了（除非任务极其简单且向用户明确说明跳过理由）
- **后台日志可随时 tail**：用户说"看进度"时，读任务后台输出文件直播
- **流水线中途可中止**：用户说"停"即停止，记录当前状态
- **并发冲突预防**：顺序模式按职责隔离文件；并行模式用 git worktree 隔离 + 冲突解决 agent 兜底
- **完整设计原理**（协调架构/通信机制/知识共享/异常协同四维度）见技能目录下的 `README.md`
