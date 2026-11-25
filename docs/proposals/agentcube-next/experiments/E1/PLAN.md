# E1：这类机器上 Kata 能否在 PVM 上起沙箱（实验计划）

- 机器：E0 用过的那台可丢弃虚拟机，ssh 名 `cpu`。它现在可以作为 PVM 宿主启动，见 `../E0/RECORD.md` 第 7 节。
- 批准：2026-11-25 负责人在 E0 通过之后要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。
- 通过标准（照 [000-5 的说明](../../subtasks/000-5-kata-runtime-spikes.md)）：换上 PVM 的 guest 内核之后 KB-1 通过；QEMU、Dragonball、Cloud Hypervisor 各试一遍；创建、执行、删除重复十次全部成功。
  - KB-1：用 containerd 的命令行工具以 Kata 的运行时起一个容器，执行一条命令；沙箱里的内核版本与宿主不同；记下节点上多出的进程（shim、VMM、文件共享进程）和它们的 cgroup。
- 不在 E1 里做：CubeSandbox（那是 E2，另有计划）；Kind 里的 Kata；适配器；网络；性能测量。E1 里记下的耗时只是观察，不是基准。
- 状态：见 `RECORD.md`。

## 修订记录

| 时间（UTC） | 改动 | 原因 |
|---|---|---|
| 2026-11-25 02:56 | 第一版，写在 E1 的任何一步之前 | — |

## 做法

**照 PVM 项目自己的做法做，用它的脚本。** PVM 项目（`virt-pvm/pvm-context` @ `276edd0c`）发布宿主模块包之前的验证次序是：Firecracker 直接启动 guest，再用 Kata 配 QEMU、Dragonball、Cloud Hypervisor 各起一个容器。它的脚本和钉住的版本都在仓库里。E1 把这个仓库在固定的 commit 上取到虚拟机上，原样运行它的脚本；这样“与 PVM 项目测过的做法一致”这一点不靠转述。它的仓库没有许可证文件，所以脚本不抄进本目录，只记 commit 和路径。

在它的做法之外，E1 加两步自己的检查（KB-1 和十次循环），因为它的冒烟测试每种 VMM 只起一个一次性的容器，用的是一个目录当根文件系统，不经过镜像和快照器。

钉住的版本：

| 项 | 版本 | 钉在哪里 |
|---|---|---|
| PVM 项目的脚本 | `virt-pvm/pvm-context` @ `276edd0cb249ac2ad892e9296f9e566a8db3bd97` | 本计划 |
| Kata | 4.2.0 的静态包，SHA-256 `b828904f…a623a8` | PVM 项目的 `configs/ubuntu-24.04-basic.env` |
| Firecracker | 1.17.0，SHA-256 `06094a11…de558` | 同上。只用于直接启动的检查，不作为 Kata 的 VMM |
| guest 内核的配置 | `virt-pvm/misc` @ `ca464030…` 的 `pvm-guest-6.12.33.config`，SHA-256 `17298e97…6717` | PVM 项目的 `pins/guest-config.env` |
| guest 内核的源码 | `virt-pvm/linux` 分支 `pvm-612` @ `9a5f15e83e894eeb4f8e56dbb146d325d405e754`（2026-11-25 的分支头） | 本计划。PVM 项目没有钉这个 commit |
| containerd、runc | 虚拟机上已有的 2.2.1、1.3.4（Ubuntu 的包） | E0 |

Kata 用的是 4.2.0，不是此前研究读的 4.4.0。先用 PVM 项目测过的版本，是为了把“这台机器行不行”和“新版本行不行”分开。4.2.0 通过之后再决定要不要加测更新的版本，结果分开记。

## 步骤

每一步是 `scripts/` 下的一个脚本，由 `../tools/vmrun.sh` 送到虚拟机上执行；输出进 `log-<步骤>.txt`，执行记录进 `commands-as-run.txt`。

