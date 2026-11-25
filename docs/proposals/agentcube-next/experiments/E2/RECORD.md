# E2 操作记录：CubeSandbox 在现在的 PVM 宿主上（不换内核）

- 时间：2026-11-25，03:13 至 03:39（UTC）。
- 机器：同 E0、E1。宿主是 Ubuntu `6.8.0-139-generic` 加 `nokaslr`，PVM 项目 v0.1 的模块包。
- 计划：`PLAN.md`。批准：负责人 2026-11-25 要求继续验证，直到能回答 Kata 或 CubeSandbox 在这台 AMD 机器的 PVM 上是否可用。
- 结果：**不通过。CubeSandbox v0.8.0 在这个宿主上装得上、服务都起得来，但创建模板时 microVM 一启动就复位。** 同样的现象在另外两个 VMM 上也出现，所以不在它的 VMM。E2 自己的证据只到这里。E4 补了对照之后能说的是：启动参数相同的条件下，这个 guest 内核在 CubeSandbox 自己的宿主内核上起得来，在这个宿主上起不来；见 `../E4/RECORD.md`。它在自己的宿主内核上是可用的，见 `../E3/RECORD.md`。
- 这份记录写成之后由子代理复核，指出原先的归因说得比证据强：E2 和 E3 的宿主不只是内核不同，启动参数也不同（E3 关着五级页表）；而且缺一个“这两个 VMM 本来启动得了这个 guest 内核”的对照。下面第 1 节已经按这一点改过。

## 1. 结论

| 通过标准 | 结果 | 证据 |
|---|---|---|
| 1 安装成功，服务在运行，安装器自检通过 | 满足。132 秒；18 个单元在运行，0 个失败；`quickcheck` OK；选中的 guest 内核是 `vmlinux-pvm` | `log-06-install.txt`、`log-07-status.txt` |
| 2 从镜像创建模板 | **不满足。** 镜像拉取和根文件系统制作都完成，起 microVM 时失败：`expected: VsockServerReady, actual: VmShutdown` | `log-08-pvm-project-test.txt` |
| 3 到 5 | 没有走到 | — |
| 6 宿主内核日志没有错误特征 | 满足（没有任何与 KVM 有关的新行） | 同上 |

**失败的位置**（`log-08b-failure-evidence.txt`）：CubeSandbox 的 VMM 装载内核、建好设备、启动 vCPU，1 毫秒之内记下 `Shutdown because VmExit::Reset`。guest 的控制台没有任何输出，模板的构建日志目录没有生成，宿主内核日志没有新行。

**定位**（`log-08c-localize.txt`）：不经 CubeSandbox，也不经 Kata，用两个在 E1 里证明过能在这台宿主上工作的 VMM，分别直接启动两个 guest 内核：

| VMM | CubeSandbox 的 `vmlinux-pvm`（6.6.117，OpenCloudOS 的 PVM guest） | PVM 项目的 guest 内核（6.12.33，E1 编的） |
|---|---|---|
| 上游 Cloud Hypervisor v51.1 | 启动后约 8 毫秒 `VmExit::Reset`，反复如此；两个控制台都是空的 | 启动，控制台有 108 行；约 2 秒后由 guest 自己发起复位，反复如此。没有给它根盘，这大概是原因，但抓到的控制台输出在挂载根盘之前就断了，没有那一行可证 |
| Firecracker 1.17.0 | 43 毫秒内退出，`Unexpected exit reason on vcpu run: Shutdown`；控制台没有内核输出 | 启动，kata-agent 就绪 |
| CubeSandbox 自己的 VMM（v0.8.0，编在 shim 里） | 1 毫秒内 `VmExit::Reset`（就是上面的失败） | 没有测，见第 9 节 |

所以：同一个 guest 内核在三种 VMM 上都是一启动就复位，另一个 guest 内核在其中两种上正常。E2 的证据支持的是：**CubeSandbox 的 guest 内核在这个宿主（照当时的启动方式）上起不来，不是它的 VMM 的问题，也不是 AMD 上 PVM 跑不了**（E1 已经证明能跑）。

E2 的证据不支持再往下说。当时这个宿主只带 `nokaslr` 启动，五级页表开着；CubeSandbox 的文档要求的启动参数里有 `no5lvl`。而且这张表里没有一格显示“这两个 VMM 在别处启动得了这个 guest 内核”。这两处由 E4 补上：在同一个宿主上关掉五级页表，结果不变；启动参数不变、只换成 CubeSandbox 的宿主内核，两个 guest 内核的结果正好对调。合起来能说的是：**这两个宿主（内核连同它的 PVM 模块）和这两个 guest 内核只能按原配用，E2 与 E3 的差别不能用启动参数解释。** 换掉的是整个宿主内核，不只是 PVM 模块；每一边只测了一个版本。

