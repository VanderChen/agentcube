# E3 操作记录：CubeSandbox 在它自己的 PVM 宿主内核上

- 时间：2026-11-25，03:42 至 03:54（UTC）；04:05 又做了一步清理（第 4 节的第 14 步）。
- 机器：同 E0 到 E2。
- 计划：`PLAN.md`。批准：负责人 2026-11-25 要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。
- 结果：**通过。换上 CubeSandbox 自己的 PVM 宿主内核之后，CubeSandbox v0.8.0 在这台 AMD 机器上可用**：模板建得出来，从模板建沙箱、执行代码、删除，十次全部成功。范围和保留见第 1 节。

## 1. 结论

| 通过标准 | 观察到的 | 证据 |
|---|---|---|
| 换到它的宿主内核之后能登录，有 `/dev/kvm` | `6.6.117-opencloudos9.cubesandbox.pvm.host` 经一次性启动项起来，能登录；`modprobe kvm_pvm` 返回 0，`/dev/kvm` 出现 | `log-02-reboot-to-cube-host.txt`、`log-03-after-boot.txt` |
| 从镜像创建模板 | 成功，20 秒到 READY。这一步起一台 microVM 并做内存快照 | `log-07-quickstart.txt` 的第一次执行 |
| 从模板创建沙箱，到达运行状态 | 成功。这一步是恢复快照 | 同上的第二次执行 |
| 在沙箱里执行代码并取回输出 | 成功。沙箱里的内核是 `6.6.117-opencloudos9.cubesandbox.pvm.guest`，2 个 CPU，算出的结果正确 | 同上 |
| 上两步加删除，重复十次 | 10/10 | `log-08-cycles.txt` |
| 宿主内核日志没有错误特征 | 起沙箱期间宿主内核日志没有任何新行。整次启动里有一行匹配 `WARNING:`，是开机时关于 Spectre V2 的提示，不是内核告警的堆栈，见第 5 节第 5 条 | `log-08-cycles.txt`、`log-09-evidence.txt` |

十次循环的时间（毫秒，是观察不是基准；用的是 E2B 的 Python SDK，从发请求到返回）：创建 79 到 99，执行代码 103 到 171，删除 87 到 98。VMM 的日志里是 1 次快照、11 次恢复、12 台虚拟机，没有 ERROR，没有提到 MSR 的行。

这个结论说明的和没有说明的：

- **用的是 CubeSandbox 文档要求的宿主内核**，不是 E0、E1 用的那个宿主。这台机器现在有两种 PVM 宿主：Ubuntu 的 `6.8.0-139` 加 PVM 项目的模块（Kata 在上面可用，CubeSandbox 不可用，见 E2）；CubeSandbox 的 `6.6.117`（CubeSandbox 在上面可用）。E3 没有测 Kata 在后一种宿主上的情况。E4 里：直接启动 E1 用的那个 guest 内核，约 1 秒后复位（没有经 Kata 再试）；把 Kata 的 guest 内核换成 CubeSandbox 的之后，Dragonball 和 Cloud Hypervisor 起得了沙箱。所以在 CubeSandbox 的宿主内核上，两者在同一次启动里都起得了沙箱（先后，不是同时），见 `../E4/RECORD.md`。
- **与文档做法有两处不同**（计划里写明）：没有把它的内核设成默认启动项、没有改全局的启动参数，而是用一个单独的一次性启动项带上它要求的那一串参数；串口控制台保留这台机器原来的设置。`kvm_pvm` 也没有设成开机加载。
- **单机、一个模板、十一个沙箱，先后创建。** 没有并发，没有长时间运行，没有测暂停与恢复、网络策略、出口代理。
- **四个基础镜像来自 Docker Hub**（E2 第 5 节第 1 条）。
- E0 测到的“`kvm-pvm` 在 AMD 上拒绝写回 MSR 0x3a”是 PVM 项目那个模块的行为。在 CubeSandbox 自己的宿主内核上，11 次快照恢复没有一条关于 MSR 的告警；这个内核的模块对那个 MSR 是什么行为，没有单独探测。

## 2. 环境与版本

