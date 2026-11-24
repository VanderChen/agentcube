# 000-1 — 接口与数据模型定稿

## 基本信息

| 项 | 值 |
|---|---|
| 所属 | 总体任务 `000`，第一版，里程碑 A |
| 目标项目 | `agentcube` |
| 基线分支 | `upstream/main`；开工时取当时的 commit 记在这里（规划时是 `6dafef4a`） |
| 任务分支 | `feat/000-1-contracts-and-seams`，尚未创建 |
| 依赖 | 无。需要先有决定 D7（命名）、D8（代码位置）。第二批定稿要等 000-5 的结论 |
| 验证环境 | 开发机上的 Kind |
| 状态 | 未开始 |

总体计划和决定事项的编号（D1 至 D19）见 [README](../README.md)。接缝的编号见 [seams.md](../seams.md)。

## 目标

提案里的接口、对象和记录都是示意。本子任务把第一版用到的部分落成可评审的定义，供后面的子任务共用，并在这里统一定义身份与可观测的接缝。不改变任何现有行为。

## 分两批定稿

把全部定义放在一个子任务里先做，有两个风险：它会挡住别的子任务，还会定出没有人验证过的接口。所以分两批。

- **第一批**，不依赖运行时：两个 CRD、容量接口、会话记录的字段表、后端接口与放置接口、共用的小包、模板上的后端选择。它批准之后，000-2、000-3、000-7、000-8、000-9 就可以开工；000-12 用到的容量字段和操作号也在这一批。下称 000-1A。
- **第二批**，与运行时有关：节点管理接口里沙箱标识的格式、`generation` 的映射，镜像拉取失败、等待就绪超时、沙箱自己退出各用哪个状态码，`Describe` 里要声明的内容。下称 000-1B。它先出草案，000-6 在开发机的前一半（000-6A）按草案开工；000-5 有结论之后冻结，000-6 的后一半（000-6B）按冻结的版本做。“无容量”不在这一批：账本归节点适配器，它的状态码与运行时无关，放在第一批。

下文“范围”里的第 4 项属于第二批，其余属于第一批。

## 范围

1. **设计文档。** 放在 agentcube 仓库的 `docs/proposals/` 下，目录名待定。内容是第一版范围内的对象、接口、会话记录和接缝，以及它与 #431 的差异、与现有 warm pool 路径的关系。它同时是给上游的提案更新草稿；是否发布按 D12。
2. **两个 CRD 的类型。** 新开 `pkg/apis/sandboxpool/v1alpha1`，用 controller-gen 生成 deepcopy 和 CRD 清单，并生成客户端。与 sandbox-pool 现有类型的关系见下面“与 sandbox-pool 的关系”一节。
   - `SandboxPoolClass`：节点选择器（不可变）、单节点的容量（可以修改，第一版由人工改，见 000-12）、`schedulerName`、优先级类、RuntimeClass（可以为空，空即档 0）、允许使用的命名空间。调节策略只留位置。
   - `SandboxPool`：`spec.classRef`、`spec.nodeName`、`spec.drain`、`spec.capacity`（期望值、操作号、原因）；`status.phase`、`status.carrier`、`status.conditions`、`status.capacity`、`status.provider`、`status.nodeAgent`。`status.capacity` 含容量操作的操作号和阶段，以及已请求、已分配、已应用、已承诺四个量；conditions 里与容量有关的是 `ResourceSynced`、`ResizeDeferred`、`ShrinkDeferred`、`InvariantViolated`。第一版就用到它们（000-12）。
