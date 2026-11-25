# E1 操作记录：这类机器上 Kata 能否在 PVM 上起沙箱

- 时间：2026-11-25，02:57 至 03:12（UTC）。
- 机器：E0 用过的那台可丢弃虚拟机，ssh 名 `cpu`。AMD EPYC 9845，没有嵌套虚拟化。
- 计划：`PLAN.md`。批准：负责人 2026-11-25 要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。
- 结果：**通过。Kata 4.2.0 在这台 AMD 的 PVM 宿主上可用，QEMU、Dragonball、Cloud Hypervisor 三种 VMM 都可以。** 范围和保留见第 1 节。

## 1. 结论

| 通过标准 | 观察到的 | 证据 |
|---|---|---|
| 换上 PVM 的 guest 内核之后 KB-1 通过 | 三种 VMM 各从镜像起一个常驻的容器，执行命令成功；沙箱里的内核是 `6.12.33`，宿主是 `6.8.0-139-generic`；宿主上多出的进程和它们的 cgroup 记下了（第 4 节） | `log-08-kata-kb1.txt` |
| QEMU、Dragonball、Cloud Hypervisor 各试一遍 | PVM 项目自己的冒烟测试三种都是 PASS | `log-07-kata-smoke.txt` |
| 创建、执行、删除重复十次全部成功 | 三种各 10/10 | `log-09-kata-cycles.txt` |

在这之前，PVM 项目的直接启动检查（Firecracker 启动 PVM 的 guest 内核）是这台机器上第一次运行 guest 代码：guest 内核起来，约 2 秒后 kata-agent 就绪（`log-06b-firecracker-evidence.txt`）。它回答了 E0 留下的问题：**PVM 在这款 AMD CPU 上跑得起 guest。** guest 的控制台里没有带“PVM”字样的行（它把自己报成 KVM 的 guest）；说它跑在 PVM 上，依据是这台宿主没有硬件虚拟化，`/dev/kvm` 只由 `kvm-pvm` 提供。

这个结论说明的和没有说明的：

- **测的是 PVM 项目测过的那一组版本**：Kata 4.2.0 的静态包（Rust 运行时），QEMU 11.0.1，Cloud Hypervisor v51.1，Dragonball（编在 shim 里），guest 内核是 PVM 项目的 `pvm-612` 分支（6.12.33）加它钉住的配置。此前计划里读的是 Kata 4.4.0，没有测。Firecracker 只用来直接启动，没有作为 Kata 的 VMM 测。
- **经 containerd 的命令行工具，不经 Kubernetes。** 容器没有网络（只有回环）。Kind 里的 Kata、节点适配器、cgroup 记账、网络，都不在 E1 里。
- **一台机器，每种 VMM 十几个沙箱，都是先后创建，没有并发，没有长时间运行。**
- **宿主是 E0 留下的状态**：`6.8.0-139-generic` 加 `nokaslr`，PVM 项目 v0.1 的模块包；PVM 宿主不是这台机器的默认启动状态。
- **换一个 PVM 宿主，这套配置大概就不行。** E4 里用两个 VMM 直接启动这个 guest 内核，在 CubeSandbox 的宿主内核上约 1 秒后复位；没有经 Kata 再试。在那个宿主上，Kata 换用 CubeSandbox 的 guest 内核之后，Dragonball 和 Cloud Hypervisor 起得了沙箱，QEMU 没有起来。见 `../E4/RECORD.md`。

有三件事要一并知道，都不影响“可用”的判断，但影响怎样用：

