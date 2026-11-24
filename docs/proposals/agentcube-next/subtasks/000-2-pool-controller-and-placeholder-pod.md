# 000-2 — 池控制器与占位 Pod

## 基本信息

| 项 | 值 |
|---|---|
| 所属 | 总体任务 `000`，第一版，里程碑 A |
| 目标项目 | `agentcube` |
| 基线分支 | `upstream/main`；开工时取当时的 commit 记在这里（规划时是 `6dafef4a`） |
| 任务分支 | `feat/000-2-pool-controller-and-placeholder-pod`，尚未创建 |
| 依赖 | 000-1。需要先有决定 D5（调度器）、D6（承载体）、D10（最低版本）。D9 已确认：sandbox-pool 的源码可以复用，按组件取舍 |
| 验证环境 | 开发机上的 Kind |
| 状态 | 未开始 |

总体计划和决定事项的编号见 [README](../README.md)。接缝的编号见 [seams.md](../seams.md)。

## 目标

实现占位 Pod 机制在 Kubernetes 一侧的部分：建一个池类，每个被选中的节点上出现一个池和一个占位 Pod；占位 Pod 丢失后在原节点重建。本子任务只做档 0，即普通的 pause Pod。

## 范围

1. **池控制器。** 独立的二进制和 Deployment，带选主，有自己的 ServiceAccount。不放进 WorkloadManager 进程：后者没有选主，权限也不该扩大。
2. **池类到池。** 按节点选择器展开，一个节点一个池，名字是确定的；同一个节点被两个池类选中时拒绝后来者。
3. **池到占位 Pod。** 在池命名空间里创建，属主引用指向池。规格按提案的节俭规格：
   - 只在容器级设 cpu 与 memory 的 requests，不设 limits；
   - 用必需的节点亲和钉在本池的节点上；
   - 不挂 ServiceAccount 令牌，不开 service links，宽限期为 0，不设探针、端口、卷；
   - 不用 `hostNetwork`；
   - `schedulerName`、优先级类、RuntimeClass 取自池类，RuntimeClass 为空即档 0；
   - 镜像用节点上已有的 pause 镜像。
4. **状态。** 控制器把承载体的命名空间、名字和 UID 写进池的状态；根据各 condition 聚合 Phase；根据 Lease 是否过期写 agent 是否健康；节点不存在时标记。
5. **承载体丢失。** 占位 Pod 被删除或被驱逐后，池记为 Degraded，控制器立即在原节点重建。被驱逐留下的 Failed Pod 要先删再建。同名的旧对象还在终止时怎样等待和重试，要有规则。
6. **删除。** finalizer 流程：先排空，再移除池，最后删占位 Pod。池里还有沙箱时不强制移除。从未应用过容量的池可以直接移除；应用过容量的池要等 `placeholder-agent` 确认已经排空并停用，这一半在 000-3 里接上。
7. **安装。** chart 里新增两个命名空间、优先级类（取值不超过 1e9，不抢占别人）、控制器的 Deployment 与 RBAC。控制器没有 `pods/resize` 权限。
8. **事件与指标。** 事件只打在池对象上；指标的前缀和标签按 000-1 的规则。

## 与 sandbox-pool 的关系

源码可以复用，但复用不是要求（D9）。下表按函数级的盘点给出取舍，依据见[gap-analysis.md](../gap-analysis.md) 第 3.2 节。路径相对于私有仓库 `kuasar-sandbox/sandbox-pool` 的根，`main` @ `e440730b`；行数是非测试行数。

