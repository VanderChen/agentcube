# E4 操作记录：把 E2 的归因弄准——是启动参数，还是宿主与 guest 要配对

- 时间：2026-11-25，04:16 至 04:31（UTC）；04:57 补了两步（清掉一条残留的容器记录、只读的状态补充）。
- 机器：同 E0 到 E3。
- 计划：`PLAN.md`。批准：负责人 2026-11-25 要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。
- 起因：E1 到 E3 的记录交给子代理复核，它指出 E2 的归因有一个没有控制的变量（宿主的启动参数），并缺一个对照。E4 把这两处补上。
- 结果：**E2 与 E3 的差别不能用启动参数解释。测到的是：这两个宿主（内核连同它的 PVM 模块）和这两个 guest 内核只能按原配用，启动参数相同也一样；换过来 guest 就复位。原因没有查。** 另外测到：CubeSandbox 的宿主内核只带 `nokaslr no5lvl` 启动时，同一次启动里 CubeSandbox 和 Kata（换用 CubeSandbox 的 guest 内核，Dragonball 和 Cloud Hypervisor）都起得了沙箱。
- 之后的决定：负责人 2026-11-25 看到结果之后说明不需要 Kata 与 CubeSandbox 并存，以后同一个节点上也只放一种运行时。本记录里“同一个宿主上两者并存”那一部分因此只作记录。
- 这份记录写成之后由一个子代理复核，对照了日志。数字和通过与否都对；它指出几处措辞比证据强、几处把推断写成了测到，已经改进正文，改了什么列在第 10 节。

## 1. 结论

**直接启动的对照。** 不经 CubeSandbox，也不经 Kata，用上游的 Cloud Hypervisor v51.1 和 Firecracker 1.17.0 直接启动两个 guest 内核。前两行是同一个宿主内核换启动参数，后一行是换宿主内核、启动参数不变：

| 宿主内核与 PVM 模块 | 启动参数 | CubeSandbox 的 guest 内核（6.6.117） | PVM 项目的 guest 内核（6.12.33，Kata 在 E1 里用的） | 证据 |
|---|---|---|---|---|
| Ubuntu `6.8.0-139` 加 PVM 项目的模块 | `nokaslr`（五级页表开着） | 两个 VMM 都是一启动就复位（几十毫秒内），控制台没有输出 | 两个 VMM 都启动 | `../E2/log-08c-localize.txt` |
| 同上 | `nokaslr no5lvl`（五级页表关着） | **同样复位**（同样在几十毫秒内） | 同样启动 | `log-04-localize.txt` |
| CubeSandbox 的 `6.6.117` 宿主内核，用它自带的 PVM 模块 | `nokaslr no5lvl` | **两个 VMM 都启动** | **两个 VMM 都复位**（约 1.1 秒后，控制台没有输出） | `log-06-localize-cube-host-min.txt` |

表里的“启动”和“复位”各指什么：

- “启动”指控制台上有 guest 内核的输出。Firecracker 下给了根盘，一直到用户态，Kata 的 agent 就绪。Cloud Hypervisor 下没有给根盘，内核打印一百多行，之后每隔两秒多由 guest 自己发起一次复位（VMM 记的是 `i8042 reset signalled`），反复到 30 秒被结束。抓到的控制台输出在挂载根盘之前就断了，所以“是因为没有根盘”是推断。
- “复位”指 VMM 记下 `VmExit::Reset`（Cloud Hypervisor）或 `Shutdown`（Firecracker），控制台没有内核的输出。
- 两个方向的失败不对称：CubeSandbox 的 guest 内核在 Ubuntu 的宿主上几十毫秒内就复位；PVM 项目的 guest 内核在 CubeSandbox 的宿主上约 1.1 秒后才复位。
- 第一行“五级页表开着”不是那一次的日志里读到的，是同一个启动项的另外几次启动里读到的（16 个 CPU 都带五级页表的标志）。第一行做的时候 CubeSandbox 的服务在运行，后两行没有。

