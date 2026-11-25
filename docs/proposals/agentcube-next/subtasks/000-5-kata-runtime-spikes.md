# 000-5 — Kata 接入实验

## 基本信息

| 项 | 值 |
|---|---|
| 所属 | 总体任务 `000`，第一版，里程碑 B |
| 目标项目 | 不产出上游代码。实验的计划、脚本和操作记录见 [experiments/](../experiments/README.md)，每个实验一个目录；原始输出和机器的状态记录留在内部工作区。这样做是为了便于审计和以后复用 |
| 被测版本 | Kata、VMM、containerd 各一个固定版本，开工时选定并记在这里。此前的 Kata 研究读的是 4.4.0（commit `2e1efbe1`） |
| 任务分支 | 无 |
| 依赖 | 无。需要 KVM 的部分要先有决定 D2（带 KVM 的机器） |
| 验证环境 | 开发机上的 Kind（用 runc 当替身）；带 KVM 的机器。另有一台可丢弃的虚拟机（2026-11-25 提供），没有硬件虚拟化，第一段和 PVM 的实验可以在它上面做；PVM 的实验已在它上面做完，换到 PVM 的宿主之后它有 `/dev/kvm`，Kata 可用 |
| 状态 | 进行中。PVM 的五个实验在 2026-11-25 做完：E0、E1、E3 通过，E2 不通过，E4 是补的对照；第一段、第二段的实验未开始 |

总体计划和决定事项的编号见 [README](../README.md)。接缝的编号见 [seams.md](../seams.md)。

## 目标

运行时已经定为 containerd 加 Kata，VMM 由实验定（D1）。目前对 Kata 的了解来自静态阅读，没有一条运行过。本子任务回答节点适配器（000-6）开工前必须知道的事，并把结果写成适配器可以直接照做的规则。

它是运行时接入的硬闸门，分两段：

- **第一段在开发机做，不需要 KVM。** 节点适配器调的是 containerd 的接口，用哪个运行时只是一个名字。先用 runc 当替身，把“在 Kubernetes 之外经 containerd 发放一个沙箱”走通。这一段做完，000-6 的前一半（000-6A）就可以开工。
- **第二段需要带 KVM 的机器。** 把 runc 换成 Kata，选出 VMM。这一段做完，000-6 的后一半（000-6B）开工，000-1 里与运行时有关的定义（000-1B）冻结。

“runc 能当替身”是分析，不是事实，第一段的第一个实验就是验证它。

## 实验

编号是本子任务自己的。提案的实验清单是按 kuasar 写的，这里用不上。

**第一段：开发机上的 Kind，runc 当替身。** 实验都在 Kind 节点的容器里做，不改宿主机。KA-7 是例外：它的 eBPF 程序装进的是与宿主共用的内核，见该行。