仍然没有回答的：为什么只能按原配用；是 PVM 模块的差别，还是宿主内核别处的差别。按两边的仓库和文档，这是两套各自演进的 PVM（读到的，不是测到的）：宿主的模块来自 PVM 项目的 `pvm-6.6-host-oot` 分支，guest 内核来自腾讯维护的 OpenCloudOS 内核。是接口有差别，还是只在 AMD 上才表现出来，这里没有 Intel 的对照，分不出来。PVM 项目的发布说明称它的六个目标都通过了“完整的运行时和持久化模板测试”，它的测试次序里有 CubeSandbox；但它用的 CubeSandbox 是预先做好的一套运行时，不在它的仓库里，用的是哪个版本、哪个 guest 内核，读不到。

## 2. 环境与版本

| 项 | 版本 | 来源与核对 |
|---|---|---|
| CubeSandbox | v0.8.0 的一键安装包 `cube-sandbox-one-click-v0.8.0-amd64.tar.gz`，包内记的 commit `41748bb78d6384962b4e417ff9215720ea7472fd` | GitHub 的发布页；SHA-256 `06e0cce7…796ad3`，与 GitHub 对这个文件给出的摘要一致 |
| guest 内核 | 包里的 `vmlinux-pvm`：`6.6.117-opencloudos9.cubesandbox.pvm.guest-gbc75224fca7e`，SHA-256 `10c21b61…16e4a0` | 安装包 |
| 组件镜像 | cube-proxy、cube-egress、cube-lifecycle-manager、MinIO，来自 `cube-sandbox-int.tencentcloudcr.com` | 安装器默认 |
| 四个基础镜像 | CoreDNS 1.14.2、MySQL 8.0、Redis 7-alpine、OpenResty 1.21.4.1-6-alpine-fat | **来自 Docker Hub，不是安装器默认的仓库**，见第 5 节第 1 条。摘要在 `log-05-images.txt` |
| 模板用的镜像 | `docker.io/library/redis:7-alpine` | 同上的原因 |
| 宿主、PVM 项目的脚本、上游 Cloud Hypervisor、Firecracker | 同 E1 | E0、E1 |

## 3. 操作是怎样做的

与 E1 相同：`scripts/` 下的脚本由 `../tools/vmrun.sh` 执行，输出进 `log-<步骤>.txt`，执行记录进 `commands-as-run.txt`。另外两个工具：`../tools/vmwait.sh`（重启之后等机器回来）、`../tools/portprobe.sh`（从开发机探测端口）。执行器每次都新开 ssh 连接，所以每一步能执行本身就说明 ssh 还通。

`scripts/` 里的 `09-quickstart.sh` 和 `10-cycles.sh` 在 E2 里没有执行过（没有走到），它们是在 E3 里执行并改好的，这里放的是改好之后的副本。`02-firewall.sh` 现在放的是 E3 那次意外之后改过的版本（`DOCKER-USER` 链不存在时报错并以 3 退出）；E2 里执行的是改之前的，它的 SHA-256 在 `commands-as-run.txt` 里。

## 4. 时间线与观察