| 项 | 版本 | 来源与核对 |
|---|---|---|
| 宿主内核 | `linux-image-6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e`，版本 `6.6.117-gbc75224fca7e-1` | CubeSandbox 的发布 `kernel-release-261012-1`；SHA-256 `821f2608…906da6`，与 GitHub 对这个文件给出的摘要一致 |
| 宿主的启动参数 | `deploy/pvm/grub/host_grub_config.sh` @ `41748bb7`（v0.8.0）里的那一串，去掉它的两个 `console=`；另保留这台机器原有的 `console=<原有的串口设置> net.ifnames=0` | CubeSandbox 的仓库。完整的命令行在 `log-03-after-boot.txt` |
| PVM 模块 | 这个内核自带的 `kvm-pvm.ko`、`kvm.ko` | 内核包 |
| CubeSandbox | v0.8.0，E2 装的，没有重装 | E2 |
| guest 内核 | `vmlinux-pvm`，`6.6.117-opencloudos9.cubesandbox.pvm.guest-gbc75224fca7e` | E2 |
| 模板的镜像 | `cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest@sha256:467494c3…c18c5e` | CubeSandbox 快速开始 |
| SDK | `e2b-code-interpreter` 2.11.10，`e2b` 2.64.0，Python 3.12.3；用 uv 0.13.10 装在 `/root/e2/venv` | PyPI；uv 的 SHA-256 在 `log-07-quickstart.txt` |

这个内核的几点事实（`log-01-host-kernel.txt`、`log-03-after-boot.txt`）：启动这台机器要用的驱动（virtio-pci、virtio-scsi、sd、ext4）都编在内核里；`KVM_PVM`、`KVM_AMD`、`KVM_INTEL` 都是模块；带 `no5lvl` 启动之后五级页表关着；时钟源是 tsc；内核因为 `clearcpuid=` 和未签名的模块被标记为 tainted（8196）。iptables 在它上面可用。

## 3. 操作是怎样做的

与 E1、E2 相同。`scripts/` 里有几个脚本来自别的实验：`01-deadman.sh`、`01a-guard.sh`、`02-firewall.sh`、`07-status.sh`、`08-pvm-project-test.sh` 是从 E2 原样复制来的，其中 `01a-guard.sh` 在 E3 里没有执行；`11-after-boot-139.sh` 是 E2 的 `01d-after-boot.sh`；`12b-kata-smoke.sh` 是 E1 的 `07-kata-smoke.sh`；`09-quickstart.sh`、`10-cycles.sh` 在 E2 里写成、没有执行过，在 E3 里执行并改过。步骤的名字与脚本的名字不总是一样，以 `commands-as-run.txt` 为准。执行过的每个脚本版本在 `scripts-as-run/` 下各留了一份，文件名前面是 SHA-256 的前八位；`09-quickstart.sh` 的第一个版本除外，它在留存之前就被改掉了。`scripts/` 里有一个脚本不是 E3 执行的那一版：`02-firewall.sh` 在第 5 节第 1 条那件事之后改过一次（链不存在时报错并以 3 退出），`scripts/` 里是改过的；E3 里执行的是改之前的，留在 `scripts-as-run/`，它的 SHA-256 在 `commands-as-run.txt` 里。

## 4. 时间线与观察