| 实验 | 做什么 | 通过标准 |
|---|---|---|
| KA-1 经 containerd 的原生接口发放 | 在 Kind 节点的 containerd 上，用一个独立的 namespace（不是 kubelet 用的 `k8s.io`），以调用方指定的标识创建容器和任务，执行一条命令，删除。用同一个标识再创建一次 | 流程走通；重复创建被拒绝，错误可以识别；给出标识的格式约束 |
| KA-2 kubelet 会不会动它 | 让 KA-1 的容器运行着，经过若干个 kubelet 的同步周期；重启 kubelet；重启 containerd | 容器一直存活；`crictl` 里看不到它；节点上没有多出 Pod 对象或事件。对照：经 CRI 在 `k8s.io` 里创建的沙箱会不会被 kubelet 清理，记录下来 |
| KA-3 沙箱的 cgroup 放在哪 | 建一个池级的父 cgroup，放在 kubelet 管理的层级之外；经 OCI 规格把沙箱放到它下面；给父 cgroup 设内存和 CPU 的上限；运行中改上限；删除占位 Pod。对照：把沙箱放到占位 Pod 的 cgroup 下面再删除 Pod | 沙箱的进程都在父 cgroup 下；上限生效；改上限不影响运行中的沙箱；删除占位 Pod 之后沙箱存活。给出父 cgroup 的路径规则和 Kind 节点的 cgroup 驱动之下的写法（D18） |
| KA-4 镜像 | 在独立的 namespace 里拉一个镜像并建快照；记录首次拉取和第二次创建的耗时；看 `k8s.io` 里已有的镜像内容能不能复用 | 给出第一版镜像怎样到节点上：按需拉取还是预置 |
| KA-5 事件与重建 | 订阅 containerd 的事件，杀掉沙箱里的进程；给容器打标签，再只凭列表和标签把“哪些是我的、属于哪个池、多大”找回来 | 收到退出事件；标签足够重建账本和身份表 |
| KA-6 适配器装在哪里 | 适配器要用 containerd 的 socket 和 cgroup 文件系统。各试一次：节点上的系统服务；系统命名空间里的特权 DaemonSet。看 WorkloadManager 的 Pod 怎样连到它，`placeholder-agent` 怎样拿到容量接口的 socket | 选出一种并写明理由。它同时回答提案的未决问题 OQ-9，以及两项待决策：运行时的接入方式（ND-2）、节点部件怎样打包（KD-A7） |
| KA-7 connector 的 veth 端口 | connector 是 kuasar-sandbox 的节点交换机，用 eBPF 做转发，可以单独使用。它是沙箱网络的候选之一（D20）。钉住它的一个版本，在 Kind 节点里起一个交换机：端口形态选 veth（默认是 TAP），给出端口命名空间和管理面的抽取网段，不配上联。给 KA-1 的容器建一个网络命名空间，要建在 `/var/run/netns` 下，connector 只认那里的名字；用它的 `attach --to-netns` 接一个 veth 端口，在命名空间里把地址和路由配到这个 veth 上。从节点上的管理命名空间经浮动地址访问容器里的一个端口，访问方的源地址要落在抽取网段里；起两个容器互相访问；删除容器后 detach，再用同一个端口、换一个代数接一个新的容器；另试一次先删命名空间、再 detach | 节点上访问得到容器；两个容器互相不通；端口能回收再用，旧的浮动地址不再访问得到，流量不会落到旧的容器上；命名空间先被删掉时端口也收得回来，收不回来就记下要怎样清。它的 eBPF 程序在 Kind 节点的内核和容器权限下能加载；加载不了就记下缺什么，把这一项挪到带 KVM 的机器上做。eBPF 程序装进的是与宿主共用的内核，只挂在 Kind 节点里的设备上；做之前先说明，实验结束后停掉交换机，确认程序和 pin 的 map 都已经清掉 |

**第二段：带 KVM 的机器。**

| 实验 | 做什么 | 通过标准 |
|---|---|---|
| KB-1 环境验收 | 安装 Kata；用 containerd 的命令行工具以 Kata 的运行时起一个容器，执行一条命令 | 沙箱里的内核版本与宿主不同；记下节点上多出的进程（shim、VMM、文件共享进程）和它们的 cgroup |
| KB-2 把 runc 换成 Kata | 重做 KA-1、KA-2、KA-3、KA-5，只换运行时的名字 | 结果与第一段相同；不同的地方逐条记下，交给 000-6 |
| KB-3 选 VMM | Firecracker、Cloud Hypervisor、Dragonball 各做一遍 KB-2。比较见下 | 选出一种并写明理由；钉住 Kata、VMM、containerd 的版本 |
| KB-4 microVM 的规格从哪里来 | 不经 CRI、直接经 containerd 创建时，microVM 的 vCPU 和内存怎样由 OCI 规格决定。分别试带限额和不带限额的规格 | 给出三个量之间的换算规则：声明的规格、microVM 实际的 vCPU 与内存、宿主上的预算。分数核会向上取整，内存会加上 guest 一侧的开销，所以验的是规则，不是“相等”。在沙箱里读到的 CPU 和内存与规则算出的一致 |
| KB-5 每个沙箱的开销 | 起若干个空闲的沙箱，量每个沙箱在宿主上的内存和进程数；再让沙箱把自己的内存用满 | 给出宿主一侧每个沙箱的固定开销（VMM、shim、文件共享进程），也就是宿主预算比 microVM 的配置多出来的部分（D15）。Kata 给 RuntimeClass 配的值是 130Mi 内存、250m CPU，作对照 |
| KB-6 cgroup 的上限在 Kata 下是否兜得住 | 每个沙箱在池的父 cgroup 下有自己的 cgroup，上限是它的宿主预算。池填满之后，让一个沙箱用超自己的内存。Kata 的 `sandbox_cgroup_only` 开和关各试一次 | 被杀的是这个沙箱自己，别的沙箱和常规 Pod 不受影响；VMM、shim、文件共享进程都在这个沙箱的 cgroup 里，没有落到不设上限的层级里。给出必须怎样配置 |
| KB-7 网络 | Kata 要调用方准备一个带虚拟网卡的网络命名空间，不支持宿主机网络。试：不给网络；适配器调 CNI 插件；connector 的 veth 端口，即把 KA-7 里的 runc 换成 Kata 重做一遍 | 确认没有网络时沙箱能否启动、能否执行命令。connector 的 veth 端口之下：Kata 不用改就能接上，地址在创建任务之前配好；guest 里拿到的地址和路由与命名空间里配的一致；从节点经浮动地址访问得到 guest 里的端口；两个沙箱互相不通；端口回收再用成立，包括杀掉 shim 之后再接。选定的 VMM 走哪个 runtime 就试哪个，Go runtime 和 runtime-rs 都在候选里时各试一遍。给出第一版和第二版各用什么做法（D20） |
| KB-8 用哪一个 containerd | kubelet 的那个加独立 namespace，对比节点上另起一个 containerd。看：改配置要不要重启 kubelet 的 containerd；Firecracker 要的块设备快照器会不会牵连常规 Pod；containerd 重启之后 Kata 的沙箱是否存活 | 给出选择和理由（D19） |
| KB-9 正式的验证形态 | 把 `/dev/kvm` 交给 Kind 节点的容器，在 Kind 节点里起 Kata 的沙箱 | 走得通，带 KVM 的机器上仍然用 Kind；走不通，改用单节点的 kubeadm 集群，并写明安装步骤 |
| KB-10 退出与收尾的次序 | 杀掉沙箱的主进程；在沙箱里执行一条命令并让它退出；启动之后立刻删除。记录 containerd 事件的次序，以及 VMM 的进程和 cgroup 何时消失 | 给出适配器怎样区分“命令退出”和“沙箱退出”，以及凭什么确认宿主上的资源已经释放 |

