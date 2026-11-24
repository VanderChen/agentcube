# 000-4 — 占位运行时档 1：空操作 shim

## 基本信息

| 项 | 值 |
|---|---|
| 所属 | 总体任务 `000`，第一版，里程碑 A。**不在关键路径上** |
| 目标项目 | `agentcube` |
| 基线分支 | `upstream/main`；开工时取当时的 commit 记在这里（规划时是 `6dafef4a`） |
| 任务分支 | `feat/000-4-placeholder-runtime-noop-shim`，尚未创建 |
| 依赖 | 实现依赖 000-2；完成验收还依赖 000-3、000-12。需要先有决定 D4（第一版是否包含档 1）、D10（最低版本） |
| 验证环境 | 开发机上的 Kind |
| 状态 | 未开始 |

总体计划和决定事项的编号见 [README](../README.md)。接缝的编号见 [seams.md](../seams.md)。

## 目标

让占位 Pod 不创建任何容器进程：RuntimeClass 指向一个空操作的 containerd shim，它对 Task API 的调用直接应答。这是占位 Pod 的目标形态。提案里它的全部应答约定都标为“分析，未实验”，所以本子任务先做实验，再定实现。

实验不通过时，第一版以档 0 准出，本子任务记录原因后顺延。

第一版要做占位 Pod 的原地调整（000-12）。档 0 下 kubelet 的调整由 runc 真实执行；档 1 下要靠 shim 的 `Update` 答成功，所以这一条应答从“以后才用”变成了第一版就要验证。

## 范围

1. **shim 二进制。** 放在单独的 Go 模块里，免得 containerd v2 的依赖进入主模块。
   - 任务状态由 shim 自己持有，不经过 `placeholder-agent`。
   - 应答按提案的约定表：`Create` 登记任务，进程号报 shim 自己的；`Start`、`Connect` 成功；`Wait` 阻塞到 `Kill`；`Kill` 在第一个信号就标为停止；`Update` 答空的成功并且幂等；`Stats` 答 NotFound；`Pids` 答 shim 自己的进程号；最后一个任务删除之后 shim 退出。
   - 不创建进程，不挂 rootfs，不建容器 cgroup。
2. **RuntimeClass 对象。** 不写 `overhead`；用 `scheduling.nodeSelector` 限定到装好 handler 的节点。
3. **节点上的安装。** shim 二进制、containerd 的 handler 条目、节点标签。开发机上的 Kind 上用集群配置里的挂载和 containerd 配置补丁带入。真实节点上的安装流程写成文档或安装器，形式在实施提案里定。
4. **池类的 RuntimeClass 字段填上之后，占位 Pod 就是档 1。**

## 与 sandbox-pool 的关系

源码可以复用，但复用不是要求（D9）。shim 是 sandbox-pool 里最值得取用的部分。路径相对于私有仓库 `kuasar-sandbox/sandbox-pool` 的根，`main` @ `e440730b`。

| 来源 | 行数 | 取舍 | 说明 |
|---|---|---|---|
| `pkg/agent/shim_proxy.go` 的 `shimManager` | 约 170 | 原样移植 | containerd v2.3 起的启动协议：参数经标准输入传入，监听 socket 的文件描述符交给子进程，返回版本 3 的结果。提案在这一块只有 Rust 库的证据，这段 Go 代码补上了这个缺口 |
| `pkg/agent/daemon_ttrpc.go` 的 `Start`、`Delete`、`State`、`Kill`、`Wait`、`Connect` | 约 200 | 移植后改 | 合成任务的状态机。现在状态存在 agent 的内存表里，要改成 shim 进程自己持有 |
| 同一文件的 `Create` | 171 | 重写 | 大半是读 OCI 规格和在创建时改容量，这些都不要。留下的只是登记任务，约三四十行 |
| 同一文件的 `Pids`、`Stats`、`Update`、`Shutdown` | — | 重写 | 四个应答都与提案的约定相反：`Pids` 答空列表，`Stats`、`Update` 答未实现，`Shutdown` 清空全部记录而进程不退出 |
| `pkg/agent/shim_proxy.go` 的 `shimProxy` | 约 330 | 不需要 | 它把 17 个调用逐个转发给 agent。档 1 的 shim 自己应答 |
| `cmd/containerd-shim-placeholder-v2/main.go` | 41 | 新写 | 只有一行有效代码 |
| `deploy/yaml/runtimeclass-placeholder.yaml`、`deploy/yaml/containerd-config.toml`、`hack/build-shim.sh` | — | 作参考 | RuntimeClass 要去掉 `overhead`，加 `scheduling.nodeSelector`；containerd 的 handler 条目可以照着写 |