| 时间 | 步骤 | 做什么 | 结果 |
|---|---|---|---|
| 03:13:41 | 00 | 只读：安装器会碰到什么 | 三件事：要 XFS；默认的基础镜像仓库连不上；没有 compose |
| 03:19:03 | 03 | 稀疏文件里的 XFS（120 GB），loop 挂到 `/data/cubelet` | 通过 |
| 03:19:09 | 04 | 下载安装包，核对，解开，不安装 | 通过 |
| 03:19:39 | 05 | 四个基础镜像：原地址都失败，从 Docker Hub 拉并改名 | 通过 |
| 03:25:59 | 01a | 装开机闸门 | 通过 |
| 03:26:12 | 01b | 默认启动项按 ID 固定到 `6.8.0-149` | 通过；`grub.cfg` 只有选默认项的那一行变了 |
| 03:26:24 至 03:28:09 | 01c、01d | **演练：普通重启** | 回到 `6.8.0-149`；Docker 没有自己启动；监听的只有 ssh |
| 03:28:21 至 03:29:59 | 01c、01d | 一次性启动回 PVM 宿主；加载模块，挂 XFS，放行 | 通过 |
| 03:30:16 | 01 | 上保险（45 分钟） | 通过 |
| 03:30:21 | 02 | 防火墙 | 通过 |
| 03:30:27 | 01 | 续保险（60 分钟） | 通过 |
| 03:30:40 | 06 | `CUBE_PVM_ENABLE=1 ./install.sh` | 通过，132 秒 |
| 03:33:21 | 01 | 续保险 | 通过 |
| 03:33:27 | 07 | 只读：状态 | 18 个单元在运行；监听的端口见下 |
| 03:33:42 | 07 | 从开发机探测 19 个端口 | 只有 22 是通的 |
| 03:35:12 | 01a | 只读：闸门盖住了哪些单元 | CubeSandbox 的 22 个单元和 Docker 的两个，全部盖住 |
| 03:35:25 | 08 | PVM 项目的 CubeSandbox 测试 | **不通过**，6 秒 |
| 03:35:58 | 08b | 只读：VMM、shim、Cubelet、宿主内核的日志 | 见第 1 节 |
| 03:37:50 | 08c | 定位：两个 guest 内核乘两个 VMM | 见第 1 节 |

之后没有在 E2 里收尾，直接进了 E3（03:42）。保险当时还上着（到 04:33），随 E3 的重启消失。

**安装器在这台机器上做了什么**（`log-06-install.txt`、`log-07-status.txt`、`../E3/log-13-state.txt`）：

- 用 apt 装了 `docker-compose` 和 `s3fs`。
- 装了 22 个 systemd 单元，其中 `cube-sandbox-control.target`、`cube-sandbox-cube-templatecenter.service`、`cube-sandbox-logrotate.timer` 是开机自启的。
- 起了 8 个 Docker 容器，6 个带 `unless-stopped` 的重启策略。
- 在 `eth0` 上加了 `clsact` 队列和一个 eBPF 过滤器（`from_world`）；建了 `cube-dev` 和约 500 个预留的网络设备；路由表里多了 `192.168.0.0/18`。
- 建了 `cube-dns0`，让 `cube.app` 这个域走本地的 CoreDNS；别的域名解析不受影响。
- 打开了 IPv4 转发。
- 监听在回环以外的端口：80、443、3000（API）、3010、8080、8082、8083、8089、8443、8890、9000（MinIO）、9090、9966、9998、9999、12088（管理界面）、53。
- 在 `/usr/local/bin` 放了 `cube-runtime`、`containerd-shim-cube-rs`、`cubecli`、`cubevsmapdump`、`cubemastercli`、`cubeopscli`、`mkcert`。

## 5. 与计划不一致的地方，和过程中的意外

1. **四个基础镜像来自 Docker Hub。** 安装器默认从 `cube-sandbox-image.tencentcloudcr.com` 拉 CoreDNS、MySQL、Redis、OpenResty，这个地址从这台机器连不上（`cube-sandbox-cn` 也连不上，`cube-sandbox-int` 连得上）。做法是从 Docker Hub 拉同名同版本的官方镜像，打上安装器要的名字；安装器会用本地已有的镜像。两边的镜像是否逐字节相同没有核对。这四个都是外围组件，与 microVM 起不起得来无关。
2. **计划在安全评审之后重写了安全部分**，在装闸门、上防火墙、安装这些动作之前。评审的发现和逐条处理在 本子任务的实施提案（内部文档） 第 5.3 节。评审回来之前做了三步不影响连通的事（XFS、下载、镜像）。
3. **默认启动项的写法改了。** E0 留下的是 `GRUB_DEFAULT=0`，靠“第 0 项是 `6.8.0-149`”。现在按菜单项的 ID 固定。`/etc/default/grub` 因此改了一行，原件在虚拟机的 `/root/exp/E2/default-grub.before-pin`。
4. **E0 留下的退路这一次实际走了一遍。** 普通重启回到了 `6.8.0-149`。E0 的记录里这一条原先只是从配置读出来的。
5. **PVM 项目的测试脚本改了两个环境变量**：CubeSandbox 的环境文件的位置，和模板用的镜像（原因同第 1 条）。脚本本身没有改。
6. **保险没有触发过**（`../E3/log-13-state.txt`）。
7. **计划里的对照没有全做。** 第 1 节那张表右下角的一格（CubeSandbox 的 VMM 配 PVM 项目的 guest 内核）没有测。它的 VMM 编在 shim 里，不能单独运行；它启动 microVM 用的内核是每个模板产物目录下的一个文件，来自一个带摘要校验的版本库，换掉它要改动安装好的内容。时间用在了 E3 上。
8. **`01d-after-boot.sh` 的第一版把 `127.0.0.53` 上的本地解析器列进了“回环以外的监听”**（`log-01d-drill-on-default.txt`）。是脚本里的正则没有处理 `%lo` 后缀，之后改了；`00-preflight.sh` 里也有同样的显示。那几行不是对外的监听。第一版的脚本没有留下，只有 SHA-256。
9. **计划的修订记录里第二条写的时间是 03:25**，装闸门是 03:25:59。修订是在那之前几分钟里写的，没有更精确的时间。