**选 VMM 时比较什么。** 第一阶段不要快照、暂停恢复和运行中改沙箱的规格，所以这些不计入。比较的是：

| 项 | 为什么要看 |
|---|---|
| 安装要求 | 静态阅读的结论是：Firecracker 要块设备快照器（devmapper），并且 Kata 的打包里它走的是已经弃用的 Go 运行时；Cloud Hypervisor 和 Dragonball 走默认的 Rust 运行时。要实测确认 |
| 冷启动耗时 | 第一阶段没有模板快速启动，每次创建都是冷启动 |
| 每个沙箱的固定开销 | 直接决定一个池能放多少个沙箱 |
| 能不能在 Kind 节点里跑 | 决定验证形态 |
| 维护状态 | 上游是否还在加功能、CI 是否覆盖 |
| 没有 KVM 的虚拟机上能不能用 | 这类机器只能靠 PVM。PVM 项目测过的 Kata 组合是 QEMU、Dragonball、Cloud Hypervisor，没有 Firecracker，见下面“没有 KVM 的虚拟机”一段 |

有人提议用 Firecracker。它的短处在上表第一行，长处是隔离面小。实验给出数据之后再定，不预设结论。

**闸门的出口。**

- 第一段通过：000-6A（runc 替身）开工。KA-1 或 KA-2 不通过，即 Kubernetes 之外的容器在 kubelet 的 containerd 上活不住时，先试另起一个 containerd；仍不通过就报给负责人。
- 第二段通过：VMM 选定，下面的产出齐全，000-6B 开工。
- KA-7 不是闸门。它不通过时沙箱网络取别的做法，把原因记下来，不挡 000-6A。
- Kata 在选定的机器上起不来，或者三种 VMM 都不满足要求时，不自行换路线，报给负责人。可选的出路：改用 QEMU；回到 kuasar 的路线，见[gap-analysis.md](../gap-analysis.md) 第 4.2 节。在带 KVM 的机器上，kuasar 是一条现成的退路；在没有 KVM 的虚拟机上不是，见下一段。

**没有 KVM 的虚拟机：PVM 上的 Kata，以及它不行时怎么办。** 开发机是一台没有嵌套虚拟化的虚拟机，没有 `/dev/kvm`。这类机器上要起 microVM，只有 PVM 一条路：它是 KVM 的一个厂商模块，不需要硬件虚拟化，装上之后节点上就有 `/dev/kvm`。

对 Kata 来说，这条路有 PVM 项目一侧的依据。下面几条是 2026-11-24 读它的文档和测试脚本得到的，没有运行：

