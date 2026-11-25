# E0 操作记录：这类机器上 PVM 的宿主能否起来

- 时间：2026-11-25，02:02 至 02:28（UTC）。之前 01:50 至 01:55 的只读评估记在 内部的机器评估记录，那一段的命令在 内部的机器评估记录。
- 机器：负责人提供的可丢弃虚拟机，ssh 名 `cpu`。
- 计划：`PLAN.md`。批准：负责人 2026-11-25 选了“现在做 E0”，并确认失联时能从云的控制台重启或重建。
- 结果：**四条通过标准都满足。** 结论的范围见第 1 节，没有验证的见第 9 节。
- 这份记录在写成之后由一个子代理做过独立复核，发现 1 条高、6 条中、10 条低，都不改变结果，主要是审计链不完整。更正列在第 10 节；最容易误导的几处在正文里就地改了。

本文件给两种读者用：审计的人看第 3 到 7 节（做了什么、改了什么、证据在哪）；以后要在另一台机器上重做的人看第 8 节。

## 1. 结论

| 通过标准（[000-5 的说明](../../subtasks/000-5-kata-runtime-spikes.md)） | 观察到的 | 证据 |
|---|---|---|
| 重启后可登录 | 两种方式进入 `6.8.0-139-generic` 加 `nokaslr` 之后都能登录：kexec 一次，经云的启动加载器冷启动一次 | `log-B-kexec.txt`；`log-E-cold-boot.txt` 的 E2、E3 |
| `/dev/kvm` 存在 | `modprobe kvm-pvm` 返回 0 之后出现 `/dev/kvm`（`crw-rw---- root kvm 10,232`）。两次启动各做一次 | `log-C-pvm-host.txt`；`log-E-cold-boot.txt` 的 E3 |
| 内核日志没有 PVM 相关的错误 | 加载模块之后内核日志只多出两行：树外模块、没有签名，内核被标记为 tainted（12288）。冷启动那一次，error 及以上级别的内核日志是空的 | `log-C-pvm-host.txt`；`log-E-cold-boot.txt` 的 E3 到 E5；`kernel-log-E-cold-boot.txt` |
| Docker 和 Kind 仍可用 | `kvm-pvm` 已加载的情况下：`docker run` 成功；Kind 集群建成，节点 Ready，系统 Pod 全部 Ready，一个 Pod 运行到 Succeeded | `log-D-docker-kind.txt`；`log-E-cold-boot.txt` 的 E3、E5 |

这个结论说明的和没有说明的：

- **只到宿主一侧。** 做到的是：模块能加载，`/dev/kvm` 出现，能用 ioctl 建出 VM 对象和 vCPU 对象。没有运行过任何 guest 代码。PVM 在这款 CPU 上能不能真的跑起一台 microVM，是 E1 要回答的。
- **一台机器，每种启动方式各一次。** 没有重复，没有长时间运行。
- **“仍可用”不是前后对比。** 这台机器原先没有装 Docker 和 Kind，换内核之前没有测过。测到的是它们在 PVM 宿主上可用。
- **PVM 宿主不是这台机器的默认状态。** 默认启动项仍是 `6.8.0-149-generic`，`kvm-pvm` 不会开机自动加载。重启或断电重开之后回到没有 `/dev/kvm` 的状态（在 E0 里这一条是从启动配置读出来的，没有实际走过；E2 里走了一遍，见第 10 节第 6 条）。这是有意的，理由见第 5 节第 1 条。

顺带得到的三个事实，对后面的实验有用：

- 这台机器开着五级页表（`la57`），不加 `no5lvl` 模块也能加载。
- **`kvm-pvm` 在这台宿主上拒绝给 vCPU 写回 MSR 0x3a，与已知问题的描述一致。** 已知的问题是：`kvm-pvm` 在非 Intel 的宿主上拒绝给 vCPU 写回 MSR 0x3a，CubeSandbox 因此在这类机器上创建失败过。不起 guest、只用 ioctl 探测的结果：这个 MSR 读得到，值是 0；把读到的值写回去被拒绝；它不在 KVM 报告的 MSR 列表里。四个对照的 MSR 写回都被接受。所以，凡是会给 vCPU 写这个 MSR 的 VMM（比如恢复快照时把保存下来的 MSR 全部写回，而保存的清单里有它），在这里要能跳过被拒绝的那一个。Kata 的三种 VMM 启动时碰不碰这个 MSR，没有验证，留给 E1；做内存快照恢复的路线（第四版，或者内置节点栈）要把它当作已知条件。另外，在宿主上用 `rdmsr` 读这个 MSR 得到的是“cannot read MSR”，这是宿主一侧的事，与上面的问题不是一回事。
- 云的启动加载器会读取并清掉 grubenv 里的一次性启动项 `next_entry`。所以可以用 `grub-reboot` 做“只试一次，失败了重启就回到原内核”的启动。

## 2. 环境

| 项 | 值 |
|---|---|
| 机器 | 云上的 KVM 虚拟机，BIOS 启动，启动加载器在云的一侧，读机器里的 `/boot/grub/grub.cfg` |
| 系统 | Ubuntu 24.04.5 |
| CPU、内存、磁盘 | AMD EPYC 9845，16 个 vCPU；31 GiB；系统盘 ext4，约 320 GB |
| 虚拟化 | 没有 `svm` 标志，没有嵌套虚拟化，实验之前没有 `/dev/kvm` |
| 实验之前的内核与启动参数 | `6.8.0-149-generic`；`root=UUID=<uuid> ro console=<原有的串口设置> net.ifnames=0` |
| PVM 宿主的内核与启动参数 | `6.8.0-139-generic`；同上，末尾加 `nokaslr` |

用到的软件和来源：