| 步骤 | 脚本 | 做什么 | 停止条件 |
|---|---|---|---|
| 00 | `00-preflight.sh` | 确认在 PVM 宿主上：内核、`nokaslr`、`kvm-pvm`、`/dev/kvm`；记下退路（第 0 项、`next_entry`） | 不在 PVM 宿主上就先按 E0 的做法进入 |
| 01 | `01-prepare.sh` | 装编译用的包；把 PVM 项目的脚本取到 `/build/pvm/context` 并核对 commit | apt 的计划里出现内核包就停 |
| 02 | `02-install-kata.sh` | 下载 Kata 4.2.0，核对校验和，用 PVM 项目的安装脚本装到 `/opt/kata`（它会重启 containerd） | 校验和不对就停 |
| 03 | `03-install-firecracker.sh` | 下载 Firecracker 1.17.0，核对校验和，装到 `/usr/local/bin` | 同上 |
| 04 | `04-guest-kernel.sh` | 取 guest 内核源码并核对 commit；取钉住的配置；用 PVM 项目的脚本编译 `vmlinux` | 编译失败就停，留下编译日志 |
| 05 | `05-configure-kata.sh` | 把 guest 内核放到 Kata 的目录；用 PVM 项目的脚本生成三份配置；列出它相对默认配置改了什么 | — |
| 06 | `06-firecracker-boot.sh` | PVM 项目的直接启动检查：Firecracker 启动 PVM 的 guest 内核和 Kata 的 guest 镜像。**这是这台机器上第一次运行 guest 代码** | 见下面“判断次序” |
| 07 | `07-kata-smoke.sh` | PVM 项目的 Kata 冒烟测试：三种 VMM 各起一个容器 | 同上 |
| 08 | `08-kata-kb1.sh` | KB-1：三种 VMM 各起一个常驻的容器（从镜像），执行命令，记下内核版本、进程和 cgroup，删除 | — |
| 09 | `09-kata-cycles.sh` | 三种 VMM 各做十次创建、执行、删除；每次之后检查有没有残留的进程 | — |
| 10 | `10-state.sh` | 只读：记下虚拟机最后的状态 | — |

02、03 与 04 互不依赖，可以同时做。

## 判断次序

- 06 不通过（guest 内核起不来，或者宿主内核报错）：问题在 PVM 本身，与 Kata 无关。保留 guest 的控制台输出和宿主的内核日志。先看是不是已知的条件没有满足（五级页表、MSR 0x3a、guest 的地址宽度），能用启动参数或配置解决的试一次并记下；不能的话结论是“这台机器上 PVM 跑不起 guest”，Kata 和 CubeSandbox 都不用再试。
- 06 通过、07 里某一种 VMM 不通过：记下是哪一种和它的报错。只要有一种通过，Kata 在这台机器上就是可用的，结论里写明是哪几种。
- 07 全部不通过：按 [000-5 的说明](../../subtasks/000-5-kata-runtime-spikes.md) 的次序，用 CubeSandbox 做对照（E2），把问题定位到 Kata 还是 PVM。
- 任何一步之后宿主的内核日志里出现 `BUG:`、`WARNING:`、`Oops`、`general protection`、`Call Trace`：记为不通过，即使容器跑出了结果。

## 风险与回退

- E1 不重启，不改启动配置。失联的风险比 E0 小。
- 01 会装几十个编译用的包，可能连带升级 libc 一类已装的包。脚本先打印 apt 的计划，内核包被碰到就停。服务不自动重启（`NEEDRESTART_MODE=l`）。
- 02 会重启 containerd，Docker 随之受影响；此时没有容器在运行。
- 宿主内核因为 PVM 出错而挂死：从控制台重启一次，回到 `6.8.0-149`。这一条退路没有实际走过，是从启动配置读出来的，见 `../E0/RECORD.md`。
- 撤销：删掉 `/opt/kata`、`/etc/kata-containers`、`/build/pvm`、`/usr/local/bin/` 下的 `containerd-shim-kata-v2`、`kata-runtime`、`kata-collect-data.sh`、`firecracker`，以及 containerd 里名叫 `e1` 的 namespace；编译用的包可以留着。逐项的清单在做完之后写进 `RECORD.md`。

## 记录

约定见 `../README.md`。E0 的记录被复核出审计链不完整（逐字的命令导出得太早、有的输出没有落盘），所以 E1 换了做法：命令都写成脚本文件，由执行器运行，输出和执行记录由执行器写，不靠事后导出。