- PVM 项目的说明写的是，它是为了在没有硬件虚拟化的情况下支持 Kata Containers 而做的，并附一份在 PVM 上运行 Kata 的指南（`virt-pvm/misc` @ `beaa849c`）。Kata 自己的仓库里没有提到 PVM。
- PVM 项目发布宿主模块包时的测试包含 Kata 配 QEMU、Dragonball、Cloud Hypervisor 三种组合，用的是 Kata 的 Rust 运行时（`virt-pvm/pvm-context` @ `276edd0c`）。2026-11-20 发布的 v0.1 称六个目标系统全部通过。
- 这套测试是用 `ctr run --runtime io.containerd.kata.v2` 发起的，不经 CRI，沙箱不带网络命名空间。它是“不经 CRI、直接经 containerd 用 Kata”这一用法的旁证，KB-4、KB-7 可以参照。
- 条件：宿主要装 PVM 的内核模块，并带关闭 KPTI、KASLR 一类的启动参数重启；guest 内核要换成带 PVM 支持的那一个，Kata 自带的不行；Firecracker 不在它测过的 Kata 组合里。
- 现成的模块包只对应几个确切的内核版本，Ubuntu 24.04 上是 `6.8.0-139-generic`。开发机是 `6.8.0-149-generic`，用不上，要换内核或者自己构建。2026-11-25 查到 Ubuntu 的软件源里还有 `6.8.0-139` 的内核包，所以在可丢弃的虚拟机上可以装回这个内核、再装现成的模块包，不用换成别家发行版的内核，也不用自己构建。模块包的测试环境给宿主加的启动参数是 `nokaslr`。
- PVM 项目说 AMD 的机器需要另外取证。开发机是 AMD 的虚拟机。E0 给出了宿主一侧的第一份，见下面 E0 的结果。

所以做实验之前的结论不是“Kata 不支持这类虚拟机”，而是“有 PVM 项目测过的路，但没有在这类机器上验证过”。下面的实验要先得到负责人同意，并且只在另一台与开发机同规格、可丢弃的虚拟机上做，不在开发机做。

2026-11-25 负责人提供了这样一台虚拟机，并说明可以在上面换内核。计划作者只读地查过它：云上的 KVM 虚拟机，Ubuntu 24.04、内核 `6.8.0-149-generic`、AMD EPYC 9845、16 核、31 GiB，没有 `/dev/kvm`，没有嵌套虚拟化。评估的结论：第一段的实验和 E0、E1 可以在它上面做；它不是带 KVM 的机器，第二段要等 E0、E1 通过；PVM 项目测过的 Kata 组合里没有 Firecracker，所以在它上面比较不了 Firecracker。它的 CPU 与开发机不是同一代，结论说明的是“AMD 的云主机、没有嵌套虚拟化”这一类机器。E0 的做法、风险和需要负责人配合的事，评估记录留在内部工作区。

| 实验 | 目的 | 通过标准 |
|---|---|---|
| E0 | 这类机器上 PVM 的宿主能否起来 | 重启后可登录；`/dev/kvm` 存在；内核日志没有 PVM 相关的错误；Docker 和 Kind 仍可用 |
| E1 | 这类机器上 Kata 能否在 PVM 上起沙箱 | 换上 PVM 的 guest 内核之后 KB-1 通过；QEMU、Dragonball、Cloud Hypervisor 各试一遍；创建、执行、删除重复十次全部成功 |

E0、E1 通过只说明没有嵌套虚拟化的机器也能做第二段。这样的证据能不能算第一版的准出，由负责人定。

**E0 的结果（2026-11-25）：通过。** 下面是在那台可丢弃的虚拟机上测到的。装回 `6.8.0-139-generic`、带 `nokaslr` 启动、装上 PVM 项目 v0.1 的模块包之后：用 kexec 和经云的启动加载器冷启动各进入一次，都能登录；`modprobe kvm-pvm` 之后 `/dev/kvm` 出现，能建出 VM 和 vCPU 对象；内核日志除了“树外模块、没有签名”的两行之外没有新的内容；Docker 可用，Kind 的节点和系统 Pod 全部 Ready。范围：

- 只到宿主一侧，没有运行任何 guest。PVM 在这款 CPU 上能不能跑起 microVM，是 E1 的事。
- 一台机器，每种启动方式一次。
- 那台机器的默认启动项没有改，`kvm-pvm` 不开机加载。PVM 宿主要用一次性的启动项进入，重启之后回到原内核。这是为了保住失联时“从控制台重启一次就恢复”的退路。
- 顺带测到两点。五级页表开着也能加载，不用加 `no5lvl`。`kvm-pvm` 在这台 AMD 宿主上拒绝给 vCPU 写回 MSR 0x3a：读得到，值是 0，它不在 KVM 报告的 MSR 列表里。这与 CubeSandbox 在 AMD 上修过的那个问题描述一致；只在 ioctl 层面看到，对 Kata 的三种 VMM 有没有影响，要到 E1 才知道。

