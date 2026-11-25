# E0：这类机器上 PVM 的宿主能否起来（实验计划）

- 机器：负责人提供的可丢弃虚拟机，ssh 名 `cpu`。事实与评估见 内部的机器评估记录。
- 批准：2026-11-25 负责人在评估之后选了“现在做 E0”，并确认失联时能从云的控制台重启或重建这台机器。
- 通过标准（照 [000-5 的说明](../../subtasks/000-5-kata-runtime-spikes.md)）：重启后可登录；`/dev/kvm` 存在；内核日志没有 PVM 相关的错误；Docker 和 Kind 仍可用。
- 不在 E0 里做：起任何 microVM（那是 E1）；开发机上的任何改动。
- 状态：已执行，结果见 `RECORD.md`。

## 修订记录

| 时间（UTC） | 改动 | 原因 |
|---|---|---|
| 2026-11-25 02:03 | 第一版 | — |
| 2026-11-25 02:08 | 加阶段 B0；阶段 E 改成“只用一次性的启动项，默认项不动”；去掉固定默认项和开机加载模块；重启前检查 kexec | 子代理的安全评审，见 本子任务的实施提案（内部文档） 第 5 节。读到评审结论之后、第一次重启（02:09）之前定下；实验结束之后才写进本文件 |
| 2026-11-25 02:28 | 加补充探测 F | 阶段 C 里在宿主上读 MSR 0x3a 回答不了已知的问题，见 `RECORD.md` 第 5 节第 11 条。同样是实验结束之后才写进本文件 |

下面是修订之后、实际执行的计划。第一版里被取代的两段原文留在文末；第一版与它的其余差别，以及哪些是评审带来的、哪些不是，见 `RECORD.md` 第 10 节第 13 条。

## 设计上的四点

1. **退路只有一条，全程不能破坏它：从控制台重启一次就回到 `6.8.0-149`。** 所以默认启动项和它的启动参数在 E0 里不改。
2. **先证明一次性的启动项真的只生效一次。** 云的启动加载器要是读了 `next_entry` 却写不回磁盘，一次失败的启动就会变成每次都失败。先拿正在运行的 `6.8.0-149` 当目标试一次（阶段 B0）。
3. **先用 kexec 试新内核，不动启动配置。** 从 `6.8.0-149` 用 kexec 直接切到 `6.8.0-139` 加 `nokaslr`。新内核挂死或网络没起来时，从控制台重启一次就回到 `6.8.0-149`。
4. **kexec 通过之后再做冷启动，用单独的一次性启动项。** 给 `6.8.0-139` 加 `nokaslr` 的启动项单独写在 `/etc/grub.d/40_custom` 里，用 `grub-reboot` 选它。重启必须真的经过启动加载器：重启前确认没有预载的 kexec 内核，并用 `SYSTEMCTL_SKIP_AUTO_KEXEC=1`。

## 步骤

### A 准备（不重启）

1. 停掉自动更新：`systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer`。
2. 装 `6.8.0-139` 的内核、模块、头文件和工具：`linux-image-6.8.0-139-generic`、`linux-modules-6.8.0-139-generic`、`linux-modules-extra-6.8.0-139-generic`、`linux-headers-6.8.0-139-generic`、`rpm2cpio`、`cpio`、`kexec-tools`、`msr-tools`。不卸载 `6.8.0-149`。kexec-tools 不接管关机流程（debconf 的 `load_kexec` 设为 false）。装完确认 GRUB 的第 0 项仍是 `6.8.0-149`，参数没有变。
3. 把两个版本的内核包和内核的元包设为保留（`apt-mark hold`）。
4. 取 PVM 项目 v0.1 的模块包 `ubuntu-24.04-pvm-kmod-6.8.0.139.generic-1.0-1.x86_64.rpm`，核对 SHA-256 为 `c6369b273d0d7db7e7982e94b0e0b637c1e842e8c524c9da83302383ce0b5f05`。用 `rpm2cpio` 解开，把 `kvm.ko` 和 `kvm-pvm.ko` 放到 `/lib/modules/6.8.0-139-generic/updates/pvm-oot/`，运行 `depmod -a 6.8.0-139-generic`。确认 `modinfo -k 6.8.0-139-generic kvm` 指向 `updates/pvm-oot/`，并确认 139 的 initramfs 里没有 kvm 模块。

### B0 证明一次性的启动项会被清掉