读法：

- 第一行对第二行：在 Ubuntu 的宿主上关掉五级页表，结果不变。所以不是五级页表。
- 第二行对第三行：启动参数一样，换了整个宿主内核（连同它的 PVM 模块），两个 guest 内核的结果正好对调。所以 E2 与 E3 的差别不能用启动参数解释。换掉的是整个宿主：发行版、内核版本（6.8 对 6.6）、PVM 模块是另装的还是内核自带的，全都不同。是 PVM 模块的差别，还是宿主内核别处的差别，这里分不开。
- 第三行同时是 E2 缺的那个对照：这两个 VMM 本来启动得了 CubeSandbox 的 guest 内核。
- 第三行右边一格回答了 E3 留下的问题：Kata 照 E1 的配置（PVM 项目的 guest 内核）在 CubeSandbox 的宿主内核上用不了。这是从直接启动推出来的，没有经 Kata 再试一遍。

**同一个宿主上两者并存。** 在 CubeSandbox 的宿主内核、只带 `nokaslr no5lvl` 的那一次启动里：

| 测的是什么 | 结果 | 证据 |
|---|---|---|
| CubeSandbox v0.8.0：新建模板，从模板建沙箱、执行代码、删除 | 模板 15 秒建成（每 5 秒查一次，没有出现 E3 那次有的 `BUILDING_EXT4` 和 `DISTRIBUTING` 两个阶段；推断是复用了 E3 留下的产物）；十次循环 10/10，创建 90 到 106 毫秒 | `log-10-quickstart.txt`、`log-11-cycles.txt` |
| Kata 4.2.0，guest 内核换成 CubeSandbox 的 `vmlinux-pvm`，KB-1（每种 VMM 一个沙箱，执行一条命令） | Dragonball 通过（创建 9.6 秒），Cloud Hypervisor 通过（7.0 秒）。**QEMU 没有起来**：10 秒内连不上 guest 里的 agent（21 次尝试，`ENODEV`），没有证据显示 guest 启动了 | `log-08-kata-cube-guest-on-cube-host.txt` |
| 同上，在 CubeSandbox 的服务启动之后再做一遍（Dragonball、Cloud Hypervisor）。这时没有 CubeSandbox 的沙箱在跑 | 都通过（创建 9.4 秒、6.9 秒） | `log-12-kata-while-cube-runs.txt` |

这说明的和没有说明的：

- **“只能按原配用”是测到的；为什么没有查。** 两边的来源不同，这是读到的，不是测到的：一边是 PVM 项目的 `pvm-6.6-host-oot` 模块和它的 `pvm-612` guest；另一边是腾讯维护的 OpenCloudOS 内核里的宿主和 guest。每一边只有一个版本，只有一台 AMD 机器，没有 Intel 的对照。所以这不是“两套 PVM 互不兼容”这样的一般结论：换掉的是整个宿主内核，不只是 PVM 模块；两个宿主上 kvm 模块的参数、漏洞缓解的设置也没有逐项对过（Ubuntu 一侧事后补记在 `log-18-state-supplement.txt`，CubeSandbox 一侧没有记）。
- **CubeSandbox 文档要求的那一长串启动参数，对通过这组功能测试不是必需的。** 只带 `nokaslr no5lvl` 时它建了模板、十次循环全部成功。少掉的有 `clocksource=tsc tsc=reliable`、`pti=off`、`mitigations=on`、`retbleed=off`、`clearcpuid=`、`transparent_hugepage=never`、`ipv6.disable=1`、`kvm.nx_huge_pages=never`、`idle=halt` 等。少了之后时钟源是 kvm-clock，并多出一行 TSC 不可靠的内核提示（第 5 节第 7 条）；对时钟、性能、长时间运行有没有影响，没有测。E3 里查 VMM 日志的那一步（`09-evidence.sh`）在 E4 里没有重做。`nokaslr` 不在它文档的参数里，E3 没有带它也通过，所以它对 CubeSandbox 不是必需的；`no5lvl` 两次都带着，是不是必需的没有试。
- **Kata 配 CubeSandbox 的 guest 内核，是没有人写进文档的组合。** 每种 VMM 起了两个沙箱、各执行一条命令，仅此而已；没有做十次循环。QEMU 为什么起不来没有查：QEMU 配 PVM 项目的 guest 内核在这个宿主上也没有试过，所以不能把它读成这个 guest 内核的限制。
- **两者并存只测了一个方向，而且不是同时。** CubeSandbox 的服务启动之后、十次循环做完之后（没有它的沙箱在跑），Kata 的沙箱起得来；那时宿主上只有 Kata 这一台虚拟机。两边的 microVM 同时存在、Kata 的沙箱在跑时再建 CubeSandbox 的沙箱，都没有测。“服务在运行”是从步骤的次序读出来的（第 12 步在启动之后、停掉之前），那一步的日志里没有打印单元的状态。