3. **容量接口的 proto。** `ApplyPool`、`GetPoolState`、`SetDrain`、`RemovePool`，含操作号、承载体的 UID 与在位标志、最近一次操作的记录、已承诺量高于目标时的拒绝。提案没有给过它的消息草图。操作号在 000-3 里固定为初值，在 000-12 里按真的用，所以幂等和围栏的规则要在这里写全。要写明的有四点：
   - “被推迟”（缩容时已承诺量高于目标）不是结果，不进幂等缓存，同一个操作号重试时重新判断。
   - 围栏在受理时和提交时各查一次。
   - 承载体状态的更新有自己的序号和 UID 作废规则，与容量操作号无关。000-3 就要用。
   - 池的状态里记下容量操作的开始时间、截止时间和基线，以及这个操作对应池类的哪一次修改。agent 不落本地盘，重启之后靠它们接着计时。
4. **节点管理接口的 proto。** 把旧文档里的草图和本专题的十二项增补合并成一份。第一版实现 `Describe`、`CreateSandbox`、`GetSandbox`、`ListSandboxes`、`DeleteSandbox`、`Watch`；其余方法保留定义，没有声明对应能力时返回未实现。
5. **两个 Go 接口。** 后端接口及其错误集合（无容量、池不可用、能力不匹配、结果不明）；放置接口的请求与结果。
6. **会话记录第二版的字段表。** 每个字段的名字、类型和零值的含义。`backend` 缺省等于 `pod`，并写明它与现有的 `kind` 字段谁是判别依据。
7. **共用的小包。** 关联键常量与三类基数的白名单；主体结构；操作注册表与授权决策接口，以及访问令牌签发的桩；生命周期事件的结构；发件箱条目的格式。
8. **模板上的后端选择。** 走哪个后端、用哪个池类、运行时一侧的模板标识、资源规格，这四个字段的名字和位置。`AgentRuntime` 的模板是完整的 PodSpec，只能走 Pod 路径，所以第一版只考虑 `CodeInterpreter`。光加四个字段不够，还要定按后端分支的校验规则：现有类型要求填 Pod 模板，`authMode` 默认是 `picod`，`warmPoolSize` 大于 0 会驱动 Kubernetes 的 warm pool。池模板要禁止 warm pool，并写明旧的 Pod 字段和 `picod` 模式在池后端下各自怎样处理。

## 与 sandbox-pool 的关系

源码可以复用，但复用不是要求（D9）。本子任务里只有 CRD 的类型在 sandbox-pool 里有对应的东西。路径相对于私有仓库 `kuasar-sandbox/sandbox-pool` 的根，`main` @ `e440730b`。

| 来源 | 取舍 | 理由 |
|---|---|---|
| `pkg/apis/sandboxpool/v1alpha1/types_sandboxpool.go` | 新写，形状作参考 | 15 个类型里有 `SetRef`、`NodeCtlConfig`、`OverrideSpec`、`ResizeInfo`、`NodeCtlStatus`；提案要的 `classRef`、`carrier`、`capacity`、`provider`、`nodeAgent` 都没有。上游对 #431 的评审还要求按 Kubernetes 的 API 约定给每个字段写完整注释，校验写在字段上。可以沿用的是 Phase 的取值和占位 Pod 信息的形状 |
| 历史提交 `b5fb66c` 的 `types_sandboxpoolclass.go` | 作起点 | 它是“池类按节点选择器展开”的版本，与提案同向。要加调度器名、优先级类、RuntimeClass（可以为空） |
| `types_sandboxpoolset.go`、`types_sandboxgroup.go` | 不取用 | 前者是副本数与 scale 子资源；后者是 kuasar 的组、凭据与模板构建 |
| `zz_generated.deepcopy.go`、`deploy/yaml/crd-*.yaml` | 不取用 | 是手写的；用工具生成 |

容量接口、节点管理接口、会话记录、共用的小包在 sandbox-pool 里没有对应的东西。

凡是取用的片段，出处记在本子任务的实施提案里，并注明是原样取用还是改过。

## 不在范围内

任何控制器、适配器或后端的实现。

## 要留好的接缝

本子任务负责定义。编号见 [seams.md](../seams.md)。

