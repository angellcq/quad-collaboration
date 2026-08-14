# Quad Collaboration — 设计原理

**版本 v5.4**（在 v5.1 跨平台写文件适配基础上，跟进 **v5.2 契约弹性 + Windows 写文件策略 + 自测责任分工**；**v5.3 契约校验收敛为「阶段3后唯一闸门」、`interfaces[]` 简化为 absent-only、`subjective` 改可选、熔断/回退轮次/AC 记录术语三分、删去对本文的外链引用**；**v5.4 阶段0 升级为「需求理解 + grilling 澄清 + 写 spec」**，产出 `.orchestration/spec.md` 作为阶段1 契约与任务卡的唯一输入）

本文件说明 `quad-collaboration` 技能在**协调架构、通信机制、知识共享、异常协同**四个维度的设计思路。这是"为什么这么设计"，`SKILL.md` 是"怎么执行"。

> ⚠️ **自 v5.3 起 `SKILL.md` 已自包含、不再外链本文**（对齐项目 CLAUDE.md「禁止通用 brainstorming」约束，执行时只读 SKILL.md）。本文保留为独立的**设计原理说明**，供理解"为什么"，不再是 SKILL 的执行依赖。

---

## 总览

四个机制如何咬合成一个可重复、可验收的多智能体系统：

```
   [协调架构] 中心化+顺序(默认)/并行(复杂)   定义"谁先谁后、谁拍板、何时并行"
        │
        ▼
   [通信机制] 文件即接口 + 后台日志          定义"信息如何从 A 到 B"
        │
        ▼
   [知识共享] 物化共享 + 职责隔离            定义"经验如何传、如何防冲突"
        │
        ▼
   [异常协同] 自愈 → 打回 → 冲突解决 → 兜底  定义"出错时谁来救、怎么救、救几轮"
```

四者叠加 = 一个**可由单一编排者稳定驱动、可重复、可验收**的多 agent 流水线，而不是把几个工具丢到一起碰运气。

---

## 1. 协调架构（Orchestration）

### 模式：中心化编排（Centralized Orchestration）

采用**中心化编排**，不是去中心化的群聊。Claude 是唯一的 orchestrator / manager，codex、opencode 是从属 worker。

```
Claude（编排者 & 唯一执行者）
   │   阶段0 需求澄清+写 spec → 阶段1 拆解→写任务卡→判断顺序/并行
   ▼
codex（实现者）─────────── 阶段2
   │   产出业务代码
   ▼
opencode（测试/文档者）──── 阶段3
   │   产出测试/文档
   ▼
Claude（验收者）────────── 阶段4
   │   （可选）冲突解决 agent 处理并行合并冲突
   ▼
交付
```

**设计要点：**
- **一主多从**：所有决策、拆解、验收、回退、冲突归属判定都由 Claude 做——消除"多智能体谁说了算"的歧义。
- **流程可编程**：`depend_on` 语义（实现→测试）通过"阶段未完成不得进入下一阶段"硬编码，不由 agents 自主协商，保证"每次严格照分工执行"。
- **顺序 vs 并行的开关在 Claude 手里**：
  - 默认顺序（链式依赖、职责隔离、低冲突）
  - 复杂/独立子任务多时切并行（同时跑 codex/opencode 或两个分支），用 git worktree 隔离
  - 拆解时就判断，而非事后补救

---

## 2. 通信机制（Communication）

### 模式：文件即接口（File-based Handoff）+ 后台日志 + 同步轮询反馈

**刻意不引入实时消息总线**，也不让 codex/opencode 直接互发消息。用"文件 + 日志文件 + 轮询"传递所有跨 agent 信息，含反馈。