## 2. 环境与版本

都是 E1 到 E3 已经装好的东西，没有新下载任何软件。

| 项 | 版本 |
|---|---|
| Ubuntu 的宿主 | `6.8.0-139-generic`，PVM 项目 v0.1 的模块包 |
| CubeSandbox 的宿主内核 | `6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e`，自带的 `kvm_pvm` |
| 两个 guest 内核 | CubeSandbox 的 `vmlinux-pvm`（SHA-256 `10c21b61…16e4a0`）；E1 编的 `vmlinux.pvm`（SHA-256 `95b64099…c9f80c`） |
| 直接启动用的 VMM | Kata 4.2.0 自带的 Cloud Hypervisor v51.1；Firecracker 1.17.0 |
| CubeSandbox、Kata、SDK | 同 E2、E3、E1 |

## 3. 操作是怎样做的

与 E1 到 E3 相同。`scripts/` 里有五个是 E4 新写的：`01-entry.sh`、`01b-entry-cube-host.sh`、`03-after-boot.sh`、`03b-after-boot-cube-host.sh`（这四个管启动项和启动之后的核对）和 `07-kata-config-cube-guest.sh`。其余是从 E1 到 E3 复制来的，其中五个改过：`02-reboot.sh`（见第 5 节第 1 条）；`08-kata-kb1.sh`（配置目录可以用 `CONF` 指定）；`09-quickstart.sh` 和 `10-cycles.sh`（工作目录可以用 `W` 指定，为的是新建模板而不动 E3 的）；`12-final.sh`（改掉了那个以 1 退出的结尾）。`09-evidence.sh` 复制来了，没有执行。`17-cleanup-kb1-qemu.sh` 和 `18-state-supplement.sh` 是记录复核之后加的。执行过的每个版本都在 `scripts-as-run/`。

## 4. 时间线