操作记录见 [experiments/E0/RECORD.md](../experiments/E0/RECORD.md)。

**E1 的结果（2026-11-25）：通过。** 在 E0 的宿主上，照 PVM 项目的做法和它钉的版本：Kata 4.2.0 的静态包（Rust 运行时），guest 内核用 PVM 项目的 `pvm-612` 分支（6.12.33）和它钉住的配置编出来。测到的：

- PVM 项目的直接启动检查里 guest 起来了，约 2 秒后 kata-agent 就绪。这是这台机器上第一次运行 guest 代码，说明 PVM 在这款 AMD CPU 上跑得起 guest。
- KB-1 通过：QEMU、Dragonball、Cloud Hypervisor 各从镜像起一个容器并执行命令，沙箱里的内核是 `6.12.33`，与宿主不同；宿主上的进程和 cgroup 记下了。
- 三种 VMM 各做十次创建、执行、删除，全部成功。
- 要知道的三点。创建一个沙箱要 6.5 到 8 秒，其中有一段约 5 秒的固定间隔，夹在 shim 的两行日志之间，时间花在哪里没有查。QEMU 的删除 13 次里有 3 次收尾不干净（shim 没有立刻退出，其中两次量到约 25 秒；留下一个 cgroup 目录和一个共享目录），另两种没有出现。宿主内核日志里每起一台虚拟机有一行 `Unhandled WRMSR`，是对没有实现的 MSR 的提示，guest 不受影响。
- 范围：经 containerd 的命令行工具，不经 Kubernetes；没有网络；没有并发；没有测 Kata 4.4.0，也没有测 Firecracker 作为 Kata 的 VMM。

**CubeSandbox 的对照（2026-11-25）。** 判断次序里原先把 CubeSandbox 放在“E1 不通过时”。E1 通过了；负责人要求把 CubeSandbox 也验证了，所以做了三个实验，编号 E2、E3、E4：

- E2，不换内核，在 E0 的宿主上装 CubeSandbox v0.8.0：**不通过。** 装得上，服务都起得来，建模板时 microVM 一启动就复位。用上游的 Cloud Hypervisor 和 Firecracker 直接启动它自带的 PVM guest 内核，同样一启动就复位；启动 PVM 项目的 guest 内核则正常。所以不在它的 VMM。
- E3，换上 CubeSandbox 自己的 PVM 宿主内核（`6.6.117`，照它的文档带一长串启动参数）：**通过。** 建模板 20 秒；从模板建沙箱、执行代码、删除，十次全部成功，创建 79 到 99 毫秒。
- E4，把 E2 的原因弄准。E2 和 E3 的宿主除了内核不同，启动参数也不同，所以补了对照：在 E0 的宿主上关掉五级页表，CubeSandbox 的 guest 内核仍然复位；让 CubeSandbox 的宿主内核带同样的参数启动，它自己的 guest 内核起得来，PVM 项目的 guest 内核反而在约 1 秒后复位。**所以 E2 与 E3 的差别不能用启动参数解释；测到的是这两个宿主（内核连同它的 PVM 模块）和这两个 guest 内核只能按原配用。** 换掉的是整个宿主内核，每边只有一个版本，原因没有查。这几格是用两个 VMM 直接启动 guest 内核测的，没有经 Kata 或 CubeSandbox。
- E4 还测到：在 CubeSandbox 的宿主内核上（只带 `nokaslr no5lvl`），CubeSandbox 十次全部成功；Kata 把 guest 内核换成 CubeSandbox 的，Dragonball 和 Cloud Hypervisor 起得了沙箱，QEMU 没有起来。这是没有人写进文档的组合，证据只有几个沙箱；两边的 microVM 没有同时存在过。
- 所以这台 AMD 机器上两者都能在 PVM 上用。照各自文档的做法，它们要的宿主不同；要在同一个宿主上并存，现在只有上一条那一种搭法。
- 这对下面“E1 不通过时看 kuasar”一段的影响：那一段的前提（E1 不通过）没有发生。它里面“用 CubeSandbox 做对照，确认这类机器上 PVM 的 microVM 起得来”这一步，E3 已经做了。

