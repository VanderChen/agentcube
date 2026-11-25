# E3：CubeSandbox 文档里的做法，在它自己的 PVM 宿主内核上（实验计划）

- 机器：同 E0 到 E2。
- 批准：2026-11-25 负责人要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。E2 的计划写明：不换内核的那条路不通过时，换 CubeSandbox 自己的宿主内核要另写计划。这就是那份计划。
- 为什么做：E2 在现在的 PVM 宿主（Ubuntu `6.8.0-139` 加 PVM 项目的模块包）上，CubeSandbox v0.8.0 建模板时 microVM 一启动就 Reset。定位的结果是它自带的 PVM guest 内核（6.6.117）在这台宿主的 PVM 模块上跑不起来，换哪个 VMM 都一样；PVM 项目的 guest 内核在同样的 VMM 上正常（`../E2/log-08c-localize.txt`）。所以 E2 没有回答“CubeSandbox 在这台 AMD 机器上能不能用”，只回答了“它的 guest 内核与 PVM 项目的宿主模块不配套”。CubeSandbox 自己的文档要求的是它自己的宿主内核，E3 照文档做。
- 通过标准：与 `../E2/PLAN.md` 的第 2 到第 6 条相同（模板、从模板建沙箱、执行代码、十次循环、宿主内核日志）。另加一条在前面：换到 CubeSandbox 的宿主内核之后能登录，`modprobe kvm_pvm` 之后有 `/dev/kvm`。
- 状态：见 `RECORD.md`。

## 修订记录

| 时间（UTC） | 改动 | 原因 |
|---|---|---|
| 2026-11-25 03:45 | 第一版，写在 E3 的任何一步之前 | — |

## 钉住的版本

| 项 | 版本 | 来源 |
|---|---|---|
| 宿主内核 | `linux-image-6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e_6.6.117-gbc75224fca7e-1_amd64.deb`，SHA-256 `821f2608…906da6` | CubeSandbox 的发布 `kernel-release-261012-1`（最新的正式内核发布；更新的 `kernel-release-261116-test1` 是预发布，不用） |
| 宿主的启动参数 | `deploy/pvm/grub/host_grub_config.sh` @ `41748bb7`（v0.8.0）里的那一串 | CubeSandbox 的仓库 |
| CubeSandbox | E2 装好的 v0.8.0，不重装 | E2 |

## 与文档做法的两处不同

1. **不运行 `host_grub_config.sh`，不把它的内核设成默认启动项。** 那个脚本改的是全局的启动参数，会连带改掉 `6.8.0-149` 这条退路的参数；文档还要求把新内核设成默认。这两样都会破坏“重启一次就回到能用的内核”。做法与 E0 相同：只加一个单独的启动项 `e3-cube-pvm-host`，把那一串参数原样写进去，用一次性的方式选它。默认启动项仍是 `6.8.0-149`。也不让 `kvm_pvm` 开机加载。
2. **串口控制台保留这台机器原来的设置。** 那一串参数里有 `console=ttyS0,115200 console=tty0`，按它脚本的合并方式最后只剩 `console=tty0`，云的串口控制台上就看不到内核的输出，启动失败时无从判断。这里保留 `console=<原有的串口设置>`。其余参数照抄，包括 `ipv6.disable=1`、`no5lvl`、`pti=off`、`clocksource=tsc tsc=reliable`。

## 步骤

| 步骤 | 脚本 | 做什么 | 停止条件 |
|---|---|---|---|
| 01 | `01-host-kernel.sh` | 下载内核包并对照 GitHub 给出的摘要；`dpkg -i`；确认启动这台机器要用的驱动在内核或 initramfs 里；确认默认启动项仍是 `6.8.0-149`；加启动项 `e3-cube-pvm-host` | 摘要不对；驱动缺；默认项变了：都停 |
| 02 | `02-reboot.sh` | 停掉 CubeSandbox；一次性启动到新的启动项 | 6 分钟连不上：请负责人从控制台重启一次，回到 `6.8.0-149`，E3 到此为止 |
| 03 | `03-after-boot.sh` | 确认内核和参数；`modprobe kvm_pvm`；`/dev/kvm`；挂 XFS | 模块加载失败：留下内核日志，停 |
| 04 | E2 的 `02-firewall.sh`、`01-deadman.sh` | 重启之后防火墙规则和保险都不在了，先补上，再放行 | 防火墙加不上（这个内核上 iptables 不可用）：不启动 CubeSandbox，停 |
| 05 | `05-start-cube.sh` | `touch /run/e2-allow`，启动 Docker 和 CubeSandbox，等它自己的检查通过 | — |
| 06 到 09 | E2 的 `07-status.sh`、`08-pvm-project-test.sh`、`09-quickstart.sh`、`10-cycles.sh` | 与 E2 相同的检查和测试 | 判断次序同 E2 |
| 10 | `10-finish.sh` 等 | 收尾：停掉 CubeSandbox，去掉它那几个容器的自动重启，一次性启动回 E0 的 PVM 宿主（`e0-pvm-139`），确认干净，再去掉 Docker 的闸门 | — |

## 风险与回退

- 新内核起不来或网络没起来：与 E0 相同，从控制台重启一次回到 `6.8.0-149`（E2 里已经实际走过一次），闸门保证 CubeSandbox 和 Docker 不自己启动。
- 这一次没有另请子代理做安全评审。用的是 E0、E2 评审过的两套做法（一次性启动项加固定的默认项；闸门、防火墙、保险）。新的东西只有“一个别家发行版的内核和它的启动参数”。
- 撤销：`dpkg --purge` 那个内核包，从 `/etc/grub.d/40_custom` 里删掉 `e3-cube-pvm-host` 那一段，`update-grub`。