| 时间 | 步骤 | 做什么 | 结果 |
|---|---|---|---|
| 04:16:24 | 01 | 加启动项 `e4-pvm-139-no5lvl`：E0 的启动项加 `no5lvl` | 通过；默认启动项没有变 |
| 04:16:37 | 02 | 一次性启动到它 | **没有重启**，脚本在重启之前退出，见第 5 节第 1 条 |
| 04:17:26 | 02 | 改了脚本再来 | 第 4 次轮询连上 |
| 04:18:41 | 03 | 核对 | `6.8.0-139`，两个参数都在，带五级页表标志的 CPU 是 0 个；`kvm-pvm` 加载成功 |
| 04:18:54 | 04 | 直接启动：两个 guest 内核乘两个 VMM | 第 1 节表的第二行 |
| 04:20:57 | 01b | 加启动项 `e4-cube-host-min`：CubeSandbox 的宿主内核，只带 `nokaslr no5lvl` 和这台机器原有的两个参数 | 通过 |
| 04:21:11 | 05 | 一次性启动到它；核对 | 第 3 次轮询连上；`kvm_pvm` 加载成功；时钟源是 kvm-clock |
| 04:22:22 | 06 | 直接启动：同样的四个组合 | 第 1 节表的第三行 |
| 04:24:25 | 07 | 另生成一套 Kata 的配置，guest 内核指到 CubeSandbox 的 | 配置生成了；脚本末尾打印版本时被 SIGPIPE 打断（141） |
| 04:24:31 | 08 | 用这套配置做 KB-1 | Dragonball、Cloud Hypervisor 通过；QEMU 不通过 |
| 04:25:28 至 04:26:10 | 09 | 挂 XFS；防火墙；保险（40 分钟）；启动 CubeSandbox；从外面探测 7 个端口 | 上保险时脚本告警“闸门没有装”，见第 5 节第 2 条；自检 19 秒后通过；外面只有 22 是通的 |
| 04:26:50 | 09 | 把 Docker 重新放回闸门之下 | 见第 5 节第 2 条 |
| 04:26:57 | 10 | 新建模板，用 SDK 执行代码 | 通过 |
| 04:27:29 | 11 | 十次循环 | 10/10 |
| 04:27:38 | 12 | CubeSandbox 运行着时再做 Kata 的 KB-1（Dragonball、Cloud Hypervisor） | 通过 |
| 04:28:15 | 13 | 停掉 CubeSandbox | 单元全停 |
| 04:28:24 | 14 | 一次性启动回 E0 的 PVM 宿主；核对 | 第 5 次轮询连上；CubeSandbox 和 Docker 都没有自己启动；`eth0` 上没有过滤器；监听的只有 ssh |
| 04:30:09 | 15 | 去掉 Docker 的闸门；Kata 的冒烟测试 | 三种 VMM 都是 PASS |
| 04:30:45 | 16 | 只读：状态；从外面探测 6 个端口 | 只有 22 是通的 |
| 04:57:47 | 17 | 清掉第 08 步里 QEMU 失败时留下的一条 containerd 容器记录 | 清掉了；没有任务、进程、目录残留，见第 5 节第 8 条 |
| 04:57:58、04:58:14 | 18 | 只读：状态的补充；这个宿主上 kvm 模块的参数和漏洞缓解的设置 | 第一次有一行统计的写法错了（那一行没有数出来，退出码仍是 0），改了重做 |

E4 重启三次。

## 5. 与计划不一致的地方，和过程中的意外

