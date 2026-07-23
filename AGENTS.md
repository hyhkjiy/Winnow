# Winnow 协作规范

## Idea2Plan 项目管理

- 本仓库绑定的 Idea2Plan 项目 URI 为 `idea2plan://projects/10`，项目 ID 为 `PRJ-10`（macOS 窗口搜索器）。
- 仅当任务需要读取或变更以下项目管理信息时，必须使用 `idea2plan` skill，并在 `PRJ-10` 中管理和记录：
  - 需求、正式版本、候选方案、方案评审或待决策事项；
  - 需求的澄清、拆分、规划、阻塞、状态流转或交付验证；
  - 将产品决策、规划结论或经明确确认的实现状态记录到 Idea2Plan。
- 以下任务默认不调用 `idea2plan` skill：
  - 检查、搜索、解释或审查本地代码；
  - 定位缺陷、分析调用链或运行测试；
  - 代码重构、缺陷修复和一般实现工作；
  - 检查 Git 状态、diff、commit、SwiftPM 或构建配置。
- 仅当上述代码任务明确关联某个 Idea2Plan 需求，或用户要求结合项目需求、方案、决策或版本处理时，才读取对应的 Idea2Plan 资源。
- Idea2Plan 是上述项目管理信息的事实来源。不要仅在聊天、临时文档、提交信息或代码注释中保存需求、决策和方案，也不要凭记忆重建项目状态。
- 执行 Idea2Plan 读写前，使用明确的项目 ID `PRJ-10`，读取最新资源、生命周期和版本。发生版本冲突时停止写入，重新读取并根据最新状态处理；不得猜测项目、需求、方案、决策或版本 ID。
- 当用户指定 Idea2Plan 需求，或实现工作明确来源于某个需求时，实现前应读取对应需求、已选方案、相关决策和所属版本。若需求尚未达到可实施状态，先在 Idea2Plan 中完成必要的澄清、方案选择、评审和版本规划。
- 需求生命周期遵循 `draft -> clarifying -> ready -> planned -> in_progress -> validating -> done`；`deferred` 和 `cancelled` 是显式分支，阻塞状态独立管理。父需求的生命周期由子需求聚合，不直接修改。
- 只有定义完整的叶子需求才能进入 `ready`；分配到正式版本后进入 `planned`。进入 `in_progress` 前，目标版本必须已激活，且已选方案的当前评审必须通过。
- 产品判断类决策必须由用户明确给出或明确授权后才能写入。需求存在关联决策时，变更前先读取并报告；决策变化后，检查并报告所有受影响需求，不自动连锁修改其他产品决策。
- `in_progress`、`validating` 和 `done` 只能依据用户或已授权 Agent 的明确声明更新；不得仅凭代码存在、测试通过、提交完成或 Agent 自行验收判定实现状态。
- 完成 Idea2Plan 操作后，报告受影响的需求、版本、方案、评审或决策 ID、结果版本，以及仍待确认或存在阻塞的事项。

## Git Commit 规范

> 来源：[Vibe Common - 代码提交规范](https://vibe-common.hlzinterface.cn:18000/rules/commit/)

提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/)：

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

- `type` 必填，表示提交目的。
- `scope` 选填，使用小写模块、目录或功能名。优先采用仓库中的稳定边界，例如 `app`、`overlay`、`search`、`ax`、`hotkey`、`core`、`logging`、`package`、`scripts`、`docs` 或 `agents`。
- `description` 必填，使用中文、祈使语气，准确概括改动，建议不超过 50 个字符，末尾不加句号。
- `body` 选填，使用中文说明改动背景、关键实现和影响；不要逐文件罗列 diff。
- `footer` 选填，用于关联 Idea2Plan 资源、Issue 或说明破坏性变更。
- 一个提交只承载一个逻辑变更；重构、格式化和功能修改应尽量拆分。
- 提交前运行与改动相称的检查：
  - Swift 代码或测试改动至少运行 `make test`；
  - App Bundle、`Info.plist`、签名或打包脚本改动运行 `make verify`；
  - 仅文档改动可不运行构建，但应检查 Markdown、链接和示例命令；
  - 使用 `make format` 后必须检查格式化 diff，避免混入无关改动。
- 不提交密钥、令牌、私有配置、`.build/`、`.swiftpm/`、`DerivedData/`、用户态 Xcode 文件或其他本地缓存。

### 常用 type

| type | 用途 | 示例 |
| --- | --- | --- |
| `feat` | 新功能 | `feat(search): 支持按窗口标题过滤` |
| `fix` | 缺陷修复 | `fix(overlay): 修复多显示器面板不同步` |
| `refactor` | 不改变行为的重构 | `refactor(ax): 提取窗口枚举协议` |
| `perf` | 性能优化 | `perf(search): 减少重复匹配计算` |
| `test` | 新增或修改测试 | `test(search): 补充大小写匹配用例` |
| `docs` | 仅文档变更 | `docs(agents): 补充项目协作规范` |
| `style` | 不影响行为的格式调整 | `style(core): 统一 Swift 代码格式` |
| `build` | 构建系统或依赖变更 | `build(package): 调整 SwiftPM 配置` |
| `ci` | CI/CD 配置变更 | `ci(test): 增加 macOS 测试任务` |
| `chore` | 其他例行维护 | `chore(repo): 完善忽略文件` |
| `revert` | 回滚先前提交 | `revert: feat(search): 支持拼音匹配` |

### Idea2Plan 关联

- 与需求、方案或决策直接相关的提交，在 footer 中记录对应引用；优先使用稳定的短引用，例如：

  ```text
  Idea2Plan: REQ-123
  Idea2Plan: SOL-181
  Idea2Plan: DEC-42
  ```

- 同一提交关联多个资源时，每行记录一个引用。不要使用无法解析的裸数字，也不要只记录项目级 `PRJ-10` 来代替更具体的资源引用。
- `Idea2Plan:` footer 只用于建立追踪关系，不代替 Idea2Plan 中的状态更新、方案评审、版本规划或交付记录。

### 破坏性变更

- 存在不兼容变更时，在 type/scope 后加 `!`，并在 footer 中使用 `BREAKING CHANGE:` 说明迁移方式：

  ```text
  feat(core)!: 调整窗口发现协议

  BREAKING CHANGE: WindowDiscovering 实现需返回新的 WindowItem 字段。
  Idea2Plan: REQ-123
  ```