| 软件 | 版本 | 来源 | 核对 |
|---|---|---|---|
| 内核包 `linux-image`、`linux-modules`、`linux-modules-extra`、`linux-headers` | `6.8.0-139.139` | Ubuntu 的软件源（apt） | apt 自己的签名校验 |
| PVM 模块包 | `ubuntu-24.04-pvm-kmod-6.8.0.139.generic-1.0-1.x86_64.rpm`，PVM 项目 v0.1 | `https://github.com/virt-pvm/pvm-context/releases/download/v0.1/` | SHA-256 `c6369b27…0b5f05`，与发布页的 `SHA256SUMS` 一致。在虚拟机上下载之后又核对了一次 |
| `kvm.ko`（装上的） | — | 模块包 | SHA-256 `5cda39fa…5e643a` |
| `kvm-pvm.ko`（装上的） | — | 模块包 | SHA-256 `07245afc…01f870` |
| Docker、containerd、runc | 29.1.3、2.2.1、1.3.4 | Ubuntu 的软件源 | apt |
| kind | v0.33.0 | `https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64` | 下载时没有核对；事后算出 SHA-256 `aee61515…d8e0d`，与官方发布的一致 |
| kubectl | v1.37.2 | `https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl` | 同上，`c0448752…5f8f4`，与官方发布的一致 |
| Kind 的节点镜像 | Kubernetes v1.37.0，节点里的 containerd 2.3.4 | kind v0.33.0 的默认镜像 | — |
| kexec-tools、msr-tools、rpm2cpio | 2.0.28、1.3、4.18.2 | Ubuntu 的软件源 | apt |

校验和的完整值在 `state-after-E0.txt`。

## 3. 操作是怎样做的，证据放在哪

- 全部操作由计划作者（编码代理）从开发机发起，形式是 `ssh cpu '<命令>'`，以 root 执行，非交互。
- 阶段 A 到 F 的输出用 `tee` 写进本目录的 `log-*.txt`。每段开头有一行 `#` 标题，带 UTC 时间。有五条只读命令的输出当时只在屏幕上看过，没有落盘，见第 10 节第 2 条。
- 发出的命令逐字保存在 `commands-as-run.txt`，取自编码代理的会话日志，不是事后回忆。第一次导出得太早，漏了之后的四条；复核之后重新导出，见第 10 节第 1 条。补充探测 F 的脚本另存为 `scripts/F-msr-probe.py`。
- 第 4 节里列的命令去掉了打印标题和截断输出的部分，便于阅读和复用；要核对原文时看 `commands-as-run.txt`。

本目录的文件：

| 文件 | 内容 |
|---|---|
| `PLAN.md` | 实验计划，含安全评审之后的修订和被取代的第一版 |
| `RECORD.md` | 本文件 |
| `commands-as-run.txt` | 动过虚拟机的每一条命令，逐字 |
| `log-A-prepare.txt` | 阶段 A：停自动更新、装内核、装 PVM 模块 |
| `log-B0-oneshot-proof.txt` | 阶段 B0：证明一次性启动项会被清掉 |
| `log-B-kexec.txt` | 阶段 B：kexec 进入 PVM 宿主 |
| `log-C-pvm-host.txt` | 阶段 C：加载模块、`/dev/kvm`、MSR、ioctl |
| `log-D-docker-kind.txt` | 阶段 D：Docker 与 Kind |
| `log-E-cold-boot.txt` | 阶段 E：加启动项、冷启动、冷启动之后重做 C 和 D |
| `log-F-msr-probe.txt` | 补充探测 F：vCPU 的 MSR 0x3a 能不能读、能不能写回 |
| `kernel-log-E-cold-boot.txt` | 冷启动那一次的完整内核日志（`dmesg`） |
| `state-after-E0.txt` | 实验结束时虚拟机的状态，只读查询得到 |
| `scripts/F-msr-probe.py` | 补充探测 F 的脚本，从逐字的命令里取出来的 |
| `scripts/G-postcheck.sh`、`log-G-postcheck.txt` | 复核之后补的只读核对（04:01），把当时没有落盘的几项重新读了一遍 |

对证据做过的改动只有一处：`log-B0-oneshot-proof.txt` 和 `log-C-pvm-host.txt` 里各有一行 `eth0` 的地址，事后换成了“已隐去”。这台机器的地址不记进任何文档。

## 4. 时间线与每一步

时间是 UTC，取命令发出的时刻。“改动”指改了虚拟机上持久的状态。

| 时间 | 步骤 | 做了什么 | 改动 | 重启 | 结果 |
|---|---|---|---|---|---|
| 02:02:27 | 准备 | 只读：grub.cfg 怎样处理 `next_entry`、kexec 的内核配置、根分区的 UUID | 否 | 否 | 可行 |
| 02:04:04 | 评审 | 请一个子代理评审“换内核会不会失联”。同时开始阶段 A（不重启） | — | — | 02:08:22 评审结束，读到结论，计划据此修订 |
| 02:04:04 | A1 | 停掉自动更新的三个单元 | 是 | 否 | 成功 |
| 02:04:04 | A2、A3 | 装内核和工具；保留内核包 | — | 否 | **失败**，dpkg 锁被占，见第 5 节第 3 条 |
| 02:04:22 | — | 只读：查看占锁的进程 | 否 | 否 | 已经结束 |
| 02:04:37 | A2、A3 | 重试 | 是 | 否 | 成功 |
| 02:05:31 | A4 | 下载、核对、安装 PVM 模块，`depmod` | 是 | 否 | 成功 |
| 02:09:12 | B0 | `grub-reboot` 指到 `6.8.0-149` 的菜单项，经启动加载器重启 | 否 | **冷启动** | 回到 149；`next_entry` 被清掉 |
| 02:10:36 | B | kexec 进入 `6.8.0-139` 加 `nokaslr` | 否 | **kexec** | 第一次轮询就连上 |
| 02:11:12 | C1、C2 | 核对内核与参数；`modprobe kvm-pvm` | 否 | 否 | `/dev/kvm` 出现 |
| 02:11:37 | C3、C4 | KASLR 是否关掉；读 MSR 0x3a；KVM ioctl | 否 | 否 | 见下 |
| 02:11:53 | D1 | 装 Docker，运行容器 | 是 | 否 | 成功 |
| 02:12:17 | D2 | 装 kind、kubectl；建集群、跑 Pod、删集群 | 是 | 否 | 成功 |
| 02:13:30 | E1 | 在 `/etc/grub.d/40_custom` 加一个只供实验用的启动项，`update-grub` | 是 | 否 | 默认项没有变 |
| 02:13:42 | E2 | `grub-reboot e0-pvm-139`，经启动加载器重启 | 否 | **冷启动** | 第六次轮询连上；系统的启动时间是 02:14:53 |
| 02:15:24 | E3 | 冷启动之后重做 C 的检查和 `docker run` | 否 | 否 | 成功 |
| 02:18:14 | E4 | 冷启动之后重做 Kind | 否 | 否 | 集群和 Pod 成功；“系统 Pod”那一项的命令写错，没有结论，见第 5 节第 7 条 |
| 02:21:17 | E5 | 用改正的检查再做一次 Kind | 否 | 否 | 成功 |
| 02:22:06 | 收尾 | 只读：记录虚拟机的状态；核对 kind、kubectl 的校验和 | 否 | 否 | `state-after-E0.txt` |
| 02:22:28 | 收尾 | 只读：核对模块包里的 manifest | 否 | 否 | 见第 5 节第 9 条 |
| 02:23:15 | 收尾 | 保存内核日志（`dmesg`），覆盖了 02:18:14 存的那一份，所以文件里有 E5 之后的行 | 否 | 否 | `kernel-log-E-cold-boot.txt` |
| 02:24:07 | 收尾 | 只读：apt 历史、dpkg 日志、debconf、kube 配置、登录记录 | 否 | 否 | 输出当时没有落盘 |
| 02:24:35 | 收尾 | 只读：systemd 日志里 02:04 前后发生了什么 | 否 | 否 | 输出当时没有落盘；见第 5 节第 3 条 |
| 02:28:04 | F | 补充探测：对一个 vCPU 读、写 MSR 0x3a 和四个对照的 MSR，不运行 guest | 否 | 否 | 读得到，写回被拒绝，见第 5 节第 11 条 |