1. **创建一个沙箱要 6.5 到 8 秒。** guest 启动到 agent 连上只占 1.2 到 2.9 秒。另有一段约 5.03 秒的固定间隔，夹在 shim 的两行日志之间（“收到创建任务”和“打开容器的输入输出”）：QEMU 和 Cloud Hypervisor 各看到一次；Dragonball 的日志在那之前被截断了，只能从它的总时间推出同样的间隔（`log-09b-where-time-goes.txt`）。每种 VMM 只看了一个样本。这段时间花在哪里不知道，可能在 shim 里，也可能在等 guest 或 agent；与 PVM 有没有关系也不知道。这不是性能测量，只是提醒：照这个配置直接用，发放时间是秒级的。
2. **QEMU 的删除有时收尾不干净。** 13 次里有 3 次：containerd 记下 `failed to shutdown shim task and the shim might be leaked`，原因是 `stop vm: qemu process has not been started yet`；shim 进程在删除之后没有立刻退出：十次循环里的两次量到约 25 秒，KB-1 那一次只知道超过 5 秒、不到 44 秒；宿主上留下一个 cgroup 目录和一个共享目录。Dragonball 和 Cloud Hypervisor 各 12 次都没有出现。这里数的是从镜像起、用 `ctr task kill` 删除的沙箱；PVM 项目的冒烟测试用的是一次性的容器，QEMU 在那里没有出过这个问题。报错在 Kata 的 QEMU 驱动的停止路径上，看上去是它自己的时序问题，没有进一步确认。
3. **宿主内核日志里每起一台虚拟机就有一行 `Unhandled WRMSR(0xc0010007)`**，级别是 error。这是 KVM 对没有实现的 MSR 的常规提示（0xc0010007 是 AMD 的一个性能计数器），guest 继续运行。它不在 PVM 项目的测试脚本查的错误特征里，这里也不算错误，但“内核日志里没有 error 级别的行”在这台机器上不成立。E0 测到的 MSR 0x3a 被拒绝写回，在 E1 里没有表现出来：三种 VMM 都是冷启动，没有碰它。

## 2. 环境与版本

| 项 | 版本 | 来源与核对 |
|---|---|---|
| 宿主 | `6.8.0-139-generic`，`nokaslr`，`kvm-pvm` 来自 `updates/pvm-oot/` | E0 |
| PVM 项目的脚本 | `virt-pvm/pvm-context` @ `276edd0cb249ac2ad892e9296f9e566a8db3bd97` | GitHub 的归档包，包里记的 commit 与之相同；归档包 SHA-256 `d75b1dff…05dda7` |
| Kata | 4.2.0 静态包，shim 是 `containerd-shim-kata-v2`（Rust），commit `c7351e79` | Kata 的发布页；SHA-256 `b828904f…a623a8`，与 PVM 项目钉的一致 |
| QEMU、Cloud Hypervisor | 11.0.1、v51.1 | 随 Kata 的静态包 |
| Firecracker | 1.17.0 | 官方发布；SHA-256 `06094a11…de558`，与 PVM 项目钉的一致 |
| guest 内核源码 | `virt-pvm/linux` 分支 `pvm-612` @ `9a5f15e83e894eeb4f8e56dbb146d325d405e754`，版本 6.12.33 | GitHub 的归档包，包里记的 commit 与之相同；SHA-256 `4a35b332…c86928`。PVM 项目没有钉这个 commit |
| guest 内核配置 | `virt-pvm/misc` @ `ca464030…` 的 `pvm-guest-6.12.33.config`，另开 `X86_PIE` 和 `PVM_GUEST` | SHA-256 `17298e97…6717`，由 PVM 项目的脚本核对 |
| 编出的 guest 内核 | `vmlinux.pvm`，308 MB（带调试信息），发行串 `6.12.33` | SHA-256 `95b64099…c9f80c`；16 个任务编译 104 秒 |
| guest 镜像 | Kata 自带的 `kata-ubuntu-resolute.image` | 随 Kata 的静态包 |
| containerd、runc | 2.2.1、1.3.4（Ubuntu 的包） | E0 |
| 测试用的镜像 | `docker.io/library/busybox:1.36`，摘要 `sha256:73aaf090…b11662` | Docker Hub |

完整的校验和在 `log-10-state.txt`。

## 3. 操作是怎样做的

- 每一步是 `scripts/` 下的一个脚本，由 `../tools/vmrun.sh` 复制到虚拟机的 `/root/exp/E1/scripts/` 并以 root 执行。输出追加到 `log-<步骤>.txt`，每次执行在 `commands-as-run.txt` 里记一行：时间、步骤、脚本、脚本的 SHA-256、退出码。
- PVM 项目的脚本不抄进本目录（它的仓库没有许可证文件），只在虚拟机上运行；本目录的脚本写明调用的是它的哪一个。
- **审计上的一处不足**：有三个脚本在执行失败之后改过再执行（见第 5 节）。本目录里只有最后的版本；之前的版本只在 `commands-as-run.txt` 里留有 SHA-256。执行器已经改成每个执行过的版本都留一份（`scripts-as-run/`），对 E1 来不及了。

## 4. 时间线与观察