| 机制 | 承载什么 | 方向 |
|------|---------|------|
| `spec.md`（`.orchestration/`） | **阶段0 澄清产物——阶段1 `contract.json` 与任务卡的唯一输入**（目标/约束/技术栈/输入输出/验收标准） | 下行（v5.4） |
| `codex_task.md` | Claude → codex 的一次性完整需求（功能、验收条件、禁止事项、文件路径） | 下行 |
| `opencode_task.md` | Claude → opencode 的测试/文档任务 | 下行 |
| `contract.json` | **机器可校验的接口契约**（签名/文件/数据格式/验收标准+版本号） | 下行（共享） |
| `state.json` | **进度恢复 + 防陈旧读取**的状态机（当前阶段/各方读取版本/产物 hash/熔断计数） | 共享 |
| `validate_contract.sh` | 跨进程后**自动校验契约**，把"理解对错"从 agent 自觉变成 exit code | 机器检查 |
| `feedback.md`（上行） | **agent → Claude 的阻塞/问题上报**（需求不符/技术难点/需要决策），Claude 完成后轮询检查 | **上行** |
| `feedback_loop.sh` | 裁决反馈 + 熔断（默认3轮），防死循环 | 机器检查 |
| 后台任务输出日志 | agent → Claude 的**事中进度**（`tail` 直播） | 上行 |
| `acceptance_report.md` | Claude → 用户的最终交付声明 | 外发 |
| `conflicts/conflict-NNN.md` | Claude → 被判"该改"的 agent 的裁决书 | 下行 |

**设计要点：**
- **任务卡是"一次性自足指令"**：每个 agent 拿到的是精心构造的最小上下文，不继承 Claude 的完整对话历史（fresh subagent, isolated context），避免上下文污染。
- **产出物即通信媒介**：opencode 通过读 codex 写的 `src/*.js` 获取实现细节，无失真、无需转述。
- **反馈采用同步轮询**：由于 codex/opencode 是独立 CLI 进程，没有 IPC 通道，agent 无法在运行中主动发消息给 Claude。反馈机制是 agent 遇到问题时写 `feedback.md`，**Claude 等 agent 完成后跑 `feedback_loop.sh check` 轮询**。这是多智能体独立进程架构下的现实选择——简单可靠，延迟对"需求不符"类场景影响不大。
- **熔断防止死循环**：每次反馈消耗计数 +1，连续 3 轮（可配）自动升级用户；每次裁决必须改变状态（改契约/任务卡），禁止连续两次做同样裁决。

> ⚠️ **固有风险（v3 已针对缓解）**：流水线本没有消息总线，上下文在每次跨进程交接时都会**压缩失真**（Claude 意图→spec/任务卡→codex 实现→opencode 测试→Claude 验收，链越长偏得越多）。v3 引入 `contract.json` + `validate_contract.sh` + `state.json`，把纠偏从**事后**前移到**交接即校验**（v5.3 收敛为：阶段2 后只跑 `interfaces[].absent` 轻量门，**全量契约在阶段3 后是唯一一次闸门**）。反馈机制进一步在**过程中**捕获偏差，见 §反馈处理流程。真正的上下文语义只有靠阶段0 需求澄清 + 阶段4 逐条对照不断缩小，无法完全消除。

---

## 3. 知识共享（Knowledge Sharing）

### 模式：物化共享（Sharing-through-artifacts）+ 职责隔离

知识经"物"共享，不经"话"共享；并用严格的职责边界防止知识流向混乱。

```
前置知识库 = 现有代码（server.js/app.js/.../src/index.js）
                          ↓ Claude 读取、消化
Claude 把"需要知道什么"压缩进任务卡（知识压缩）
        ↓
codex 读 codex_task.md + 项目文件 → 产出新代码（知识经代码自动共享给后续）
        ↓
opencode 读 opencode_task.md + codex 新代码 → 写测试（隐含消费 codex 的经验）
        ↓
Claude 读所有产出 → 验收（汇聚全部知识）
```

**设计要点：**
- **知识压缩（knowledge distillation）**：Claude 不倾倒全部上下文，只给"够用的断言性知识"（做什么/不做什么/接口长什么样）。
- **职责隔离防冲突**：
  - opencode 只读不改业务代码 → 知识单向，不反向污染实现
  - codex 不写测试 → 不与 opencode 抢同一文件
  - 验收时检查双方谁越权改了谁的文件（已实战验证有效）