| 时间 | 步骤 | 做什么 | 结果 |
|---|---|---|---|
| 03:42:37 | 01 | 下载内核包并核对；`dpkg -i`；核对驱动和默认启动项；加启动项 `e3-cube-pvm-host` | 通过。默认启动项仍是按 ID 固定的 `6.8.0-149` |
| 03:43:03 | 02 | 停掉 CubeSandbox；一次性启动到新启动项 | 第 8 次轮询连上（03:44:52） |
| 03:44:57 | 03 | 核对内核与参数；`modprobe kvm_pvm`；挂 XFS | 通过。起来之后 Docker 和 CubeSandbox 都没有自己启动 |
| 03:45:13 | 04 | 防火墙 | **少了一条**，见第 5 节第 1 条 |
| 03:45:18 | 04 | 上保险（60 分钟） | 通过 |
| 03:45:24 | 05 | 放行，启动 Docker 和 CubeSandbox | 19 秒后它自己的检查通过；17 个单元在运行 |
| 03:45:57 | 04 | 重新加防火墙 | 补上了那一条 |
| 03:46:03 | 05 | 从开发机探测 19 个端口 | 只有 22 是通的 |
| 03:47:39 | 06 | PVM 项目的 CubeSandbox 测试 | **不适用**，见第 5 节第 2 条 |
| 03:47:56 | 07 | 快速开始：建模板，用 SDK 执行代码 | 模板 20 秒建成；SDK 没装上，见第 5 节第 3 条 |
| 03:48:45 | 07 | 改了脚本再执行 | 通过：创建 173 毫秒，执行 175，删除 91 |
| 03:49:00 | 08 | 十次循环 | 10/10 |
| 03:50:07 | 09 | 只读：VMM、shim、宿主内核的日志 | 见第 1 节 |
| 03:50:23 | 09b | 只读：状态 | `log-09b-status.txt` |
| 03:50:30 | 10 | 停掉 CubeSandbox 的单元和容器 | 单元全停；容器只剩一个已退出、不带重启策略的 `cube-egress`；`eth0` 上的 eBPF 过滤器和约 500 个网络设备还在，等重启 |
| 03:50:50 | 11 | 一次性启动回 E0 的 PVM 宿主 | 第 7 次轮询连上（03:52:35） |
| 03:52:35 | 11 | 核对；加载 `kvm-pvm` | **CubeSandbox 装着、设着自启，但起来之后一个单元都没有运行**；Docker 也没有自己启动；`eth0` 上没有过滤器；监听的只有 ssh |
| 03:52:59 | 12 | 去掉 Docker 的闸门；删掉放行文件；卸载 XFS；试着启动 Cubelet | Docker 照常运行；Cubelet 的启动请求被闸门挡住 |
| 03:53:06 | 12b | PVM 项目的 Kata 冒烟测试 | 三种 VMM 都是 PASS |
| 03:53:43 | 13 | 只读：最后的状态；从开发机探测端口 | 只有 22 是通的 |
| 04:05:57 | 14 | 清掉实验脚本留在虚拟机 `/tmp` 下的临时文件 | 已经没有了（重启时清过）；脚本的退出码 1 来自最后一条列目录的命令 |

E3 重启两次。连同 E0 的三次和 E2 演练的两次，这台机器当天一共重启七次，其中一次是 kexec。

## 5. 与计划不一致的地方，和过程中的意外

1. **有最多 38 秒，Docker 发布的两个端口没有被防火墙盖住。** 重启之后我先加防火墙、再启动 Docker。防火墙脚本里管 Docker 发布端口的那条规则加在 `DOCKER-USER` 链上，而这条链是 Docker 启动时才建的；脚本发现链不存在就跳过了，没有报错。03:45:24 开始启动 Docker 和 CubeSandbox，03:46:02 我重新加了一遍才补上；容器是这 38 秒里的哪一刻起来的，日志里没有。这期间管理界面（12088）和 MinIO（9000）有可能从公网连得到；其余端口由 `INPUT` 链上的规则挡着，不受影响。之后的探测确认都关上了。这期间有没有人连过，没有查。E2 里没有这个问题，因为那时 Docker 一直在运行。**重做时的次序应当是：先启动 Docker，再加防火墙，最后启动 CubeSandbox**；并且启动 Docker 时不能有带自动重启策略、又发布了端口的容器（E3、E4 里停掉 CubeSandbox 时这些容器都被删掉了，所以没有）。脚本已经改成在链不存在时报错并以 3 退出；虚拟机上改过的那一份在 `/root/exp/E4/scripts/02-firewall.sh`，`/root/exp/E3/scripts/` 下的还是旧的。
2. **PVM 项目的 CubeSandbox 测试在这个内核上不适用。** 它的环境检查要求宿主模块来自 `updates/pvm-oot/`，也就是它自己的模块包；这个内核用的是自带的模块，脚本在检查处就退出了，没有任何输出。`log-06-pvm-project-test.txt` 里显示的那段 JSON 是 E2 留在同一个目录里的旧文件，与这一次无关。计划里写的“与 E2 相同的测试”因此少了这一项，由快速开始的做法代替，后者覆盖得更多（多了执行代码）。
3. **`09-quickstart.sh` 第一次执行失败，是我的脚本的问题。** 快速开始要求把 `SSL_CERT_FILE` 指到 mkcert 的根证书。我在安装 SDK 之前就设了它，uv 因此只信这一张证书，连不上 PyPI。改成先在独立的虚拟环境里装好 SDK，运行时才设这个变量。两次执行都在 `log-07-quickstart.txt` 里；模板是第一次执行建的，第二次直接复用。脚本的第一个版本没有留下，只有 SHA-256。
4. **`12-final.sh` 的退出码是 1，动作都做完了。** 最后一行数保险的定时器，数到 0 时 `grep -c` 返回 1。
5. **宿主内核日志里匹配错误特征的那一行**是 `Spectre V2 : WARNING: Unprivileged eBPF is enabled with eIBRS on…`，开机第 0.15 秒打印的。另有一行 error 级别的 `Unsupported mitigations=on`。两行都来自它要求的启动参数和这个内核的默认设置，与 PVM、与沙箱无关。
6. **没有另请子代理做安全评审**（计划里写明）。失联的风险与 E0 相同，实际没有发生。
7. **停掉单元之后容器基本都被删掉了**，所以计划里“去掉容器的自动重启策略”这一步只对剩下的一个容器有意义，而它本来就没有重启策略。
8. **沙箱的端口映射在防火墙之外**（E2 的计划里写明接受）。E3 里沙箱一共存在了几十秒：建模板约 20 秒，11 个沙箱各不到 1 秒。