一共重启三次：一次冷启动回到 149（B0），一次 kexec 到 139（B），一次冷启动到 139（E2）。

### A 准备（不重启）

A1 停掉自动更新，免得实验中途内核被升级：

```bash
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
```

A2 装 `6.8.0-139` 的内核和工具。`6.8.0-149` 不卸载。先告诉 kexec-tools 不要接管关机流程：

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
echo "kexec-tools kexec-tools/load_kexec boolean false" | debconf-set-selections
apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends \
  linux-image-6.8.0-139-generic linux-modules-6.8.0-139-generic \
  linux-modules-extra-6.8.0-139-generic linux-headers-6.8.0-139-generic \
  rpm2cpio cpio kexec-tools msr-tools
```

A3 保留两个版本的内核包和元包，免得被升级或自动清理：

```bash
apt-mark hold linux-image-6.8.0-139-generic linux-modules-6.8.0-139-generic \
  linux-modules-extra-6.8.0-139-generic linux-headers-6.8.0-139-generic \
  linux-image-6.8.0-149-generic linux-modules-6.8.0-149-generic \
  linux-modules-extra-6.8.0-149-generic linux-image-generic linux-headers-generic
```

装完之后核对默认启动项没有变。旧内核装进来，`update-grub` 按版本排序，`6.8.0-149` 仍在第 0 项：

```bash
awk '/^menuentry /{n++} n==1 && /^[[:space:]]*linux[[:space:]]/{print; exit}' /boot/grub/grub.cfg
grep -E '^GRUB_DEFAULT' /etc/default/grub
```

观察到：第 0 项的 `linux` 行是 `vmlinuz-6.8.0-149-generic … net.ifnames=0`，`GRUB_DEFAULT=0`。`/boot/vmlinuz` 这个符号链接改指向了 139，见第 5 节第 4 条。

A4 取 PVM 模块包，核对，装到 `updates/pvm-oot/`：

```bash
mkdir -p /root/e0 && cd /root/e0
curl -fsSL -o pvm-kmod.rpm https://github.com/virt-pvm/pvm-context/releases/download/v0.1/ubuntu-24.04-pvm-kmod-6.8.0.139.generic-1.0-1.x86_64.rpm
echo "c6369b273d0d7db7e7982e94b0e0b637c1e842e8c524c9da83302383ce0b5f05  pvm-kmod.rpm" | sha256sum -c -
rm -rf x && mkdir x && cd x && rpm2cpio ../pvm-kmod.rpm | cpio -idm --quiet
install -d -m 0755 /lib/modules/6.8.0-139-generic/updates/pvm-oot
install -m 0644 lib/modules/6.8.0-139-generic/updates/pvm-oot/kvm.ko \
  lib/modules/6.8.0-139-generic/updates/pvm-oot/kvm-pvm.ko \
  /lib/modules/6.8.0-139-generic/updates/pvm-oot/
depmod -a 6.8.0-139-generic
modinfo -k 6.8.0-139-generic -F filename kvm kvm-pvm
lsinitramfs /boot/initrd.img-6.8.0-139-generic | grep -c -E '/kvm(-pvm|-amd|-intel)?\.ko'
```

观察到：校验和 OK；`modinfo` 给出的 `kvm` 和 `kvm-pvm` 都在 `updates/pvm-oot/` 下，即 PVM 的 `kvm.ko` 盖过了发行版自带的；`vermagic` 是 `6.8.0-139-generic SMP preempt mod_unload modversions`；139 的 initramfs 里没有任何 kvm 模块（计数 0），所以开机时不会先加载别的 kvm。

### B0 证明一次性启动项会被清掉（目标是无害的 149）

为什么先做这一步：如果云的启动加载器读了 `next_entry` 却写不回磁盘，那么指到 139 的一次性启动一旦挂死，之后每次重启都还进 139，退路就没有了。所以先用现在就在跑的 149 做目标，试一次。

```bash
cat /sys/kernel/kexec_loaded                       # 必须是 0
grub-reboot "gnulinux-advanced-<uuid>>gnulinux-6.8.0-149-generic-advanced-<uuid>"
grub-editenv /boot/grub/grubenv list               # next_entry=…149…
sync
SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot
```

重启之后：

```bash
uname -r; cat /proc/cmdline; cat /proc/sys/kernel/random/boot_id
grub-editenv /boot/grub/grubenv list
```

观察到：`boot_id` 变了（确实重启过）；命令行里有 `BOOT_IMAGE=`（确实经过启动加载器）；grubenv 里是 `next_entry=`，值为空。启动加载器读到并清掉了它。

### B kexec 进入 PVM 宿主（不动启动配置）

```bash
kexec -l /boot/vmlinuz-6.8.0-139-generic --initrd=/boot/initrd.img-6.8.0-139-generic \
  --command-line="root=UUID=<uuid> ro console=<原有的串口设置> net.ifnames=0 nokaslr"