| 来源 | 行数 | 取舍 | 说明 |
|---|---|---|---|
| 历史提交 `b5fb66c` 的 `pkg/controller/sandboxpool/class_reconciler.go` | 718 | 移植，小改 | 它做的就是本子任务要的：列出目标节点、逐节点确保池存在、节点冲突检查、创建时写入池类引用与节点名、确定性的池名、类的删除、聚合状态。要改的是类型名、池的初始容量、指标与日志的约定 |
| `pkg/controller/sandboxpool/pool_reconciler.go` | 1045 | 移植对得上的约 750 行 | 取：节点是否存在及其 condition、按 Lease 判活并按到期时间重排队、Phase 的计算与写入、删除流程、调度失败的检测。不取：事后回填节点名、按副本集清理、副本集到池的映射。Phase 的计算里 node-ctl 与改容量的分支换成提案的 condition |
| 承载体丢失后的处理 | — | 新写 | sandbox-pool 没有：它不记承载体的 UID，被驱逐留下的 Failed Pod 不重建，丢失之后不记 Degraded |
| `pkg/controller/sandboxpool/pod_builder.go` | 269 | 新写 | 现有规格逐个字段几乎都与节俭规格相反：requests 等于 limits、以 root 运行、容忍一切污点、反亲和、RuntimeClass 不能为空、优先级类写死 |
| `helpers.go`、`metrics.go`、`cmd/sandboxpool-controller/main.go` | 387 | 新写 | 都是小文件。判断 condition 的函数与 apimachinery 的现成函数重复；指标的前缀和埋点方式按 000-1 的规则；`main` 按 agentcube 现有的写法 |
| `pkg/webhook/sandboxpool/` | — | 视需要 | 能用类型上的校验规则表达的不做 webhook；第一版要不要 webhook 在实施提案里定 |
| 控制器的 7 个测试文件 | — | 重写 | 它们建在 sandbox-pool 自写的内存客户端上，那个客户端不模拟 API server 的校验。用例场景作参考 |

取用时要逐处清掉三个假设：kubelet 会重建容器；node-ctl 会热加载配置；一个节点可以有多个池。它还用了三个已标为弃用的 controller-runtime 接口，取用时换成新的。

凡是取用的片段，出处记在本子任务的实施提案里，并注明是原样取用还是改过。

## 不在范围内

- 档 1 的 shim（000-4）。
- `placeholder-agent` 和容量交接（000-3）。没有它时池停在 Pending，这是预期的。
- PodDisruptionBudget 的效力、节点被 cordon 触发的排空、按节点身份限制状态写入的 webhook。它们在第三版；最后一项在此之前记为已知的安全缺口。
- 运行中调整占位 Pod 的大小（第四版）。

## 提案阶段要做的刻画

在开发机上的 Kind 上，不需要写控制器代码：

- 手工建一个节俭规格的 pause Pod，确认调度器看到的节点已请求量的增加值等于它的 requests。
- 提案的实验 KE-P3：对它写 `/resize` 子资源，放大和缩小各一次，记录 condition、事件和调度器何时改变计数。第一版不使用这个能力，但它决定占位 Pod 的规格以后要不要返工。
- 删除它，确认节点可分配量回到原值。

## 要留好的接缝

编号见 [seams.md](../seams.md)。

- 身份：I-23（控制器没有 `pods/resize`；占位 Pod 所在的命名空间里租户没有任何权限）。承载体的 UID 由控制器写，`placeholder-agent` 以后只认这条记录。
- 可观测：O-24（事件只打在池对象上）、O-11（不占用注解名 `opentelemetry.io/trace-context`）、O-2 与 O-5（指标标签只用不随会话数增长的标识，前缀 `agentcube_`）。

## 验收

对应第一版的 V1-1，以及 V1-2 里属于控制器的部分。

- 建一个池类：每个匹配的节点上有一个池和一个占位 Pod，Pod 为 Ready；节点已请求量的增加值等于它的 requests。
- 占位 Pod 没有 `hostNetwork`；池命名空间不需要特权级；一个只有租户权限的身份在池命名空间里建不了 Pod。
- 删除占位 Pod：池变为 Degraded；新的 Pod 在同一个节点上出现；池状态里承载体的 UID 更新。
- 删除池类（集群里没有 `placeholder-agent`，容量从未应用）：池和占位 Pod 被清理，节点可分配量回到启用之前。应用过容量之后的删除在 000-3 里验收。
- 单测、lint、生成检查通过；现有端到端测试不受影响。

## 参考

- 对象与字段：内部报告 04（提案摘要） 第 2.2 至 2.5、2.7 节；失败分支见 9.2 节。
- sandbox-pool 与提案的逐条对照：内部报告 02（sandbox-pool 分析） 第 7.1 节第 1 至 8、16、18 至 24 条；控制器的 reconcile 与占位 Pod 的现有规格见第 2.4、2.5 节；报告里到文件一级的清单在第 9.5 节，取舍以本文件为准。不要带过来的做法：副本数与 HPA、事后回填节点名、requests 等于 limits、写 `overhead`、容忍一切污点。
- 提案：`04-placeholder-runtime.md` 第 2.3 节、第 6.2 节；`modules/pool-controller.md`。