- 身份：I-10（会话接口携带主体、租户、策略版本）、I-11（决策函数的签名）、I-14 与 I-15（节点管理接口里有类型的归属字段和预留字段）、I-1 至 I-7 的字段定义。
- 可观测：O-1（关联键集中定义，前缀 `agentcube.`）、O-12（生命周期事件的格式）、O-19 与 O-20（游标、收尾用量、遥测来源的字段位置）、O-10 与 O-15 的字段定义。

## 开工前要回答的问题

| 问题 | 来源 |
|---|---|
| API 组与对象名；标签、注解、finalizer 的前缀 | D7；提案的待决策 PD-7；#431 的评审意见 |
| 池类上要不要有“用哪种运行时”的字段 | 提案没有这个字段 |
| `priorityClassName` 放在 `spec` 顶层还是占位 Pod 的模板之下 | 提案两份文档不一致 |
| 操作号的初值；过期的操作号、过期的 `generation`、命中墓碑各用哪个状态码 | 提案没有写 |
| 承载体更新的序号由谁产生，怎样在 agent 重启之后保持单调 | OQ-41；提案没有设计 |
| 撤销或重试一个容量操作的人工入口放在哪个对象上 | 第一版没有容量调节器，见 000-12 |
| 归属字段与已预留的负载上下文在组和父会话上重叠，合并还是并列 | 提案的未决问题 OQ-1 |
| 容量接口携带占位 Pod 的 UID 与命名空间 | OQ-3，模块文档已按“带”来写 |
| 墓碑保留时间的默认值 | OQ-54 |
| 公开沙箱标识的格式，以及 `generation` 怎样映射到运行时一侧的标识 | 提案要求只含小写字母和数字；containerd 对容器标识的约束由 000-5 给出；containerd 和 Kata 都没有 `generation` 的概念，建议放在容器的标签里 |
| `ResizeDeferred` 和 `status.capacity.allocated` 在两份文档里含义不同，取哪个 | 提案摘要 2.3 节。第一版就用到，建议取 `03-scheduling.md` 的口径：`ResizeDeferred` 指扩容被 kubelet 推迟，`ShrinkDeferred` 指缩容被已承诺量挡住，`allocated` 指 kubelet 分给占位 Pod 的量 |
| 期望容量、操作号、原因这三个字段由谁写 | 提案里是容量调节器。第一版没有它，建议由池控制器写，第四版换成调节器，字段不变 |
| 池类上的容量改了之后，要不要允许单个池另取一个值 | 提案没有写手工调整。建议第一版不允许 |
| Lease 的名字取池名还是节点名 | #431 写池名，sandbox-pool 用节点名 |
| 池模板是扩展现有的 `CodeInterpreter`，还是新增一个模板对象 | 提案的待决策 PD-5 建议扩展；现有类型的 Pod 模板、`authMode`、`warmPoolSize` 与池后端的语义要互斥，见范围第 8 项 |
| 会话存储是否只支持单节点 | 键的布局要在冻结之前定；见 000-7 |

## 验收

- `make gen-all`、`make gen-check`、`make lint`、`make test`、`make build-all` 通过。
- 两个 CRD 能装进开发机上的 Kind；合法的样例被接受，不合法的样例被拒绝，校验规则写在类型上。
- 现有单测通过，没有任何现有路径调用新代码。
- 设计文档里每个接口都有字段表和错误模型；归本子任务的接缝逐条对应到字段或签名。

## 参考

- 提案摘要：内部报告 04（提案摘要）第 1、2、5、6 节和 9.1 节。
- sandbox-pool 的类型与 #431 的出入：内部报告 02（sandbox-pool 分析）第 7.1、8.2、9.2 节。
- 现有 CRD 的生成约定：内部报告 01（基线现状）第 4 节。
- 容量字段与操作号的草图：提案 `03-scheduling.md` 第 6.12 节。
- containerd 一侧的标识与标签：000-5 的产出。