- **接口先钉死**：任务卡里提前写明接口签名/数据格式，让 Codex 与 OpenCode 照同一契约工作，从源头减少知识分歧。**v3 把它升级成 `contract.json` 机器契约 + `validate_contract.sh` 自动校验**——不再依赖 agent 自觉，跨进程交接即用 exit code 判定"契约是否一致"。契约是唯一真相：代码跟契约走，不是契约跟代码走。

### 契约弹性与收敛（v5.2 / v5.3）—— 让机器契约"可用而不脆"

- **契约弹性（v5.2）**：机器契约不能只满足"机器能跑"，还要扛得住实现层的**合法变体**。`acceptance[].type: contains` 的 `text` 一律写**最小公共子串**（如 `billRepository.insert(` 而非 `billRepository.insert(bill)`），预留 5-10% 弹性——实现层选 `Collections.singletonList(bill)` 这类变体也不误报；Java/SQL/JSON 字面量因外层包装不可控，尤其要写子串。
- **断言收敛（v5.3）**：
  - `interfaces[]` **仅记录 absent**（"绝不能出现的旧符号"，防重构漏删）；"必须存在的符号"由 `acceptance[].type: contains` 覆盖——单一职责，避免双轨。
  - `subjective` 由默认改为**可选**：多数场景无主观 AC，机器可验条目就是唯一契约尺；无法机器验证时才用它（不参与阶段3 自动校验，阶段4 人工核验写回 `state.json`）。
  - **全量契约校验只跑一次**：阶段2 后仅 `--phase=2` 跑 absent 轻量门；**阶段3 后跑全量（唯一闸门）**，对照"codex 实现 + opencode 测试"双产出，避免单靠 codex 产物 false negative。

### 源码根自动对准（v5）—— 给 codex "找对落盘位置"

**问题**：codex 的 `workspace-write` 沙箱可写区默认只覆盖传入的 `project_dir`。并行 git worktree 场景下若把 worktree 根当 project_dir，真实源码树在可写区外 → codex 能执行却写不进源码（`Access denied` →"退出但无产出"），曾多次踩坑。

**方案**：不靠人记忆传对 `--add-dir`，而是**自动探查 + 文件固化**：

```
probe_src_roots.sh <search_root>   → 自动探查各"编码单元"根，按类型分类
   backend  : 含 pom.xml / build.gradle / *.java 显著
   frontend : 含 package.json + src 或 *.vue/*.jsx/*.tsx 显著
   other    : 有工程入口或含 src/ 但非前后端（宁多勿错，一律加入可写区）
   → 输出 "类型:绝对路径"（一行一个），不硬编码路径、不绑死某项目
        │
        ▼
write_source_roots.cjs  → 写成 <project>/.orchestration/source_roots.json
   （带中文注释的可编辑 JSON，人工可改一次永久生效；标准 JSON 解析器读它失败属预期，
     读取端已支持剥离 // 注释解析）
        │
        ▼
run_agent.sh（file-first）→ 优先读 source_roots.json；文件不存在才再探查并写回
   · 默认仅后端(backend)根加入可写区（多数研发任务目标）
   · --add-root <type> 只加某类型（并行时 codex 往往只改某一类）
   · EXPLICIT_ADD_ROOTS=1 / --add-root all 全部类型
   · 显式 --add-dir <dir> 则用用户给的，不自动探查（尊重显式意图）
   · -C 主目录始终可写；可写根可多个，逐个 --add-dir；日志打印 add-dir 一眼核对
```

**设计要点**：
- **判定基于客观信号**（工程/清单文件 + 源码目录 + 源文件扩展名），不依赖项目目录名 → 任何语言/仓库通用。
- **文件固化 + 人工可改**：探查结果落 `source_roots.json`，脚本每次优先读它——既是缓存（免重复探查），也给人一个"发现不对就手动改"的覆盖入口。
- **归类宁多勿错**：拿不准一律 `other`（仍加入可写区），只影响 `--add-root` 的过滤粒度，不影响能否落盘。