五个实验的计划、脚本和操作记录见 [experiments/](../experiments/README.md)；原始输出留在内部工作区。

**E1 不通过时看 kuasar。** 这是负责人 2026-11-24 的要求。先给静态的结论：在这类机器上，kuasar 的处境比 Kata 差，不是更好。

| | Kata | kuasar-sandbox |
|---|---|---|
| 有没有 PVM 的依据 | Kata 的仓库里没有；PVM 项目把 Kata 当作首要目标，发布时测 | 没有。它的九个仓库（含 Cloud Hypervisor 分叉）里检索不到 PVM，2026-11-24 重新检索过 |
| guest 内核 | 换成 PVM 项目的 6.12 内核，在 Kata 的配置里改一个路径 | 自带的是 6.1 加两个补丁。PVM 的 guest 支持只有 6.6、6.7、6.12 三条线，要在 PVM 的内核树上重新编译并移植补丁 |
| 运行时的代码 | 不用改 | 要改。它把根文件系统挂成 pmem 设备，PVM 下要限制 guest 的地址宽度，这一步在它的 `sandbox-ctl` 里没有 |
| 先例 | PVM 项目的测试 | 没有 |

开源的 Kuasar（`kuasar-io/kuasar`）在 GitHub 的代码和 issue 检索里同样没有 PVM 的命中。它的 microVM 沙箱用的是 Cloud Hypervisor、StratoVirt、QEMU，Quark 沙箱按它自己的说明要起 KVM 虚拟机。

所以 E1 不通过时，按下面的次序判断，不直接换成 kuasar：

1. E0 就不通过：是这类机器跑不了 PVM，换哪个运行时都一样。出路只有带 KVM 的机器。
2. E0 通过、E1 不通过：先用 CubeSandbox 做对照。它有成文的 PVM 部署方式，用来确认这类机器上 PVM 的 microVM 起得来，把问题定位到 Kata。
3. 确认是 Kata 的问题之后评估 kuasar。做法是内部报告 03（运行时调研）第 6.6 节列的四个实验，第一个是用 PVM 的内核树编出 kuasar 的 guest 内核并手工启动。这相当于给 kuasar 增加一种宿主类型，工作量先报给负责人再决定。

## 产出

- 经 containerd 发放一个沙箱的步骤：namespace、运行时的名字、OCI 规格里要写的字段、标签。适配器照做。
- 选定的 VMM，钉住的 Kata、VMM、containerd 版本，可重复的安装步骤。
- 用哪一个 containerd（D19）。
- 池级 cgroup 的做法：路径、上限、扩容和缩容时改上限的次序（D18）。
- 每个沙箱的记账规则和固定开销的取值（D15）。
- 网络的做法：第一版用什么，第二版用什么；取不取 connector，取的话钉住的版本和安装步骤（D20）。
- 适配器装在哪里、监听在哪里，`placeholder-agent` 怎样拿到容量接口的 socket。
- 给 000-1 第二批的输入：沙箱标识的格式约束；重复创建、不存在、超时各自的表现，以及到接口状态码的翻译表。
- 带 KVM 的机器上正式的验证形态。

## 不在范围内

- 修改 Kata 或 containerd 的代码。
- 快照、模板快速启动、暂停与恢复、运行中改沙箱的规格。
- 出站网络的策略、节点上的数据入口（第二版）。connector 的出站一侧，即上联、GENEVE 网关和出口命名空间，也不在这里试。
- 在开发机上换内核，或者在开发机的宿主上安装 Kata。

## 参考

- Kata 的定位、接口、VMM 与网络：内部的 Kata 研究笔记的 `README.md` 第 2、3 节。
- 内存、规格、cgroup 与记账：同一份笔记的 `mechanisms.md` 第 4、5、8 节。
- 路线的比较与选择 Kata 的理由：[gap-analysis.md](../gap-analysis.md) 第 4.2 节。
- 带 KVM 的机器的要求、PVM 的步骤与风险：内部报告 03（运行时调研）第 6.5、6.7 节。
- 提案里与运行时无关的要求：`modules/node-adapter.md`、接入契约。
- connector 的端口形态、附着与限制：公开仓库 `kuasar-sandbox/connector` 的 `README.md`、`docs/vswitch.md`、`docs/vswitch-operations.md`、`docs/tapfd.md`，读的是 `6b48c8f`。它为什么能配 Kata、有哪些代价，见 [gap-analysis.md](../gap-analysis.md) 第 3.3 节。