## 6. 对虚拟机的改动，和怎样撤销

E3 自己引入的：

| 改动 | 位置 | 怎样撤销 |
|---|---|---|
| CubeSandbox 的 PVM 宿主内核 | 包 `linux-image-6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e`；`/boot` 下的内核、initramfs、配置；`/lib/modules/6.6.117-…/`；`grub.cfg` 里多出它的菜单项 | `dpkg --purge`（在别的内核上运行时做） |
| 一次性启动项 `e3-cube-pvm-host` | `/etc/grub.d/40_custom` 末尾，接在 E0 的 `e0-pvm-139` 之后；原件在 `/root/e3/40_custom.before` | 删掉那一段，`update-grub` |
| 下载的内核包、安装日志 | `/root/e3/`（64 MB） | 删除 |
| 模板 `tpl-5b0a841ee9a24d7494191a95` 和它的快照 | `/data/cubelet`（在 XFS 的稀疏文件里）、`/usr/local/services/cubetoolbox/cubebox_os_image/` | 随 CubeSandbox 卸载；或启动 CubeSandbox 之后 `cubemastercli template delete` |
| SDK 的虚拟环境、uv | `/root/e2/venv`、`/root/e2/bin/uv`、`/root/e2/quickstart/`、`/root/.config/uv` | 删除 |
| CubeSandbox 运行时建的目录和 Docker 网络（复核补记，E2 的表里也没有；`../E4/log-18-state-supplement.txt`） | `/data/CubeMaster`、`/data/cube-shim`、`/data/snapshot_pack`、`/data/cubeops`、`/data/cube-shared`、`/data/shared`；Docker 网络 `support_default` | 随 CubeSandbox 卸载；`docker network rm` |
| Docker 的闸门 | E2 装的，E3 结束时去掉了 | — |

E2 引入、现在还在的，见 `../E2/RECORD.md` 第 6 节；E1 的见 `../E1/RECORD.md` 第 6 节；E0 的见 `../E0/RECORD.md` 第 6 节。

把机器恢复到 E0 之前的样子，次序是：卸载 CubeSandbox；删掉闸门；清掉 `/etc/grub.d/40_custom` 里实验加的各段（E0 一段、E3 一段、E4 两段）并把 `/etc/default/grub` 换回原件，`update-grub`；在 `6.8.0-149` 上清掉另外两个内核；再按各记录的表清其余的。实际上这台机器是可丢弃的，重建更省事。

## 7. 虚拟机现在的状态（E0 到 E4 之后）

E3 结束时（03:53）的只读记录在 `log-13-state.txt`。这一节按 E4 之后的情况更新过：04:31 的只读记录在 `../E4/log-16-state.txt`，04:58 的补充在 `../E4/log-18-state-supplement.txt`。