1. **第一次“重启”没有发生。** 复制来的 `02-reboot.sh` 在重启之前要确认闸门的文件在，其中包括 Docker 的那一个，而它在 E3 结束时已经去掉了。脚本在这里退出（2），一次性启动项已经设好但机器没有重启；紧接着的等待和核对因此是在原来那次启动上做的，核对如实报了“`no5lvl` 不在”。我的处理是把 Docker 那一项检查从脚本里去掉，然后重来。`log-02-reboot-no5lvl.txt` 和 `log-03-after-boot.txt` 里各有两次执行。这次退出其实是下一条那件事的第一个信号，我当时没有往下想。
2. **有 72 秒，保险的退路是不完整的。** E3 结束时去掉了 Docker 的闸门。E4 里启动 CubeSandbox 之后，它的几个容器带着自动重启的策略；这时如果保险触发、机器重启，Docker 会自己启动并把这些容器带起来，而防火墙规则已经随重启消失。04:25:45 启动，04:26:57 Docker 重新回到闸门之下。这期间保险没有触发，ssh 一直通。事先有两个信号，我都没有停下来处理：04:16:43 `02-reboot.sh` 因为找不到 Docker 的闸门文件而退出（上一条）；04:25:40 上保险时脚本打印了“闸门没有装”的告警，那是启动之前 5 秒。后果是按容器的重启策略推出来的，没有试：E2、E3 的状态记录里这些容器是 `unless-stopped`，其中两个发布着 12088 和 9000 端口。**重做时：启动 CubeSandbox 之前，Docker 必须在闸门之下。**
3. **计划里“不能的话，换成整串参数再试”这一步没有做。** 第二行的结果出来之后，换了一个更能说明问题的做法：让 CubeSandbox 的宿主内核带最少的参数启动。它一步回答了“是参数还是内核”，并且同时是缺的那个对照。CubeSandbox 的整串参数配 Ubuntu 的内核没有试；那串参数里的 `clearcpuid=` 是按它自己内核的特性编号写的，放到别的内核上含义不同。
4. **计划的第 05 步（Kata 的冒烟测试，在带 `no5lvl` 的 Ubuntu 宿主上）没有单独做。** 第 04 步里 PVM 项目的 guest 内核在那个宿主上直接启动成功，用 Firecracker 一直到 agent 就绪；经 Kata 的那一遍省了。所以“Kata 在带 `no5lvl` 的 Ubuntu 宿主上可用”是推出来的。
5. **`07-kata-config-cube-guest.sh` 的退出码是 141**，配置已经生成；是末尾一条 `strings | grep -m1` 的管道被 SIGPIPE 打断。与 E1 里犯过的是同一种错。
6. **Kata 的 KB-1 脚本退出码是 1**，因为 QEMU 不通过。另两种通过。
7. 在 CubeSandbox 的宿主内核、最少参数的那一次启动里，起沙箱时宿主内核日志有一行 `kvm: SMP vm created on host with unstable TSC; guest TSC will not be reliable`。带文档的整串参数（其中有 `clocksource=tsc tsc=reliable`）时没有这一行。对沙箱的影响没有评估。
8. **失败的那次 QEMU 在 containerd 里留下一条容器记录**（命名空间 `e1` 里的 `kb1-qemu`；脚本当时打印了 `container record left`）。写这份记录时漏了，复核指出。它没有任务、没有进程，但以后再用 QEMU 做 KB-1 会因为重名失败。04:57 清掉，前后的情况在 `log-17-cleanup-kb1-qemu.txt`。
9. **计划之外的步骤当时没有先记进计划。** 01b、05、06（让 CubeSandbox 的宿主内核带最少的参数启动）和 07、08、12（Kata 配 CubeSandbox 的 guest 内核）都不在第一版计划里。`PLAN.md` 的修订记录是复核指出之后补的。

## 6. 对虚拟机的改动，和怎样撤销

| 改动 | 位置 | 怎样撤销 |
|---|---|---|
| 两个一次性启动项 | `/etc/grub.d/40_custom` 末尾的 `e4-pvm-139-no5lvl`、`e4-cube-host-min`；改动之前的文件在 `/root/exp/E4/40_custom.before` | 删掉这两段，`update-grub` |
| Kata 的第二套配置 | `/etc/kata-containers/pvm-cube-guest/`（三个文件）。E1 的那一套没有动 | 删除 |
| CubeSandbox 的第二个模板 | `tpl-69c110adf67d44d48286e26e`，在 `/data/cubelet` 里 | 随 CubeSandbox 卸载 |
| 工作目录 | `/root/e2/quickstart-e4/`、`/root/exp/E4/` | 删除 |
| Docker 的闸门 | 中途装回，结束时又去掉了 | — |
| containerd 里的容器记录 `kb1-qemu` | 命名空间 `e1`；第 08 步失败时留下 | 04:57 已清掉 |

防火墙规则、保险的定时器、CubeSandbox 在网络上的改动，都随最后一次重启消失了（`log-16-state.txt`）。保险没有触发过。

## 7. 虚拟机的状态

与 `../E3/RECORD.md` 第 7 节写的相同，那一节已经按 E4 之后的情况更新：正在运行的是 Ubuntu 的 PVM 宿主（`e0-pvm-139`），Kata 可用，三种 VMM 的冒烟测试在最后的状态上又通过了一遍；CubeSandbox 装着、不在运行、受闸门约束；对外只有 ssh。多出来的是上表里的两个启动项和一套 Kata 配置。04:31 的只读记录在 `log-16-state.txt`，04:58 的补充在 `log-18-state-supplement.txt`。