**先跑一遍原样的。** sandbox-pool 的 shim 从来没有留下运行记录。提案阶段先把它原样的 shim 与 agent 在开发机上的 Kind 上跑起来，记下实际行为作为对照：占位 Pod 能否 Ready；节点上有哪些进程；重启 containerd 之后任务还在不在；重启 agent 之后占位 Pod 的任务是否重建；shim 进程是否残留。启动握手值不值得原样取用，也由这一步确认。

**一个要定的名字。** 提案把二进制叫 `containerd-shim-placeholder-v1`，sandbox-pool 叫 `containerd-shim-placeholder-v2`。名字要与 containerd 配置里的运行时类型对应，在实施提案里定。

凡是取用的片段，出处记在本子任务的实施提案里，并注明是原样取用还是改过。

## 实验

编号是提案的编号。都在开发机上的 Kind 上做，先于实现。

| 实验 | 做法 | 通过标准 |
|---|---|---|
| KE-P1 | 建一个档 1 的占位 Pod，旁边放一个档 0 的；任务进程号取 shim 的进程号和 0 各试一次 | 档 1 的 Pod 为 Ready；只有一个 shim 进程，没有容器进程、rootfs 挂载和容器 cgroup；日志里没有重复的错误 |
| KE-P2 | 重启 containerd | Pod 的 UID 和绑定不变，任务保留 |
| KE-P4 | 杀掉 shim；重启 kubelet | 重启计数加一；Pod 对象、绑定和预留不变 |
| KE-P3 的档 1 部分 | 对档 1 的占位 Pod 写 `/resize`，放大和缩小各一次；shim 的 `Update` 分别答成功、未实现、不存在，记下 condition、事件和各方何时改变计数 | 答成功时调整完成，没有重建 Pod；另两种应答的后果记录下来，作为 000-12 处理“`Update` 出错”的依据 |
| KE-P8 | 对档 1 的占位 Pod 执行 `kubectl logs`、`exec`、`top`、`describe` | 不产生持续的错误 |
| KE-P10 的 RBAC 部分 | 以租户身份在租户命名空间建一个使用这个 RuntimeClass 的 Pod | 它不会被当成池 |

通过标准是规划时按提案的准出标准补的，提案自己没有给实验写通过标准。

## 不在范围内

- CRI-O；不能改 containerd 配置的集群。这些集群留在档 0。
- 用准入策略限制谁能使用这个 RuntimeClass。它是可选的加固。

## 要留好的接缝

- 身份：I-23（shim 没有任何 Kubernetes 凭据，不联网）。编号见 [seams.md](../seams.md)。

## 验收

对应第一版的 V1-3。

- 上表的实验全部通过，结果记在本子任务的实施提案里。
- 档 1 的占位 Pod 在调度器一侧的记账与档 0 相同。
- 000-2、000-3 的验收用例在档 1 上同样通过；000-12 的扩容和缩容在档 1 上同样完成（V1-3、V1-8）。
- shim 模块自己的构建、lint、单测通过；主模块的依赖没有新增 containerd 的库。

## 参考

- 应答约定：内部报告 04（提案摘要）第 1.8 节；提案 `04-placeholder-runtime.md` 第 4.2 至 4.6 节。
- sandbox-pool 的 shim 与提案的差距：内部报告 02（sandbox-pool 分析）第 3 节；报告里到文件一级的清单在第 9.5 节，取舍以本文件为准。它的四处做法与提案相反，不要带过来：任务状态放在 agent 里；`Update`、`Stats` 答未实现；`Pids` 答空列表；shim 没有退出路径。
- 提案里有证据的 shim 脚手架是 Rust 的库；Go 的实现以 sandbox-pool 的为基础。
- 开发机上的 Kind 上怎样装入 shim：内部报告 03（运行时调研）第 6.4 节。
- #431 把“最小 shim 验证”写成了验收条件，上游会期待看到这些实验的结果。