cat /sys/kernel/kexec_loaded                       # 1
sync
systemctl kexec
```

开发机一侧每 8 秒试一次 ssh，最多 5 分钟。观察到：第一次就连上，`uname -r` 是 `6.8.0-139-generic`。

### C 在 PVM 宿主上检查

```bash
uname -r; cat /proc/cmdline
lsmod | grep -E '^kvm' || echo none; ls -la /dev/kvm     # 加载之前：没有
modprobe kvm-pvm; echo "exit=$?"
lsmod | grep -E '^kvm'; ls -la /dev/kvm
dmesg | tail -n 20; cat /proc/sys/kernel/tainted
grep -w -E '_text|_stext' /proc/kallsyms                 # KASLR 关掉时是 ffffffff81000000
modprobe msr; rdmsr -p 0 0x3a
```

再用一小段 Python 对 `/dev/kvm` 做 ioctl：取 API 版本、查几项能力、建一个 VM、建一个 vCPU、关掉。脚本原文在 `commands-as-run.txt` 的 02:11:37 一条。

观察到：

- 加载之前没有 kvm 模块，没有 `/dev/kvm`。`modprobe kvm-pvm` 返回 0，之后 `kvm_pvm`、`kvm` 都在，`/dev/kvm` 出现。
- 内核日志多出两行：`kvm: loading out-of-tree module taints kernel.` 和 `kvm: module verification failed: signature and/or required key missing - tainting kernel`。`tainted` 是 12288。
- `_text` 在 `ffffffff81000000`，是没有随机化的地址。内核日志里有一行 `Unknown kernel command line parameters "nokaslr"`：这个参数由解压阶段处理，主内核不认识它，这一行不表示它没有生效。
- `rdmsr` 输出 `CPU 0 cannot read MSR 0x0000003a`。
- KVM 的 API 版本 12；`KVM_CREATE_VM` 和 `KVM_CREATE_VCPU` 都返回了文件描述符；`NR_VCPUS` 是 16，`MAX_VCPUS` 是 1024。之后内核日志没有新的行。
- 计划里的 C5（加载失败时加 `no5lvl` 再试）没有用上。

### D Docker 与 Kind

```bash
apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends docker.io
docker run --rm busybox:latest sh -c "uname -r; echo container-ok"
docker run --rm --device /dev/kvm busybox:latest sh -c "ls -l /dev/kvm"
curl -fsSL -o /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 && chmod +x /usr/local/bin/kind
KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/$KV/bin/linux/amd64/kubectl && chmod +x /usr/local/bin/kubectl
kind create cluster --name e0 --wait 180s
kubectl --context kind-e0 get nodes -o wide
kubectl --context kind-e0 run e0-probe --image=busybox:latest --restart=Never --command -- sh -c "uname -r; echo pod-ok"
kubectl --context kind-e0 wait --for=jsonpath='{.status.phase}'=Succeeded pod/e0-probe --timeout=120s
kubectl --context kind-e0 logs e0-probe
kind delete cluster --name e0
```

观察到：容器里 `uname -r` 是 139；带 `--device /dev/kvm` 时容器里看得到这个设备。Kind 的节点 17 秒后 Ready，Kubernetes v1.37.0；探针 Pod 运行到 Succeeded 并输出 `pod-ok`；集群删除之后没有留下容器。

### E 经启动加载器冷启动（默认项不动）

E1 加一个只供实验用的启动项。做法是把 `grub.cfg` 里生成的 139 菜单项整段复制到 `/etc/grub.d/40_custom`，改三处：标题、菜单项的 id（改成 `e0-pvm-139`）、`linux` 行末尾加 `nokaslr`。`/etc/default/grub` 不动，所以默认项和它的参数都不变。脚本原文在 `commands-as-run.txt` 的 02:13:30 一条。先留了三份原件在 `/root/e0/`：`40_custom.orig`、`default-grub.orig`、`grub.cfg.before-e1`。

之后：

```bash
update-grub
grub-script-check /boot/grub/grub.cfg
awk '/^menuentry /{n++} n==1 && /^[[:space:]]*linux[[:space:]]/{print; exit}' /boot/grub/grub.cfg   # 仍是 149
```

观察到：语法检查通过；第 0 项的整段与改动之前逐字相同；`GRUB_DEFAULT=0`；新启动项的 `linux` 行是 `vmlinuz-6.8.0-139-generic … net.ifnames=0 nokaslr`。

E2 一次性冷启动：

```bash
kexec -u; cat /sys/kernel/kexec_loaded             # 必须是 0
grub-reboot e0-pvm-139
grub-editenv /boot/grub/grubenv list               # next_entry=e0-pvm-139
sync
SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot
```

E3 起来之后重做阶段 C 的检查和 `docker run`。观察到：`uname -r` 是 139；命令行是 `BOOT_IMAGE=/boot/vmlinuz-6.8.0-139-generic … nokaslr`；`next_entry=` 为空；`_text` 在 `ffffffff81000000`；加载之前没有 kvm 模块（没有做开机自动加载）；`modprobe kvm-pvm` 返回 0，`/dev/kvm` 出现；ioctl 的结果与阶段 C 相同；error 及以上级别的内核日志是空的；`docker`、`containerd`、`ssh` 都在运行，没有失败的单元；`docker run` 成功；默认项仍是 149。

E4、E5 重做 Kind。E5 的系统 Pod 检查：

```bash
kubectl --context kind-e0 delete pod e0-probe --wait=true
for ns in kube-system local-path-storage; do
  kubectl --context kind-e0 wait --for=condition=Ready pod --all -n $ns --timeout=180s