| 时间 | 步骤 | 做什么 | 结果 |
|---|---|---|---|
| 02:57:31 | 00 | 只读：确认在 PVM 宿主上 | 是；`/dev/kvm` 在；退路（第 0 项、`next_entry`）没有变 |
| 02:57:42 | 01 | 装编译用的包；取 PVM 项目的脚本 | 第一次装好了包，脚本在打印版本号时退出（141）；第二次在统计处退出（1）；第三次通过。见第 5 节 |
| 02:58:43 | 04 | 取 guest 内核源码，核对 commit，用 PVM 项目的脚本编译 | 通过，104 秒 |
| 02:58:43 | 02 | 下载 Kata 4.2.0，核对，用 PVM 项目的脚本安装 | 安装成功；我加的清点在一个不存在的文件上退出（2）。见第 5 节 |
| 02:59:15 | 03 | 下载 Firecracker 1.17.0，核对，安装 | 通过 |
| 02:59:36 | 02b | 只读：清点 Kata 的安装 | 这个版本只有 Rust 运行时；不带 Firecracker |
| 03:01:28 | 05 | 放好 guest 内核；用 PVM 项目的脚本生成三份配置 | 通过。它相对默认配置的改动见下 |
| 03:01:39 | 06 | PVM 项目的直接启动检查 | **guest 起来了；它的脚本报失败。** 见第 5 节 |
| 03:02:57 | 06b | 只读：把保存的 guest 控制台整份记下来，逐条重做它的三项检查 | 第 2、3 项满足；第 1 项是字符串匹配，在这里不适用 |
| 03:03:10 | 07 | PVM 项目的 Kata 冒烟测试 | QEMU、Dragonball、Cloud Hypervisor 都是 PASS |
| 03:03:45 | 08 | KB-1 | 三种都起来、能执行；QEMU 因为 shim 残留被我的检查记为 FAIL |
| 03:04:47 | 08b | 重做一次 QEMU，看 shim 留多久 | 这一次立刻退出 |
| 03:05:19、03:05:41 | 08c、08d | 只读：containerd 对那次残留记了什么 | 见第 1 节第 2 条 |
| 03:06:15 | 09 | 三种 VMM 各十次创建、执行、删除 | 各 10/10 |
| 03:11:07 | 09b | 观察：创建的时间花在哪里 | 见第 1 节第 1 条 |
| 03:12:05 | 10 | 只读：虚拟机的状态 | `log-10-state.txt` |

02 到 04 是同时进行的。E1 没有重启。

**PVM 项目的配置脚本相对 Kata 默认配置改了什么**（`log-05-configure-kata.txt`）：

- 三种都把 guest 内核换成 `vmlinux.pvm`。
- QEMU：机器类型 `q35`，固件 `qboot.rom`，根文件系统设备从 `virtio-pmem` 改成 `virtio-blk-pci`，块设备驱动从 `virtio-scsi` 改成 `virtio-blk-pci`。
- Dragonball：内核参数加 `agent.hotplug_timeout=30 vsyscall=emulate`。
- Cloud Hypervisor：只换内核。
- 生成的配置里没有限制 guest 地址宽度的设置。沙箱里看到的是：QEMU 和 Dragonball 52 位物理地址，Cloud Hypervisor 46 位；都是 57 位虚拟地址。

**KB-1 记下的进程和 cgroup**（`log-08-kata-kb1.txt`）：

| VMM | 宿主上的进程（常驻内存，约） | cgroup |
|---|---|---|
| QEMU | shim（26 MB）、virtiofsd 两个（2 MB、7 MB）、`qemu-system-x86_64`（182 MB） | 都在 `/e1/kb1-qemu` |
| Dragonball | 只有 shim 一个进程（158 MB），VMM 和文件共享都在它里面 | `/e1/kb1-dragonball` |
| Cloud Hypervisor | shim（26 MB）、virtiofsd 两个、`cloud-hypervisor`（144 MB） | 都在 `/e1/kb1-clh` |

cgroup 的路径是“containerd 的 namespace / 容器标识”，在 cgroup v2 的根下。这是没有指定 cgroup 路径时的默认位置，适配器要放进池的父 cgroup 是 KB 系列后面的事。内存数字是空闲的 busybox 沙箱刚起来时的一次读数，guest 配的是 1 个 vCPU、2048 MB。