- **正在运行**：`6.8.0-139-generic` 加 `nokaslr`（04:29 经一次性启动项 `e0-pvm-139` 起来），`kvm-pvm` 已加载，有 `/dev/kvm`。**Kata 在这个状态下可用。**
- **下一次重启之后**：回到 `6.8.0-149-generic`（默认启动项，按 ID 固定），没有 `/dev/kvm`。Docker 会自己启动，CubeSandbox 不会。
- **装着的三个内核、四个一次性启动项**：`6.8.0-149`（默认）；`6.8.0-139`，启动项 `e0-pvm-139`（Kata 用）和 `e4-pvm-139-no5lvl`（E4 的对照用）；`6.6.117-…cubesandbox.pvm.host`，启动项 `e3-cube-pvm-host`（带它文档的整串参数，IPv6 关着）和 `e4-cube-host-min`（只带 `nokaslr no5lvl`，CubeSandbox 和换了 guest 内核的 Kata 都能用）。
- **CubeSandbox**：装着，不在运行，受闸门约束。没有 `/run/e2-allow` 时它的单元启动不了，开机也不会自启。
- **Docker、containerd**：在运行。没有容器在运行；有一个已退出、不带重启策略的 `cube-egress`。containerd 的三个命名空间里都没有容器记录（E4 里 QEMU 失败留下的一条在 04:57 清掉了）。
- **对外**：只有 ssh。没有实验加的防火墙规则（`E2-IN` 链不在，`INPUT` 和 `DOCKER-USER` 里没有规则；Docker 自己的规则在），没有保险的定时器，`eth0` 上没有 eBPF 过滤器。
- **自动更新仍然停着**（apt 的两个定时器和 unattended-upgrades 都是停用、未运行），九个内核相关的包仍然保留着（E0）。

**进入“Kata 可用”的状态**：

```bash
grub-reboot e0-pvm-139 && SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot
# 起来之后
modprobe kvm-pvm
ctr run --rm --runtime io.containerd.kata.v2 \
  --runtime-config-path /etc/kata-containers/pvm/configuration-clh-pvm.toml \
  docker.io/library/busybox:1.36 demo uname -r          # 镜像要先在同一个 namespace 里拉好
```

**进入“CubeSandbox 可用”的状态。** 次序要紧，见第 5 节第 1 条和 `../E4/RECORD.md` 第 5 节第 2 条。下面每一行是 E4 里执行过的一步，脚本在虚拟机的 `/root/exp/E4/scripts/` 下；`/root/exp/E3/scripts/` 下的防火墙脚本是旧的，不要用。与 E4 实际执行的次序有一处不同：闸门那一步提前到了上保险之前，E4 里它是启动之后才补的。这一整段照这个次序没有再执行过；复核的子代理读过这些脚本，认为次序是安全的，同样没有执行。

开始之前先看 `MODE=status bash /root/exp/E4/scripts/01a-guard.sh`：Docker 应当在运行，并且不在闸门之下（现在就是这样）。不是这样，说明上一轮的收尾没有做完，或者机器在 CubeSandbox 运行着的时候被重启过；先按后面两段处理，不要往下做。

```bash
cd /root/exp/E4/scripts
ENTRY=e4-cube-host-min bash 02-reboot.sh   # 清掉 kexec 预装的内核，设一次性启动项，重启。换成 e3-cube-pvm-host 就是文档的整串参数，IPv6 会被关掉
# 起来之后。Docker 已经自己启动了：它现在不在闸门之下
bash 03b-after-boot-cube-host.sh           # 核对内核，打印启动参数，加载 kvm_pvm
MODE=install bash 01a-guard.sh             # Docker 放回闸门之下，并放行这一次启动。它不启动任何东西
bash 03-xfs.sh                             # 挂上 /data/cubelet
MODE=apply bash 02-firewall.sh             # 退出码不是 0 就停。3 表示管 Docker 发布端口的那一条没有加上
MODE=arm MINUTES=40 bash 01-deadman.sh     # 保险：到时间机器自己重启，要用得更久就再执行一次续上。这时它不应当再告警“闸门没有装”
bash 05-start-cube.sh                      # 防火墙、保险、/dev/kvm、挂载缺一样它就不启动；启动之后等自检通过
```

之后从开发机探测端口（`tools/portprobe.sh`），确认外面只有 22 是通的。在这个状态下要用 Kata，配置目录是 `/etc/kata-containers/pvm-cube-guest/`，只有 Dragonball 和 Cloud Hypervisor 可以。

**退出这个状态。** 这四步在 E3、E4 里各做过一遍：

```bash
cd /root/exp/E4/scripts
bash 10-finish.sh                          # 停掉 CubeSandbox，去掉它的容器的自动重启
ENTRY=e0-pvm-139 bash 02-reboot.sh         # 回到 Ubuntu 的 PVM 宿主。保险的定时器和防火墙规则随重启消失
# 起来之后。Docker 这时受闸门约束，没有启动
EXPECT=139 bash 11-after-boot-139.sh       # 核对；加载 kvm-pvm；挂上 XFS；放行并启动 Docker
bash 12-final.sh                           # 查过没有会自动重启的容器之后，去掉 Docker 的闸门；卸载 XFS
```