done
kubectl --context kind-e0 get pods -A
```

观察到：两个命名空间里的九个 Pod 全部 Ready（`1/1 Running`，重启次数 0）；集群删除之后没有留下容器；内核日志没有 error；`tainted` 仍是 12288。

### F 补充探测：vCPU 的 MSR 0x3a（计划之外）

计划里只写了“读 MSR 0x3a，记下读得到还是读不到”，指的是在宿主上用 `rdmsr`。已知的问题却在 vCPU 一侧：`kvm-pvm` 拒绝写回这个 MSR。所以加了这一步，直接问 KVM。它建一个 VM 和一个 vCPU，不设置内存，不运行，做完就关掉。脚本原文在 `commands-as-run.txt` 的 02:28:04 一条，做的是：

1. `KVM_GET_MSR_INDEX_LIST`、`KVM_GET_MSR_FEATURE_INDEX_LIST`：看 0x3a 在不在列表里。
2. 对 0x3a 和四个对照的 MSR（`IA32_TSC`、`EFER`、`STAR`、`IA32_APICBASE`）：`KVM_GET_MSRS` 读一次，再用 `KVM_SET_MSRS` 把读到的值原样写回。
3. 再单独给 0x3a 写一次 0。

观察到：

| MSR | 在 MSR 列表里 | 读 | 读到的值 | 原样写回 |
|---|---|---|---|---|
| `IA32_FEATURE_CONTROL`（0x3a） | 否 | 成功 | 0 | **被拒绝** |
| `IA32_TSC`（0x10） | 是 | 成功 | 非零 | 接受 |
| `EFER`（0xc0000080） | 否 | 成功 | 0 | 接受 |
| `STAR`（0xc0000081） | 是 | 成功 | 0 | 接受 |
| `IA32_APICBASE`（0x1b） | 否 | 成功 | `0xfee00900` | 接受 |

单独写 0 同样被拒绝。之后内核日志没有新的行。

## 5. 与计划不一致的地方，和过程中的意外

1. **计划在安全评审之后改过。** 第一版计划的最后一步是把默认启动项固定到 139 并让 `kvm-pvm` 开机加载。评审指出这会毁掉“失败了重启就回到 149”的保证，并指出另外两个没有证实的假设。采纳的改动：默认项全程不动；先做 B0；重启前确认没有预载的 kexec 内核，并用 `SYSTEMCTL_SKIP_AUTO_KEXEC=1`；不给全局参数加 `nokaslr`，改用单独的启动项；不做开机自动加载。评审的原文摘要和逐条处理在 本子任务的实施提案（内部文档） 第 5 节，被取代的第一版在 `PLAN.md` 末尾。
2. **阶段 A 与评审同时进行。** 阶段 A 不重启，每一步都能反过来做，所以没有等评审结束。会重启的各步（B0、B、E2）都在读到评审结论之后才做。
3. **A2 第一次因为 dpkg 锁失败。** `systemctl disable --now` 引起 systemd 重载，02:04:06 `apt-daily.service` 被启动了一次，它调用的 unattended-upgrade 占住了锁，02:04:14 结束。时间上是紧跟着发生的；是不是重载触发的，没有进一步确认。它没有安装或升级任何包（apt 的历史里那个时段只有本实验的两次安装，dpkg 的日志里没有升级），**但它往 apt 的缓存里下载了 26 个包**，包括整套 `6.8.0-151` 的内核和 libc6，见第 10 节第 4 条。重试时加了 `-o DPkg::Lock::Timeout=120`。另外，第一次的命令在 A2 失败之后没有停下、接着执行了 A3（`set -e` 管不到管道里前面的命令），A3 也因为同一把锁失败，没有造成改动。
4. **装旧内核改了 `/boot/vmlinuz` 这个符号链接。** 它现在指向 139，`vmlinuz.old` 指向 149。启动加载器不用这个链接（菜单项里写的是带版本号的路径），所以默认启动不受影响。但 `/etc/default/kexec` 里 `KERNEL_IMAGE="/boot/vmlinuz"`，谁要是打开 kexec-tools 的自动加载，重启就会进 139。现在没有打开（debconf 里 `load_kexec` 是 false）。
5. **阶段 C 里有一行输出有误导性。** `rdmsr exit=0` 是管道末尾 `head` 的返回值，不是 `rdmsr` 的。判断依据是它的输出 `cannot read MSR`。
6. **阶段 C 清过一次内核日志缓冲区。** `modprobe` 之前执行了 `dmesg -C`，为的是只看加载之后的新行。那一次启动（kexec）在此之前的内核日志因此不在 `dmesg` 里。冷启动那一次没有清，完整的日志存在 `kernel-log-E-cold-boot.txt`。
7. **E4 的“系统 Pod”检查写错了。** 命令是 `kubectl wait --for=condition=Ready pod --all -A`，把已经 Succeeded 的探针 Pod 也算了进去。它永远不会 Ready，用光了共用的超时，后面的 Pod 全部报超时。这一项不说明系统 Pod 的状态。E5 先删掉探针 Pod、再按命名空间等待，九个 Pod 全部 Ready。
8. **kind 和 kubectl 下载时没有核对校验和。** 事后算出的 SHA-256 与官方发布的一致，见 `state-after-E0.txt`。复用时应当先核对再安装，见第 8 节。
9. **模块包里的 manifest 与包里的模块对不上。** `manifest.txt` 记的两个模块的校验和（`99641d2f…`、`39c3a63e…`）与包里实际的文件（`07245afc…`、`5cda39fa…`）不同。读了 PVM 项目的打包脚本（`virt-pvm/pvm-context` @ `276edd0c` 的 `lib/guest-build-ko-rpm.sh`）：manifest 是在 rpmbuild 之前对构建目录里的模块算的，rpmbuild 的后处理可能改过文件（比如去掉调试段）。这个原因没有确认。可以确定的是：整个包的校验和与发布页一致，装上的文件与包里的逐字节相同。
10. **两处小的不一致，不影响结论。** 阶段 D 用的镜像是 `busybox:latest`，阶段 E 用的是 `busybox:1.36`。日志文件的名字是 `log-E-cold-boot.txt`，写计划时没有约定名字。
11. **关于 MSR 0x3a，计划作者先下过一个错的推断，后来用实测改正。** 阶段 C 在宿主上 `rdmsr` 读不到这个 MSR，计划作者当时据此认为“已知的 MSR 0x3a 问题在这家云上多半不存在”。这个推断不成立：已知的问题是 `kvm-pvm` 拒绝给 vCPU 写回它，与宿主上读不读得到没有关系。补充探测 F 直接测了 vCPU 一侧，结果是问题存在。这个错的推断没有写进任何已发布的文档。

## 6. 对虚拟机的改动，和怎样撤销

持久的改动：

| 改动 | 位置 | 怎样撤销 |
|---|---|---|
| 停用自动更新 | `unattended-upgrades.service`、`apt-daily.timer`、`apt-daily-upgrade.timer` | `systemctl enable --now` 这三个单元 |
| 新装内核 `6.8.0-139` | `linux-image-6.8.0-139-generic`、`linux-modules-6.8.0-139-generic`、`linux-modules-extra-6.8.0-139-generic`、`linux-headers-6.8.0-139-generic`、`linux-headers-6.8.0-139`；`/boot` 下的内核与 initramfs；`grub.cfg` 里多出 139 的菜单项 | 先 `apt-mark unhold`，再 `apt-get purge` 这五个包（必须在 149 上运行时做） |
| `/boot/vmlinuz`、`/boot/initrd.img` 改指向 139 | `/boot` | 卸掉 139 的包之后自动改回 |
| 新装工具 | `rpm2cpio`、`kexec-tools`、`msr-tools`，连带 `rpm-common`、`librpm9t64`、`librpmio9t64`、`liblua5.3-0` | `apt-get purge` |
| debconf 的选择 | `kexec-tools/load_kexec = false` | 随包清除 |
| 九个包被保留 | `apt-mark showhold` 列出的：139 的四个、149 的三个、`linux-image-generic`、`linux-headers-generic` | `apt-mark unhold` |
| PVM 的模块 | `/lib/modules/6.8.0-139-generic/updates/pvm-oot/kvm.ko`、`kvm-pvm.ko`；`depmod` 重新生成的索引 | 删掉这个目录，`depmod -a 6.8.0-139-generic` |
| 只供实验用的启动项 | `/etc/grub.d/40_custom` 末尾 19 行；`grub.cfg` 重新生成 | `cp /root/e0/40_custom.orig /etc/grub.d/40_custom && update-grub` |
| Docker | `docker.io`、`containerd`、`runc`；三个镜像（`busybox:latest`、`busybox:1.36`、Kind 的节点镜像）；名叫 `kind` 的 Docker 网络 | `docker system prune -a`；`docker network rm kind`；`apt-get purge` |
| kind、kubectl | `/usr/local/bin/kind`、`/usr/local/bin/kubectl`；`/root/.kube/config`（里面已经没有集群） | 删除 |
| 实验用的文件 | `/root/e0/`：模块包、解开的目录、三份原件 | 删除（撤销启动项之后再删） |

没有动的：`/etc/default/grub`（与阶段 E 之前留的副本逐字节相同，两者的修改时间都是 2026-11-12）；默认启动项；sshd；swap（仍然开着）；`/etc/modules-load.d/` 和 `/etc/modprobe.d/`（没有加任何东西）。网络配置实验没有动；`/etc/fstab` 和网络配置文件的修改时间是每次启动的时刻，是云的启动辅助程序重写的，内容没有比对。

复核查出这张表漏了几项，补在第 10 节第 5 条。

只在本次启动里有效、重启就没有的：`kvm`、`kvm_pvm`、`msr` 三个模块已加载；内核被标记为 tainted。

对开发机的改动：只有任务目录下的文档。评估时下载过一次模块包到临时目录，已删除。

## 7. 虚拟机现在的状态，和怎样切换

**这一节是 E0 结束时的状态。** 之后 E1 到 E3 又改过这台机器，现在的状态和切换方法见 `../E3/RECORD.md` 第 7 节。

实验结束时（02:22，`state-after-E0.txt`）：

- 正在运行 `6.8.0-139-generic` 加 `nokaslr`，是 E2 那一次冷启动。`kvm-pvm` 已加载，有 `/dev/kvm`。
- 没有容器，没有 Kind 集群。
- 下一次重启或断电重开会回到 `6.8.0-149-generic`，没有 `/dev/kvm`。

再次进入 PVM 宿主（做 E1 之前要做）：

```bash
kexec -u; cat /sys/kernel/kexec_loaded      # 0
grub-reboot e0-pvm-139
SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot
# 起来之后
uname -r                                    # 6.8.0-139-generic
modprobe kvm-pvm && ls -l /dev/kvm
```

回到原来的内核：重启一次即可。要把机器恢复到实验之前的样子，在 149 上按第 6 节的表从下往上撤销。

## 8. 在另一台机器上重做

适用的机器：Ubuntu 24.04，x86_64，没有硬件虚拟化的云主机，软件源里还有 `6.8.0-139` 的内核包。别的发行版和内核版本要先看 PVM 项目有没有对应的模块包。

要按机器改的参数：

| 参数 | 这一次的值 | 怎样得到 |
|---|---|---|
| 根分区的 UUID | `<uuid>` | `blkid`，或者现成的 `/proc/cmdline` |
| 原有的启动参数 | `ro console=<原有的串口设置> net.ifnames=0` | `/proc/cmdline`。**整条照抄，只在末尾加 `nokaslr`。** 这台机器的网络配置按 `eth0` 匹配，丢了 `net.ifnames=0` 网络就起不来 |
| 菜单项的 id | `gnulinux-advanced-<UUID>>gnulinux-<版本>-advanced-<UUID>` | `grep -o "menuentry_id_option '[^']*'" /boot/grub/grub.cfg` |
| ssh 的名字 | `cpu` | — |

次序和每一步的停止条件：

1. **先确认有退路。** 机器的主人能从控制台重启或重建。没有这一条不做。
2. **只读地看一遍**：是不是 BIOS 加 GRUB；`grub.cfg` 的开头有没有处理 `next_entry` 的那几行；`/sys/kernel/security/lockdown` 是不是 `none`；模块签名是不是强制的。有一项不是，就停下重新评估。
3. **阶段 A。** 停自动更新之后等几秒，或者给 apt 加锁的超时。装完核对第 0 项仍是原来的内核。不是，就停下。
4. **阶段 B0。** 重启之后 `next_entry` 没有被清掉，就不做阶段 E，只用 kexec。
5. **阶段 B。** 5 分钟连不上，就请主人从控制台重启，回到原内核，实验停在这里。
6. **阶段 C。** `modprobe` 失败时保留内核日志，加 `no5lvl` 用 kexec 再试一次。之后带进阶段 E 的启动参数必须是这里成功的那一条。
7. **阶段 D。** kind 和 kubectl 下载之后先核对校验和再放进 `/usr/local/bin`：
   ```bash
   curl -fsSL https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64.sha256sum
   curl -fsSL https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl.sha256
   ```
8. **阶段 E。** `update-grub` 之后核对第 0 项的整段没有变，再 `grub-reboot`。重启前确认 `kexec_loaded` 是 0。5 分钟连不上，请主人重启一次，会回到原内核。
9. **收尾。** 做一次只读的状态记录（`state-after-E0.txt` 那一条命令），保存内核日志。

这一次证实了、可以直接沿用的：旧内核装进来不会抢走默认项；云的启动加载器会清 `next_entry`；kexec 和冷启动都能进 139；不需要 `no5lvl`。这些只在这一家云、这一种机型上证实过。

不要照搬的：第 5 节第 5、6、7 条里那三处写得不好的命令。阶段 C 里在宿主上读 MSR 0x3a 那一步可以不做，要了解这个 MSR 就做补充探测 F。

要不要把 PVM 宿主设成默认状态（固定默认启动项，开机加载模块），这一次有意没有做。要做的话先想清楚失联时怎样回退，并先用一次性启动项试一遍开机加载。

## 9. 没有验证的

- 没有运行任何 guest。PVM 在这款 CPU 上的切换路径、guest 的系统调用和中断，都要到 E1 才碰到。
- 每种启动方式只做了一次；没有长时间运行；没有测性能。
- 没有试过不加 `nokaslr`。PVM 项目的测试环境加了它，这里照做，没有验证它是不是必需的。
- 没有试过开机自动加载 `kvm-pvm`。
- `6.8.0-139` 比 `6.8.0-149` 旧，两者之间的安全修复在 PVM 宿主上没有；自动更新也停了。这台机器可丢弃，所以接受；不能照此对待要长期使用的机器。
- 内核带着没有签名的树外模块，处于 tainted 状态。对 Ubuntu 的支持和问题定位有什么影响，没有评估。
- `kvm-pvm` 拒绝写回 MSR 0x3a 这件事，只在 ioctl 层面看到了。它会不会让 Kata 的某一种 VMM 启动失败，没有验证。
- 换内核之前 Docker 和 Kind 的表现没有测过，见第 1 节。

## 10. 复核之后的更正（2026-11-25）

复核由一个没有参与实验的子代理做：逐条拿记录对原始日志，并在虚拟机上只读地抽查。结论是四条通过的判断在声明的范围内成立，没有一条发现改变结果。发现和处理的汇总在 本子任务的实施提案（内部文档） 第 5.2 节；这里是对本记录的更正。

1. **逐字的命令导出不全（高）。** `commands-as-run.txt` 第一次是 02:23:15 导出的，之后没有刷新，漏了四条动过虚拟机的命令：02:23:15 的 `dmesg`、02:24:07 和 02:24:35 的两条只读查询、02:28:04 的补充探测 F。本记录当时却说它是“每一条命令”。现在重新导出了，23 条；F 的脚本另存为 `scripts/F-msr-probe.py`。复核自己在虚拟机上跑的 10 条只读命令不在里面，列在它的报告里。
2. **有几项说法当时没有落盘的证据（中）。** 这几条命令的输出只在屏幕上看过：02:02:27、02:04:22、02:22:28、02:24:07、02:24:35。靠它们的说法有：三个工具的版本；apt 和 dpkg 的历史；02:04 那次自动更新的起止时间；装上的模块与包里的逐字节相同；debconf 的设置；连带装上的依赖包；kube 配置里已经没有集群。复核在虚拟机上重新查过，都属实。04:01 补了一次只读核对，结果在 `log-G-postcheck.txt`。
3. **两处时间写错了（中）。** 安全评审是 02:08:22 结束的，不是 02:05:49（那是开始等它的时刻）。“会重启的各步都在读到评审结论之后才做”仍然成立，第一次重启是 02:09:12。时间线里 02:22:28 那一行原先把三条不同时刻的命令并在了一起，已经拆开。
4. **自动更新那一次的影响说轻了（中）。** 它没有安装任何包，但下载了 26 个包到 apt 的缓存，包括 `6.8.0-151` 的整套内核和 libc6。`linux-image-generic` 的候选版本因此是 `6.8.0-151`。元包 `linux-generic` 装着、没有设保留，它之所以没有被升级，只是因为它依赖的包设了保留。所以“旧内核装进来之后第 0 项仍是 `6.8.0-149`”依赖那几个保留：谁解除保留并恢复自动更新，`6.8.0-151` 就会装进来排到第 0 项。E2 之后默认启动项改成按 ID 固定，不再依赖排第几。
5. **第 6 节的改动清单漏了几项（中）。** 都是装 Docker 和 Kind 带来的：`docker.service`、`docker.socket`、`containerd.service` 设成了开机自启（所以在 `6.8.0-149` 上也会启动）；加了 `docker` 用户组；建了 `/etc/cni/net.d` 和 `/opt/containerd`；`/root/.kube/cache`。另外 grubenv 在 E0 之后带着一个值为空的 `next_entry`，E0 之前它没有变量（E2 里清掉了）；停自动更新的那一步改了 `/etc/rc[2-5].d` 下的链接。
6. **“重启一次就回到 `6.8.0-149`”在 E0 里没有实际走过（中）。** E0 的三次启动是：一次性启动到 149 的子菜单项、kexec、一次性启动到自定义项。第 0 项在 `grub.cfg` 重新生成两次之后没有启动过。记录里把它写成了事实，其实是从配置读出来的（`set default="0"`，第 0 项是 149，`next_entry` 为空）。E2 在 03:26 把默认项按 ID 固定之后做了一次普通重启，回到了 `6.8.0-149`，这一条现在是测到的（`../E2/log-01d-drill-on-default.txt`）。
7. **关于 MSR 0x3a 的小标题比测试强（低）。** 原先写的是“已知的问题在这台机器上存在”。测到的只是 ioctl 层面的行为，没有用 VMM 验证，也没有 Intel 的对照，已经改成“与已知问题的描述一致”。复核读了 PVM 的源码（`virt-pvm/linux` @ `ad74ccef`）：写这个 MSR 时非 Intel 的宿主直接返回失败，读则返回存着的值，与测到的一致。另外，KVM 在这台宿主上报告的 MSR 列表里没有它，所以按列表保存和恢复 MSR 的 VMM 不会去写它；风险在跨宿主的快照和写死的清单。E1 里 Kata 的三种 VMM 冷启动都没有碰到它。
8. **第 4 节整理过的命令与实际执行的有几处出入（低），都不改变结果。** 阶段 A2 把两次执行并成了一段，`apt-get update` 只在失败的那一次里执行过。A2 之后核对默认项的 `awk` 是 02:05:31 改对的那一条；02:04:37 的第一条写错了，打印的是 `menuentry` 那一行（`log-A-prepare.txt` 里“grub default entry kernel”下面那一行），这个写错的检查原先没有交代。重启和 kexec 实际是以 `(sleep 2; …) &` 的形式发的，好让 ssh 先返回。B0 里“必须是 0”只是打印了，没有强制。D1 的容器里还执行了 `ls -l /dev/kvm`。“最多等 5 分钟”实际上最多约 10 分钟（36 次，每次连接超时 8 秒再等 8 秒）。
9. **时间线的“改动”一栏有三处不准（低）。** A2 第一次失败的执行其实做了 `apt-get update` 和 `debconf-set-selections`；B0 和 E2 写了 grubenv；E3 拉了 `busybox:1.36` 镜像。
10. **第 5 节第 4 条说的风险，机制说得不对（低）。** 这个版本的 kexec-tools 没有 `LOAD_KEXEC` 这个开关，也没有 `kexec-load.service`。准确的说法是：任何按默认去加载 `/boot/vmlinuz` 的东西，加载到的会是 139。
11. **撤销的次序自相矛盾（低）。** 第 7 节说“按第 6 节的表从下往上撤销”，但表的最后一行（`/root/e0/`）要在撤销启动项之后才能删。正确的次序：先撤销 `40_custom` 里的启动项，再在 `6.8.0-149` 上清掉 139 的包，其余随意。“卸掉 139 的包之后符号链接自动改回”是预期，没有验证。
12. **第 8 节的复用说明有缺口（低）。** 参数表缺原内核的版本、模块包的地址和校验和（在第 2 节）。B0 没有写重启失败时怎么办，也没有写 `next_entry` 没有被清掉时怎样清（`grub-editenv /boot/grub/grubenv unset next_entry`）。第 3 步只说“停下”，没有说第 0 项已经变了怎么恢复（比如原内核比 139 旧的时候）；按 ID 固定默认项可以避开这个问题，做法在 E2。“整条照抄”不包括 `BOOT_IMAGE=`。kubectl 的版本来自会变的 `stable.txt`，当时取到的是 v1.37.2。
13. **`PLAN.md` 的附录只留了第一版的两段（低）。** 第一版与执行的计划还有几处不同：C4 原先只建 VM 不建 vCPU；A2 的 debconf 设置、A3 的元包保留、A4 的 initramfs 检查、B2 和 C5 的补充都是后加的。其中 debconf、元包保留、initramfs 检查这三样是在评审结论回来之前、看到评审的中间输出之前我自己加的，本子任务的实施提案（内部文档） 里原先把它们都算成了评审的功劳，已经改正。`PLAN.md` 修订记录里的时间也从 02:06 改成了 02:08。
14. **“实验前的副本”说得不准（低）。** `/root/e0/default-grub.orig` 是阶段 E 之前（02:13:30）留的，不是实验开始之前。结论不变：它和 `/etc/default/grub` 的修改时间都是 2026-11-12，E2 固定默认项之前留的副本与它逐字节相同。
15. **敏感信息（低）。** 复核确认各文件里没有地址、密钥路径、账号。有三样留在内部的文件里：云服务商的名字（在机器评估和内核日志的 DMI 行里）、根分区和 swap 的 UUID、开发机上的绝对路径。之后负责人要求把操作记录提交到公开的仓库：公开的副本只带计划、操作记录和脚本，不带原始输出、逐字的命令和机器评估；副本里的 UUID 换成了占位符，并在生成时扫描地址、密钥、指纹、云服务商的名字和开发机的路径，见 `../README.md` 的“发布”一节。
16. **几处措辞不一致（低）。** 关于 MSR 0x3a 那个错的推断，本记录写“没有写进任何已发布的文档”，本子任务的实施提案（内部文档） 原先写“没有写进任何文档”；前者准确，后者已改。编码代理的会话摘要里还留着那个错的推断，那不是文档。
17. **总体任务的文档里有一句话写早了（中）。** [gap-analysis.md](../../gap-analysis.md) 第 5 节在复核开始之前就写了“做完之后由另一个子代理复核了记录”。写的时候复核还没有做。现在复核做了，那句话已经改成符合实际的说法。这一条是我的错：把打算做的事写成了做过的事。