## 6. 对虚拟机的改动，和怎样撤销

E2 和 E3 的改动合在一起记在 `../E3/RECORD.md` 第 6 节，因为 E3 接着 E2 做，收尾也在 E3 里。这里只列 E2 引入、到现在还在的：

| 改动 | 位置 | 怎样撤销 |
|---|---|---|
| CubeSandbox v0.8.0 | `/usr/local/services/cubetoolbox`（1.2 GB）、`/etc/cube`、`/etc/cube-sandbox`、`/data/log`、22 个 systemd 单元、`/usr/local/bin` 下 7 个命令、`/root/.local/share/mkcert` | 它自带的卸载脚本：`/usr/local/services/cubetoolbox/scripts/one-click/uninstall.sh`，再 `uninstall.sh check`。要先放行并挂上 XFS |
| 开机闸门 | `/etc/systemd/system/cube-sandbox-.service.d/`、`cube-sandbox-.target.d/`、`cube-sandbox-.timer.d/` 下的 `10-e2-guard.conf` | 删掉这三个文件，`systemctl daemon-reload`。**删掉之后 CubeSandbox 会开机自启** |
| 默认启动项按 ID 固定 | `/etc/default/grub` 的 `GRUB_DEFAULT` | 换回 `/root/exp/E2/default-grub.before-pin`，`update-grub` |
| XFS 的稀疏文件 | `/var/lib/e2/cubelet.xfs`（名义 120 GB；E2 结束时实占约 750 MB，E4 之后约 1.0 GiB）；挂载点 `/data/cubelet` | 卸载之后删除 |
| 安装包 | `/root/e2/`（682 MB，含 uv 和 SDK 的虚拟环境） | 删除 |
| apt 装的包 | `docker-compose`、`s3fs` 及依赖 | `apt-get purge` |
| Docker 镜像 | 四个基础镜像（各有两个名字）和四个组件镜像 | `docker rmi` |
| 保险的动作脚本 | `/root/exp/E2/deadman-action.sh` | 删除；没有定时器指向它 |

已经不在的：防火墙规则、保险的定时器、`eth0` 上的 eBPF 过滤器和 `clsact`、`cube-dns0` 和 `cube.app` 的解析、那约 500 个网络设备。它们都随 E3 的重启消失了，核对见 `../E3/log-13-state.txt`。

## 7. 虚拟机的状态

见 `../E3/RECORD.md` 第 7 节。

## 8. 在另一台机器上重做

要重做的是“定位”这一段，它不需要安装 CubeSandbox 的全部服务：有 E1 的环境，再把 CubeSandbox 安装包里的 `vmlinux-pvm` 取出来，改一下 `08c-localize.sh` 里的路径就能跑。它在几十秒内回答“这个 guest 内核在这个宿主的 PVM 上起不起得来”。

要重做整个 E2，次序照第 4 节的表。安全上的三样（闸门、固定默认启动项并演练、保险）和防火墙要在安装之前做完。镜像的替换只在连不上默认仓库时需要。

## 9. 没有验证的

- CubeSandbox 的 VMM 配 PVM 项目的 guest 内核（第 5 节第 7 条）。所以“把 CubeSandbox 的 guest 内核换掉就能在这种宿主上用”只是推测。
- E2 当时没有试它文档要求的宿主启动参数，也没有对照。E4 补了对照，并在这个宿主上试了其中的 `no5lvl`；文档的整串参数在这个宿主上始终没有试过。
- 只能按原配用的原因，以及它在 Intel 的机器上会不会出现。
- 更新的 PVM 模块包或更新的 CubeSandbox 版本。
- 沙箱端口经 eBPF 映射到宿主端口这条路在防火墙之外（计划里写明接受）；E2 里没有建成任何沙箱，所以这条路没有被用到。