**十次循环**（`log-09-kata-cycles.txt`；单位毫秒，是观察不是基准）：

| VMM | 通过 | 创建（最小/中位/最大） | 执行 | 删除 | 备注 |
|---|---|---|---|---|---|
| QEMU | 10/10 | 7662 / 7760 / 7797 | 约 85 | 约 80 | 第 2、第 10 次 shim 在删除之后留了约 25 秒 |
| Dragonball | 10/10 | 7968 / 8052 / 8088 | 约 85（两次约 180） | 约 87 | — |
| Cloud Hypervisor | 10/10 | 6413 / 6462 / 6490 | 约 83 | 约 76 | — |

“通过”的定义：容器起来；命令在内核为 `6.12.33` 的沙箱里执行并返回；容器和任务的记录删掉；沙箱的进程在删除之后 60 秒内全部消失。宿主内核日志每一轮只多出那一行 `Unhandled WRMSR`。

## 5. 与计划不一致的地方，和过程中的意外

1. **PVM 项目的直接启动检查报了失败，实际 guest 起来了。** 它的脚本用 `Linux version .*pvm` 去匹配 guest 内核的横幅。这里编出的内核横幅是 `Linux version 6.12.33 (root@localhost)`，配置里 `CONFIG_LOCALVERSION` 是空的，横幅里没有“pvm”这几个字。脚本的另外两项检查（kata-agent 就绪；宿主内核日志没有错误特征）都满足，Firecracker 的退出码 124 是脚本自己设的超时到点。所以这里判为通过，依据是保存下来的 guest 控制台，不是它的退出码。它那边为什么匹配得上，没有查（可能是它的构建机的主机名或用户名里有这几个字）。
2. **KB-1 里 QEMU 被我的检查记成 FAIL。** 那个检查要求删除之后 5 秒内进程全部消失，是我随手定的。之后把问题查清（第 1 节第 2 条），在十次循环里把等待放宽到 60 秒并单独统计 containerd 的报错。按放宽后的定义 QEMU 是通过的；收尾不干净这件事照实记下，没有因为“通过”而略去。
3. **三个脚本执行失败之后改过。**
   - `01-prepare.sh`：`make --version | head -1` 在 `pipefail` 下被 SIGPIPE 打断（141）；改成 `sed -n 1p`。第二次执行时包已经装好，`grep -c` 数到 0 返回 1，脚本又退出；加了 `|| true`，并加了打印 apt 历史的一段。三次的输出都在 `log-01-prepare.txt` 里，包是第一次装的。
   - `02-install-kata.sh`：安装成功之后，我加的清点对一个这个版本没有的文件（`kata-runtime`）执行 `ls`，退出码 2。没有重跑安装，另写了只读的 `02b-kata-inventory.sh`。本目录里的 `02-install-kata.sh` 还带着那一段，重跑会在同一处退出。
   - `09-kata-cycles.sh`：在第一次执行之前改的（加了 60 秒的等待和报错统计），不算执行后修改。
4. **`08c-kb1-qemu-journal.sh` 退出码是 2**：最后一条 `ls` 查的两个目录已经不在了。这正是要看的结果，不是失败。
5. **`01-prepare.sh` 打印的“已装的包里有哪些被升级”是空的。** 这一步新装了 54 个包，没有升级已装的包（libc 没有动）。完整的包名在 `log-01-prepare.txt` 第三次执行打印的 apt 历史里。
6. **计划里说 4.2.0 通过之后再决定要不要加测更新的 Kata 版本。** 没有加测。负责人的问题已经可以回答，时间用在了 CubeSandbox 上（E2、E3）。

## 6. 对虚拟机的改动，和怎样撤销