`12-final.sh` 必须在 `11-after-boot-139.sh` 之后做：Docker 没有启动时它列不出容器，会不经检查就去掉闸门。

**收尾做到一半**（`10-finish.sh` 已经做过，容器的自动重启已经去掉，后面的步骤没有做完）：在 Ubuntu 的 PVM 宿主上把剩下的步骤做完。`11-after-boot-139.sh` 会在没有防火墙的情况下启动 Docker，所以只有 `10-finish.sh` 确实做过才安全。分不清做没做过，按下一段处理。

**CubeSandbox 运行着的时候机器被重启了**（保险触发，或者别的原因）：这种情况没有发生过，也没有演练过，没有现成的脚本。照脚本读下来，起来之后是默认的 `6.8.0-149`，Docker 和 CubeSandbox 都被闸门挡着，机器是安静的。这时不要做 `11-after-boot-139.sh`（带 `EXPECT=139` 时它会启动 Docker）、`01a-guard.sh` 的 `MODE=allow`（同样会启动 Docker）和 `12-final.sh`，也不要手工启动 Docker：CubeSandbox 的那几个容器还带着自动重启的策略，Docker 一启动它们就带着发布的端口起来，而管这些端口的 `DOCKER-USER` 链要到 Docker 启动之后才有。要先挡住这两个端口再启动 Docker，然后做 `10-finish.sh`。怎样先挡住没有验证过；机器是可丢弃的，重建是另一条路。

## 8. 在另一台机器上重做

前提：E2 已经做过（CubeSandbox 装着，闸门在，默认启动项固定）。

```bash
tools/vmrun.sh E3 01-host-kernel 01-host-kernel.sh EXPECT_SHA256=<GitHub 给出的摘要>
tools/vmrun.sh E3 02-reboot 02-reboot.sh ENTRY=e3-cube-pvm-host && tools/vmwait.sh E3 02-reboot
tools/vmrun.sh E3 03-after-boot 03-after-boot.sh
# 这里的次序与这一次不同，是改正过的：先启动 Docker，再加防火墙
ssh <机器> 'touch /run/e2-allow && systemctl start docker && rm /run/e2-allow'   # 只为让 DOCKER-USER 链出现；Docker 的闸门已经去掉的话不需要
tools/vmrun.sh E3 04-firewall 02-firewall.sh MODE=apply
tools/vmrun.sh E3 04-deadman 01-deadman.sh MODE=arm MINUTES=60
tools/vmrun.sh E3 05-start-cube 05-start-cube.sh
tools/portprobe.sh E3 05-portprobe 22 80 443 3000 9000 12088
tools/vmrun.sh E3 07-quickstart 09-quickstart.sh
tools/vmrun.sh E3 08-cycles 10-cycles.sh
tools/vmrun.sh E3 10-finish 10-finish.sh
tools/vmrun.sh E3 11-reboot 02-reboot.sh ENTRY=e0-pvm-139 && tools/vmwait.sh E3 11-reboot
```

要按机器改的：根分区的 UUID 和原有的启动参数由脚本从现成的菜单项里取，不用手填；上联网卡的名字在防火墙脚本里默认是 `eth0`，用 `UPLINK` 换。

## 9. 没有验证的

- Kata 在 CubeSandbox 的宿主内核上能不能用，E3 没有测。E4 里：直接启动 E1 用的 guest 内核会复位（没有经 Kata 再试）；Kata 换用 CubeSandbox 的 guest 内核之后，Dragonball 和 Cloud Hypervisor 起得了沙箱。见 `../E4/RECORD.md`。
- CubeSandbox 的暂停与恢复、并发创建、长时间运行、网络策略、出口代理、多节点。
- 照文档把它的内核设成默认启动项、让 `kvm_pvm` 开机加载。
- 它要求的那一串启动参数里哪些是这台机器上必需的。照抄了，没有逐个试。`ipv6.disable=1` 之后这台机器的 IPv6 地址不可用。E4 里只带 `nokaslr no5lvl` 也建了模板、十次循环全部成功；少掉的参数对时钟、性能、长时间运行的影响没有测。
- 第 5 节第 1 条那 38 秒里有没有外部连接。
- 第 7 节里进入和退出 CubeSandbox 状态的两段命令，各步都执行过，照现在写的次序整段没有再执行过。CubeSandbox 运行着时机器被重启之后怎样安全地恢复，没有演练过。
- 这些结果在别的 AMD 型号、别的云上是否一样。