## 8. 在另一台机器上重做

前提：E1、E2、E3 做过（两个宿主内核、Kata、CubeSandbox 都装着）。直接启动的对照是最省事的一段，每个宿主上一两分钟：

```bash
tools/vmrun.sh E4 01-entry 01-entry.sh ID=e4-pvm-139-no5lvl EXTRA=no5lvl
tools/vmrun.sh E4 02-reboot 02-reboot.sh ENTRY=e4-pvm-139-no5lvl && tools/vmwait.sh E4 02-reboot
tools/vmrun.sh E4 03-after-boot 03-after-boot.sh
tools/vmrun.sh E4 04-localize 08c-localize.sh

tools/vmrun.sh E4 01b-entry-cube-host 01b-entry-cube-host.sh ID=e4-cube-host-min "PARAMS=console=<原有的串口设置> net.ifnames=0 nokaslr no5lvl"
tools/vmrun.sh E4 05-reboot 02-reboot.sh ENTRY=e4-cube-host-min && tools/vmwait.sh E4 05-reboot
tools/vmrun.sh E4 05-after-boot 03b-after-boot-cube-host.sh
tools/vmrun.sh E4 06-localize 08c-localize.sh
```

`PARAMS` 里前两项是这台机器原有的启动参数，换机器要换。之后要在同一次启动里用 CubeSandbox，照 `../E3/RECORD.md` 第 7 节“进入 CubeSandbox 可用的状态”那一段做：Docker 放回闸门之下、挂 XFS、防火墙、保险、启动；用完照它的“退出”那一段收尾。

## 9. 没有验证的

- 为什么只能按原配用；是 PVM 模块的差别还是宿主内核别处的差别；在 Intel 的机器上是不是也这样；换别的版本是不是也这样。
- Kata 配 CubeSandbox 的 guest 内核：QEMU 为什么起不来；十次循环；网络；这个组合有没有别的问题。它不是任何一方支持的用法。
- Kata 照 E1 的配置（PVM 项目的 guest 内核）经 Kata 在 CubeSandbox 的宿主内核上：只做了直接启动。
- CubeSandbox 本身在带 `no5lvl` 的 Ubuntu 宿主上：只直接启动了它的 guest 内核。
- CubeSandbox 的整串启动参数配 Ubuntu 的内核。
- `no5lvl` 在 CubeSandbox 的宿主内核上是不是必需的；少掉的那些启动参数对时钟、性能、长时间运行的影响。
- 两种运行时的 microVM 同时存在；同时带负载。负责人 2026-11-25 说明不需要两者并存，这两项和上面“Kata 配 CubeSandbox 的 guest 内核”的各项都不再补。

## 10. 复核之后的更正

这份记录写成之后由一个子代理对照日志复核（发现和处置的全文在 本子任务的实施提案（内部文档） 第 5.5 节）。没有高级别的发现；结论表里的数字和通过与否都对。改了的：

1. “PVM 的宿主和 guest 要出自同一套实现”说得比证据强，改成“这两个宿主和这两个 guest 内核只能按原配用”，并写明换掉的是整个宿主内核、每边只有一个版本。
2. “不是启动参数造成的”改成“E2 与 E3 的差别不能用启动参数解释”：在 Ubuntu 的宿主上只加过 `no5lvl`，文档的整串参数没有试。
3. 写明哪几格是从直接启动推出来的，不是经 Kata 或 CubeSandbox 测到的。
4. “那一长串启动参数不是必需的”加上了范围：只对这组功能测试而言。
5. 保险的那段空档从“约一分钟”改成 72 秒，补上了事先的两个信号。
6. “启动”“复位”各指什么、QEMU 那一格的日志原文、并存只测了一个方向，都写明了。
7. 补记：残留的容器记录（已清掉）、Kata 在这个宿主上的创建时间、探测的端口数、计划之外的步骤。