| 改动 | 位置 | 怎样撤销 |
|---|---|---|
| 编译用的包，54 个 | `build-essential`、`bc`、`bison`、`flex`、`dwarves`、`libelf-dev`、`libssl-dev`、`busybox-static`、`jq`、`pkg-config`、`zstd` 等及其依赖；清单在 `log-01-prepare.txt` | `apt-get purge`；留着也无妨 |
| PVM 项目的脚本、下载的包、内核源码与编译产物 | `/build/pvm/`，5.0 GB | 删除 |
| Kata 4.2.0 | `/opt/kata/`，2.6 GB（含放进去的 `vmlinux.pvm`） | 删除 |
| Kata 的三份 PVM 配置 | `/etc/kata-containers/pvm/` | 删除 |
| 两个链接和一个二进制 | `/usr/local/bin/containerd-shim-kata-v2`（链接）、`/usr/local/bin/firecracker` | 删除 |
| containerd 重启过一次 | 由 PVM 项目的安装脚本做的 | — |
| containerd 里的 namespace `e1` | 一个镜像（busybox:1.36）和它的快照 | `ctr -n e1 image rm docker.io/library/busybox:1.36`；`ctr namespace rm e1` |
| QEMU 收尾留下的三组残留 | `/run/kata-containers/shared/sandboxes/` 和 cgroup `/e1/` 下的 `kb1-qemu`、`cyc-qemu-2`、`cyc-qemu-10` | 在 `/run` 和 cgroup 文件系统里，E2 的重启之后已经没有了 |
| 内核模块 | `vhost_vsock`、`vsock` 等，起虚拟机时自动加载 | 重启即无 |

没有动的：启动配置、网络、E0 留下的保留包。

## 7. 虚拟机的状态

E1 结束时的状态在 `log-10-state.txt`。之后 E2、E3 又改过这台机器，最后的状态看 `../E3/RECORD.md` 第 7 节。E3 收尾时在最后的状态上又跑了一遍 PVM 项目的 Kata 冒烟测试，三种 VMM 仍然是 PASS（`../E3/log-12b-kata-smoke.txt`）。

## 8. 在另一台机器上重做

前提是那台机器已经是 PVM 宿主（`../E0/RECORD.md` 第 8 节）。

```bash
cd experiments        # 这些记录所在的目录
VM_HOST=<ssh 名> tools/vmrun.sh E1 00-preflight 00-preflight.sh
tools/vmrun.sh E1 01-prepare 01-prepare.sh
tools/vmrun.sh E1 02-install-kata 02-install-kata.sh        # 末尾的清点会以 2 退出，见第 5 节第 3 条；接着跑 02b
tools/vmrun.sh E1 02b-kata-inventory 02b-kata-inventory.sh
tools/vmrun.sh E1 03-install-firecracker 03-install-firecracker.sh
tools/vmrun.sh E1 04-guest-kernel 04-guest-kernel.sh          # 可以与 02、03 同时
tools/vmrun.sh E1 05-configure-kata 05-configure-kata.sh
tools/vmrun.sh E1 06-firecracker-boot 06-firecracker-boot.sh  # 退出码 1 不等于失败，接着跑 06b 看证据
tools/vmrun.sh E1 06b-firecracker-evidence 06b-firecracker-evidence.sh
tools/vmrun.sh E1 07-kata-smoke 07-kata-smoke.sh
tools/vmrun.sh E1 08-kata-kb1 08-kata-kb1.sh                  # QEMU 可能因为 5 秒的窗口记成 FAIL，见第 5 节第 2 条
tools/vmrun.sh E1 09-kata-cycles 09-kata-cycles.sh
tools/vmrun.sh E1 10-state 10-state.sh
```

要按情况改的：

- guest 内核的 commit 写在 `04-guest-kernel.sh` 里，是 2026-11-25 那一天的分支头；可以用环境变量 `GUEST_COMMIT` 换。
- 要让 PVM 项目的直接启动检查自己报通过，可以给 guest 内核加一个带“pvm”的本地版本后缀。这里没有这样做，为的是不改它钉住的配置。
- 08、09 的容器在 containerd 的 namespace `e1` 里，用 `NS` 换；VMM 用 `HYPERVISORS` 选。

## 9. 没有验证的

- 更新的 Kata 版本（4.4.0）；Firecracker 作为 Kata 的 VMM。
- 那段约 5 秒的间隔，每种 VMM 只有一个样本；Dragonball 的是推出来的。
- Kubernetes 里的 Kata（CRI、RuntimeClass、Kind 节点里的 containerd）；网络；适配器要用的 cgroup 布局；容量调整。
- 并发创建；长时间运行；带负载的沙箱；内存和 CPU 的超卖。
- 那段约 5 秒的固定间隔花在哪里；QEMU 收尾问题的原因，以及它与 PVM 有没有关系。
- 不加 `nokaslr`、不同的 guest 内核配置。
- 这些结果在 Intel 的机器、别的云、别的 AMD 型号上是否一样。