1. 确认 `/sys/kernel/kexec_loaded` 是 0。
2. `grub-reboot` 指到 `6.8.0-149` 的菜单项；`SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot`。
3. 起来之后确认：`boot_id` 变了；命令行里有 `BOOT_IMAGE=`；grubenv 里的 `next_entry` 被清掉。
4. 没有被清掉：不做阶段 E，只保留 kexec 的做法。

### B kexec 试启动

1. `kexec -l /boot/vmlinuz-6.8.0-139-generic --initrd=/boot/initrd.img-6.8.0-139-generic --command-line="root=UUID=<根分区> ro console=<原有的串口设置> net.ifnames=0 nokaslr"`。
2. 确认 `/sys/kernel/kexec_loaded` 是 1，`systemctl kexec`。
3. 轮询 ssh，最多等 5 分钟。连不上就停下，请负责人从控制台重启。

### C 在 `6.8.0-139` 上检查

1. `uname -r`、`/proc/cmdline`、网卡与地址。
2. `modprobe kvm-pvm`；`lsmod`；`ls -l /dev/kvm`；内核日志。
3. `modprobe msr`，读 MSR 0x3a，记下读得到还是读不到。
4. 对 `/dev/kvm` 做 ioctl：取 API 版本，建一个空的 VM 和一个 vCPU 再关掉。
5. `kvm-pvm` 加载失败时：留下内核日志，加 `no5lvl` 再用 kexec 试一次。成功的那一条启动参数原样带进阶段 E。

### D Docker 与 Kind

1. 装 `docker.io`，`docker run --rm` 跑一个容器。
2. 装 kind 和 kubectl，`kind create cluster`，节点 Ready 之后删除集群。

### E 冷启动（默认项不动）

1. 备份 `/etc/grub.d/40_custom`、`/etc/default/grub`、`grub.cfg`。把 `grub.cfg` 里生成的 139 菜单项整段复制到 `/etc/grub.d/40_custom`，id 改成 `e0-pvm-139`，`linux` 行末尾加 `nokaslr`。`update-grub`。不改 `/etc/default/grub`。
2. 核对：`grub.cfg` 语法通过；第 0 项的整段与改动之前相同；新启动项的 `linux` 行是阶段 B 成功的那一条参数。
3. `kexec -u`，确认 `/sys/kernel/kexec_loaded` 是 0；`grub-reboot e0-pvm-139`；`SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot`。
4. 轮询 ssh，最多等 5 分钟。连不上就停下，请负责人从控制台重启一次，会回到 `6.8.0-149`。
5. 起来之后确认是 `6.8.0-139`、`next_entry` 被清掉，重做阶段 C 的检查和阶段 D 的 Docker、Kind。
6. 不固定默认项，不做开机加载。

### F 补充探测：vCPU 的 MSR 0x3a

建一个 VM 和一个 vCPU，不运行。看 0x3a 在不在 KVM 报告的 MSR 列表里；读它，再把读到的值写回；用四个别的 MSR 做对照。

## 回退

- A 的各步都可以反过来做：卸掉 `6.8.0-139` 的包，删掉 `updates/pvm-oot/`，重新启用自动更新。
- B0、B、E 的重启失败：从控制台重启一次，回到 `6.8.0-149`。
- 去掉实验用的启动项：把 `/etc/grub.d/40_custom` 换回备份，`update-grub`。
- 逐项的撤销方法见 `RECORD.md` 第 6 节。

## 记录

输出记在本目录的 `log-*.txt`，发出的命令逐字记在 `commands-as-run.txt`，过程和结论写在 `RECORD.md`，结论的摘要写进 本子任务的实施提案（内部文档） 第 3 节。

## 附：第一版里被取代的两段

留作对照。这两段没有执行。

设计的第 2 点：

> **kexec 通过之后再做冷启动，先用一次性的启动项。** `grub-reboot` 只影响下一次启动；冷启动失败时再重启一次也回到 `6.8.0-149`。两次都通过，才把默认项固定到 `6.8.0-139`。

阶段 E：

> ### E 冷启动与固定
>
> 1. 备份 `/etc/default/grub`，给 `GRUB_CMDLINE_LINUX` 加上 `nokaslr`，`update-grub`。默认项不变。
> 2. `grub-reboot` 指到 `6.8.0-139` 的菜单项，`systemctl reboot`。
> 3. 起来之后确认是 `6.8.0-139`，并看 grubenv 里的 `next_entry` 有没有被清掉。
> 4. 把 `GRUB_DEFAULT` 固定到 `6.8.0-139` 的菜单项，写 `/etc/modules-load.d/kvm-pvm.conf` 让 `kvm-pvm` 开机加载，再重启一次确认。