---

## 4. 异常协同（Exception Handling）

### 三层机制，对应不同位置的故障

**① 运行期异常（agent 内部）** —— 交给 agent 自愈
- 策略：让 agent 自己发现并绕开，Claude 只监控不干预。
- 实战案例：codex 的 `apply_patch` 在 Windows 因尾随换行反复报错，它**自主换方案**用 PowerShell 字符串替换写入成功。Claude 全程旁观，未打断。

**② 阶段门禁异常（产出被判定不合格）** —— Claude 打回重跑
- 归属判定：问题在实现 → 回阶段 2；在测试/文档 → 回阶段 3。
- 回退轮次（v5.3 术语规范，不再用"熔断"）：实现 ≤ **2 轮**、测试/文档 ≤ **2 轮**，**分开计数**（避免"先改测试再改实现"挤占同一份额）；超限停止并向用户报告阻塞原因，防死循环浪费 token。"熔断"一词专指反馈流程的 `feedback_loops` 总闸（默认 3 轮，见 §反馈处理流程）。

**③ 并行冲突（新增 v2）** —— 引入**冲突解决 agent**
- 触发：并行合并时文件 conflict，或两模块对同一接口/语义理解不一致。
- 谁当：默认 Claude 担任；冲突大时可再派独立 codex 实例当"中立方"评审。
- 流程：识别冲突 → 归属判定（业务归 codex / 接口约定归实现方 / 文档归 opencode）→ 写裁决书 `conflict-NNN.md` → 指派修复 → 重验收 → 2 轮无解降级为顺序模式。
- 预防优先：拆解时一人一文件、接口先定。

**④ 资源/环境异常（tool 本身故障）** —— Claude/脚本兜底
- 任务卡脚本里写死 CLI 兜底查找路径（`/c/Users/.../npm`），找不到明确报错跳过而非静默。
- 验收阶段 Claude 自行发现"命令环境坑"（如目录/路径写错）兜住，不甩给 agent。

### 跨平台写文件适配（v5.1）—— 把"环境提示"前置到任务卡，而不是改脚本

- **背景**：codex/opencode 常默认按 bash/Linux 思维生成命令——`cat << 'EOF'` heredoc、把整段补丁塞进 `apply_patch` 命令行参数。Windows 下 `shell_command` 实际执行的是 **PowerShell**，两类写法都会失败：heredoc 报 `Missing file specification after redirection operator`，apply_patch 报 `requires a UTF-8 PATCH argument`。实战中 codex 开局连失败 5 次后才自主切到 PowerShell here-string 写文件成功（见上方 ① 的案例）。
- **决策**：**不改 run_agent.sh 等脚本硬编码平台提示**——技能跨 OS 通用，Linux/macOS 上误加会污染任务卡。改由 **Claude 编排时判断当前 OS**（win32）决定是否注入：Windows 才在每份任务卡标题下加 `## ⚠️ 运行环境提示（Windows / PowerShell）` 段，指明实际 shell 与正确的写文件姿势（PowerShell here-string + `Set-Content -Encoding UTF8`，内容统一 UTF-8 保证中文注释不乱码）。
- **为什么在任务卡**：任务卡是编排者的产物，Claude 运行时自知平台，注入时机最准确；脚本保持平台无关，改动面最小。规则已固化进 SKILL.md 阶段 1（任务卡须按运行 OS 动态注入），使每次编排自动遵守、不再靠 agent 试错。

### 自测责任分工（v5.2）—— codex 别在 javac/mvn 上兜圈

- **背景**：后端 Maven 项目的 `mvn compile` / `javac` 自测，codex 平均耗时 10-15 分钟（编码仅 5 分钟），收益为负。
- **决策**：codex 的"自测"仅对**前端类**项目（`npm test` / `node --test`）有意义；后端 Maven 项目在任务卡明文写「**编译验证由阶段 4 跑，codex 不要自行 javac/mvn**」，节省 5-10 分钟。
- **为什么在任务卡**：同 v5.1 的运行环境提示——平台/项目差异属于编排时的上下文，Claude 在阶段 1 按项目类型注入任务卡，脚本保持平台无关。

---

## 变更记录

| 版本 | 变更 |
|------|------|
| v1 | 三 agent 顺序流水线：规划→codex→opencode→严验收 |
| v2 | + 复杂时自动切并行（git worktree 隔离）；+ 冲突解决 agent；+ 四维度设计说明（本文） |
| v3 | **通信可靠性增强**：+ `contract.json` 机器契约（接口/文件/数据格式/验收条件）+ `validate_contract.sh` 每次交接自动校验 + `state.json` 状态机 + 产物 hash（防陈旧） |
| v4 | **上行反馈通道**：+ `feedback.md` + `feedback_loop.sh`（`check`/`consume`/`reset`）——agent 遇阻塞写文件、Claude 完成后轮询接管，带熔断(默认3轮)防死循环；解决并行定义歧义；run_agent 前后台模式；验收归属客观判定 |
| v4.1 | run_agent.sh 可写区参数规范为 `--add-dir`（显式给根→不自动探查，尊重显式意图） |
| v5 | **源码根自动对准**：+ `probe_src_roots.sh`（通用探查 backend/frontend/other 三类源码根，多语言清单，不硬编码路径）+ `write_source_roots.cjs`（生成带中文注释的 `source_roots.json`）+ `run_agent.sh` 改 file-first（优先读 `source_roots.json`、剥离 `//` 注释解析，文件缺失才探查并写回）、新增 `--add-root <type>` / `EXPLICIT_ADD_ROOTS=1`(all) 可写区注入、多根逐个 `--add-dir`。根治并行 worktree「实现了却无处落盘」的历史大坑 |
| v5.1 | **跨平台写文件适配**：+ SKILL.md 阶段1 新增「任务卡须按运行 OS 动态注入运行环境提示」——Claude 编排时判断当前 OS，Windows 才在每份任务卡标题下注入 `## ⚠️ 运行环境提示（Windows / PowerShell）` 段（禁 bash heredoc / apply_patch 塞命令行参数，改用 PowerShell here-string + `Set-Content -Encoding UTF8`），Linux/macOS 不加。**不改脚本**（run_agent.sh 等保持平台无关），平台判断留在编排时 |
| v5.2 | **契约弹性 + Windows 写文件策略 + 自测责任分工**（基于 2026-08-12/13 本地工程复盘）：`contains` 断言写最小公共子串留 5-10% 弹性（防实现层合法变体误报）；Windows 写文件姿势（PowerShell here-string + `Set-Content -Encoding UTF8`、`Get-Content -Replace` 小步替换而非整段重写）写进任务卡而非脚本；codex 自测仅前端类项目有意义，后端 Maven 编译验证由阶段 4 独立跑 |
| v5.3 | **契约校验收敛 + 术语规范**：删除阶段2 后全量契约校验（仅阶段3 后唯一一次闸门，阶段2 只跑 `interfaces[].absent` 轻量门）；`interfaces[]` 简化为 absent-only；`subjective` 由默认改可选；契约版本升级条件明确化（接口增删必升、AC 文本调整不升）；熔断/回退轮次/AC 记录三分；**删去对 README.md 的外链引用**（SKILL 自包含，执行只读 SKILL.md） |
| v5.4 | **阶段0 升级为「需求理解 + grilling 澄清 + 写 spec」**：衔接 Matt `grilling` 技能逐轮澄清需求，产出 `.orchestration/spec.md` 作为阶段1 `contract.json` 与任务卡的唯一输入；内置 grilling 检测 + 自动安装（`git clone` mattpocock/skills，缺失即装） |

---

## 一句话概括

> **一个中心化编排者（Claude），用"文件即接口"通信、经"物"共享知识、靠"自愈→打回→冲突解决→兜底"四层异常协同，驱动 codex 与 opencode 严格照分工、可重复、可验收地协作。**
