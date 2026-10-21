# polaris-ios-kit

**在小米 MIX 2S 上跑 Apple 的 iOS 16。**

把 Apple 开源的 XNU 内核（xnu-8796，iOS 16 同代）移植到小米 MIX 2S
（`polaris`，Qualcomm SDM845 / 骁龙 845），上面跑**未修改的 iPhone X
iOS 16.7.16（20H392）用户态**：launchd、各系统守护进程、backboardd、
SpringBoard 和原生 App。

本项目是 [dipa-studio/ios-polaris](https://github.com/dipa-studio/ios-polaris)
（Redmi Note 10 Pro / `polaris` / SM7150）的 polaris 移植分支：沿用上游的
shim、ADT/payload 工具链和 0001-0081 内核补丁，polaris 的差异集中在
`xnu/patches/0082`-`0088`。

> 实验性移植，不是可用的手机系统。很多功能缺失或只有桩实现，Apple 的
> 安全模型基本是关掉的。它装在 `userdata` 分区，**会清除 Android 的
> 用户数据**。

## 当前状态（2026-10-20）

| 领域 | 状态 |
| --- | --- |
| 启动 | 原生小米 bootloader（已解锁）→ `fastboot boot` 我们的 shim → XNU。boot 分区不落盘 |
| CPU | 8 个核（`cpus=8`）：4×A55 + 4×A75，经 PSCI 启动，16K 页，GICv3，通用定时器 |
| 内存 | 上段 DDR，6GB 机型约 1.9 GiB 可用（ADT `--ram 6`） |
| 存储 | 自带 UFS host 驱动；iOS 根是 `userdata` 里的日志式 HFS+ 卷，可读写 |
| iOS 用户态 | 真机 iPhone X 16.7.16 根文件系统与共享缓存；launchd 与系统守护进程可运行 |
| 显示 | 内核 IOSurface + IOMobileFramebuffer（`AppleCLCD`）；CoreAnimation 纯软件渲染；对 iOS 报告 iPhone X 的 1125×2436，**按高度缩放成 998×2160 居中显示在 1080×2160 面板上，两侧各 41px 黑边** |
| 图形界面 | backboardd、SpringBoard、锁屏、桌面、控制中心、通知中心、设置 |
| 触摸 | Synaptics DSX S3330（`i2c@a98000`）驱动已写好（`0087`），**未实机验证**；需要 `polaristouch=1` |
| 按键 | 电源/音量下走 PM8998 PON；音量上是 PM8998 GPIO6，`0084` 已适配，**待实机验证** |
| 电池 | 静态 100% / 充电图标。真电量计是 PMI8998 `fg-gen3`，目前只有只读探针（`0086`） |
| 设备身份 | iPhone X（`iPhone10,3` / `D22AP`）：无 Home 键，手势 UI |
| 激活 | mobileactivationd 的原生 "Hactivation" 路径，由设备树里的安全状态决定，不连 Apple 服务器 |

## 还不能用的部分

- **没有 Wi-Fi、蓝牙、蜂窝、音频、摄像头、传感器、GPS、SEP / Face ID。**
  对应守护进程会启动后失败或反复重启。
- **没有 GPU。** 全部靠 CPU 绘制，约 20–30 fps。8 核的 A75 簇未启用。
- **App 很少。** 镜像只有系统卷里的内容，没有 App Store、没有 Apple ID，
  部分设置页面是空的。
- **安全全关**：AMFI 代码签名与沙箱策略宽松，AppleKeyStore 是桩，无数据
  保护。不要放任何私人数据。

## 启动链路

```
ABL（原生小米 bootloader，已解锁）
  -> fastboot boot out/shim-polaris-xnu.img     （临时，不写 boot 分区）
     -> shim：自建 MMU，读实时 FDT，从 ramdisk 里加载 payload
        -> XNU Mach-O + 生成的 Apple Device Tree（ADT）+ boot-args
           -> XNU -> UFS 驱动 -> userdata 里的 HFS+ 根
              -> dyld + 共享缓存 -> launchd -> 守护进程 -> backboardd + SpringBoard
```

polaris 没有可用串口（调试 UART 在这块板子上没接出来）。内核把控制台画进
ABL 留下的 `0x9d400000` 帧缓冲，并在 `userdata` 末尾维护 4 MiB 持久日志环。
上游用 OrangeFox 拉日志（`tools/polaris-log-pull.sh`）；本 kit 没带这套工具，
读日志靠 0077 的 USB 实时日志（见下）。

## 自己动手

需要一台**已解锁**的小米 MIX 2S（`polaris`，SDM845）、一台 Linux 或 macOS
主机，以及一个 GitHub 账号（内核构建走 CI）。**`userdata` 上的内容会全部
丢失。** bootloader、recovery、modem、persist 分区不会被碰。

### 0. 备份

临时进 OrangeFox（或任何带 adb root 的 recovery），至少拉出 `persist`、
`modemst1`、`modemst2`、`fsg`、`fsc`、`boot`、`dtbo`、`vbmeta`，里面是
逐机的校准数据。**不要提交进 git**；`.gitignore` 已排除 `backup/`、`dtb/`、
`recovery/` 和根镜像。

shim 需要 stock DTB。本 kit 的 `dtb/polaris_stock/` 已带 Mi MIX 2S 的
14 个 stock DTB（`dtb_00.dtb` 是主板那份）。换机型或换固件要重新拆
`boot.img`。

### 1. 构建内核

内核在 GitHub 的 macOS runner 上用
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build)
构建：拉 xnu-8796，按文件名顺序应用 `xnu/patches/`，并预置固定版本的
libpthread、HFS、BearSSL 源码。fork 上游仓库（公开仓库有免费 macOS
额度）然后：

```sh
gh workflow run xnu.yml -R YOU/ios-polaris
gh run download RUN_ID -R YOU/ios-polaris -n xnu-kernel -D xnu/out
```

本 kit 已经逐字节收录全部 84 个上游补丁文件，本地复现不再需要另拉上游，
但仍需 `darwin-xnu-build`（固定 `6639065`）和 **Xcode 15.x**
（Xcode 16 的 `iig` 会生成 `IORPC.kernelContent`，xnu-8796 没有这个字段；
另外 SDK 也要 14.x）。用 `tools/xnu-cc.py` 可以在花掉一次 CI 之前本地
验证单个文件的编译。

本地构建对宿主系统有硬性要求：**Xcode 15.4 只能跑在 macOS 14.x 上，
14.3.1 只能跑在 13.x 上**，在 macOS 15 上会被系统拒绝启动。版本矩阵、
依赖清单（不需要 Homebrew）和本地构建步骤见
[`docs/KERNEL-BUILD.md`](docs/KERNEL-BUILD.md)。

### 2. 构建 iOS 根镜像

从 Apple 下载 iPhone X（iPhone10,3）iOS 16.7.16（20H392）的 IPSW。
在 Linux 上（`apfs-fuse`、`hfsprogs`、sudo）：

```sh
# IPSW 里的 OS / SystemOS / AppOS 磁盘映像（名字见 BuildManifest.plist）
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/polaris-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
```

`mkiosroot.sh` 把 OS 卷和两个 cryptex 合成一个区分大小写的日志式 HFS+ 卷，
并补上 dyld 缓存链接、明文系统 keybag 和守护进程需要的日志目录。
`polaris-root-tweaks.py` 做适配改动：跳过 Setup、写入激活状态、移除基带
守护进程、关掉会杀掉慢 App 的 watchdog 和崩溃循环的媒体路径等，脚本头部
逐条说明。

DMG 角色（`BuildManifest`）：

| 角色 | 文件 |
| --- | --- |
| OS | `087-86698-044.dmg` |
| SystemOS | `087-86593-047.dmg` |
| AppOS | `087-86715-047.dmg` |

macOS 原生构建（不需要 WSL）：`sudo extra/build-root-macos.sh`。IPSW 默认
放 `build-root/iphonex-16.7.16.ipsw`；工作目录用 `BUILD=/path` 或
`WORK=/path` 覆盖，`IPSW=/path` 可单独指定。所有脚本与工具按仓库相对定位。

WSL 路线：用 `extra/bzImage` 替换 WSL 内核（含 hfsplus），装
`apfs-fuse`、`hfsprogs`、`rsync`、`android-sdk-libsparse-utils`，然后跑
`extra/build-root.sh`。注意 `mkiosroot.sh` 需要 LF 行尾
（`sed -i 's/\r$//'`）。

### 3. 构建 boot 镜像

需要 `aarch64-linux-gnu-gcc`（或 zig）和 `mkbootimg`。

```sh
./extra/package-boot.sh
```

它依次做：检查内核版本串 → 拷回 `xnu/out/kernel.development.polaris` →
生成 payload → 打包 `out/shim-polaris-xnu.img` → 打印大小和 SHA256。默认
`cpus=8 polarispanel=1 polaristouch=1 polarisbattery=1 polarisfb_hz=60`，
可以覆盖：

```sh
./extra/package-boot.sh --cpus 4 --touch 0     # 只起 A55、不加载触控
./extra/package-boot.sh --kernel PATH --zig /path/to/zig
```

**不要手写那段 `--cmdline`**：单引号里的 `\` 换行会被当成字面反斜杠塞进
启动参数（内核会多收到一个 `\` token）。脚本里用的是双引号续行，拼接结果
是干净的。

本 kit 的 ADT 是**外部输入**（`xnu/out/polaris.adt`，已补上 iPhone X 的
`/product` 节点），本地无法重生成。payload 丢了用上面的命令重建（与旧
payload 字节一致）。

`--cmdline` 里不太直观的几个：

| boot-arg | 作用 |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | 根在 `userdata` 上，可读写 |
| `cpus=8` | 8 个核全开（ADT 里 0-3 是 A55、4-7 是 A75）。`cpus=4` 只起 A55，`cpus=1` 是最保守的回退 |
| `polarispanel=1` | polaris 板型开关：显示缩放、音量键、触控/电量计探针都看它 |
| `polarisfb_hz=60` | 面板 CPU 拷贝的刷新率，与 60Hz 面板对齐 |
| `polarisfb_noconsole=1` | 不再把内核文字画在 GUI 上；仍写持久日志，panic 照画 |
| `polaristouch=0` `polariskeys=0` | 关掉触控/按键驱动。**这是有意为之**：上游驱动面向 PM6150L/GT9896，会写错 polaris 的 PMIC/I2C 地址 |
| `launchd_unsecure_cache=1` | 无 AMFI 时 launchd 接受它的 job 缓存 |
| `wdt=-1 wdt_test=no_user_checkin` | 关硬件看门狗 |

### 4. 刷根镜像并启动

```sh
fastboot -S 512M flash userdata ios16-root.simg   # 约 7 分钟，别拔线
# 小米的 fastboot 刷完大分区常会卡住：按电源 + 音量下重新进 fastboot
fastboot boot out/shim-polaris-xnu.img
```

首次启动在 Apple logo 停 5–10 分钟，然后出现锁屏。上滑解锁。想回 fastboot：
按住电源 10 秒硬复位，再按住音量下。

### 5. 看内核日志

polaris 上最实用的是 0077 的 USB 实时日志：

```sh
# 启动参数加 polarisusb=2，然后用上游的 tools/polaris-usbnet.sh 取（本 kit 未带）
```

或者接一个能读 `userdata` 末尾日志环的环境（上游的 OrangeFox + `adb root`
流程）。日志里有带回溯的崩溃报告（`CRASH name ...`）、backboardd 和
SpringBoard 的 IOKit trace，以及各驱动的 `POLARIS ...` 行。
`tools/polaris-crash.py` 可以对着共享缓存做符号化。

### QEMU

`tools/qemu-polaris.py` 能在 QEMU `virt` 上跑同一个内核（内存根）。
注意它用的是 **`--qemu` 生成的 ADT**：单核、GIC 在 virt 地址、帧缓冲是
polaris 的 `0x9c000000` / 1080×2400，**验证不了 polaris 的显示与板级驱动**。
细节见 [`docs/QEMU_TESTING.md`](docs/QEMU_TESTING.md)。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `shim/` | 裸机引导 shim（C + 汇编），打成 Android boot.img v2 |
| `xnu/patches/` | 内核补丁序列（CI 按文件名顺序应用），含 libpthread/HFS/BearSSL 的预置脚本 |
| `xnu/out/` | 需跟踪的输入：CI 内核 `kernel.development.polaris` 与 `polaris.adt` |
| `dtb/polaris_stock/` | Mi MIX 2S 的 stock DTB（shim 与 ADT 的事实来源） |
| `tools/mkadt.py` | 从 polaris 的 MMIO 布局和 iPhone X 身份生成 ADT |
| `tools/mkpayload.py` | 把内核 + ADT + boot-args 打成 shim payload |
| `tools/mkiosroot.sh` | 从 IPSW 映像构建 HFS+ iOS 根 |
| `tools/polaris-root-tweaks.py` | 根镜像的适配改动（跳过 Setup、激活、守护进程） |
| `tools/polaris-log.py`, `polaris-crash.py` | 解码持久日志 / 符号化崩溃报告 |
| `tools/xnu-cc.py` | 从 CI 日志回放单文件编译 |
| `tools/qemu-polaris.py` | QEMU 测试启动，带帧缓冲文字解码 |
| `tools/raw2simg.py` | 原始镜像转 Android sparse |
| `extra/` | `build-root.sh`（Linux/WSL）、`build-root-macos.sh`（macOS 原生）、`apfs-fuse/`、`bzImage` |
| `docs/` | [`KERNEL-BUILD.md`](docs/KERNEL-BUILD.md)（CI 与本地构建、Xcode 版本矩阵）、[`UPSTREAM-GAP.md`](docs/UPSTREAM-GAP.md)（与上游的差异）、[`QEMU_TESTING.md`](docs/QEMU_TESTING.md)、`upstream/`（上游原文存档） |
| `NOTES.md` | 工程笔记：polaris 的硬件事实、验证结果、未完成项 |
| `AGENTS.md` | 协作约定 |

不在 git 里：分区备份、实时设备树、recovery 镜像、Apple 固件与根镜像、
下载或生成的构建树。它们要么含设备序列号/校准数据，要么是 Apple 的
版权文件。

## 内核补丁

| # | 内容 |
| --- | --- |
| 0001–0009 | 工具链兼容、POLARIS 机器配置、非 PAC arm64、Apple 内部件打桩 |
| 0010–0018 | 早期帧缓冲控制台、physmap 修正、无 corecrypto 的 PRNG、设备树平台专家、定时器 PPI、启动 CPU 驱动 |
| 0019–0020 | Apple 开源 libpthread 的内核版；BearSSL AES |
| 0021–0027 | RAM 盘根、mockfs、SHA-256、最小 AMFI、Apple 开源 HFS+、MD5 |
| 0028–0034 | UFS host 驱动与根设备、根可读写、4 GiB 以上 DMA |
| 0035–0045 | entitlement、bindfs、AppleKeyStore 桩、IOWatchdog、控制台崩溃报告 |
| 0046 | IOSurface（IOCoreSurfaceRoot）与 IOMobileFramebuffer（AppleCLCD）服务 |
| 0047–0055 | 诊断：持久日志、`/dev/null` 转发、IOKit trace、崩溃堆字符串与用户栈采样；宽松沙箱策略；HFS rename-swap；AppleKeyStore 选择子 |
| 0056–0057 | 面板拷贝节流；关掉外部身份解析 |
| 0058 | HID 事件服务。Apple IOHIDFamily-1915.140.3 的 user client 与事件队列，匹配 iOS 16.7 用户态 |
| 0059 | iPhone X 身份（`hw.product` / `hw.target` 来自设备树） |
| 0060 | 电源/音量键走 SPMI；触控走 GENI I²C |
| 0061 | 把显示报告成 1125×2436 |
| 0062 | 触控电源轨的 RPMh 投票；电池 power source |
| 0063 | GENI FIFO 打包修正与 Goodix GT9896 协议 |
| 0064 | 授予 `PRIV_WORK_INTERVAL`（UIKit 的 CoreAnimation work interval） |
| 0065 | SMP：从核经 PSCI `CPU_ON` 启动 |
| 0066–0067 | 崩溃 fault region 信息；控制台静音 |
| 0068 | 已映射 IOSurface 的查找语义 |
| 0069 | 持久日志批量刷写 |
| 0070–0071 | `pid_hibernate` 桩；触控边缘 |
| 0072–0077 | USB：探测、device EP0、VBUS、ECM（`ue0`）、RX mbuf、实时日志 |
| 0078–0081 | 8 核、显示电源、网络 trace、USB link state |
| **0082** | **polaris 显示缩放**：1125×2436 按高度缩成 998×2160，两侧 41px 黑边；取样改为四舍五入 + 两行混合 |
| **0083** | **polaris 早期帧缓冲**：几何取自 `boot_args`，替代写死的 `0x9c000000`/2400；补上 32MB L2 块的边界断言 |
| **0084** | **polaris 按键**：音量上改读 PM8998 GPIO6（SPMI SID 0），电源键沿用 PON |
| **0085** | **polaris 触控探针**（只读）：SE14/GCC/TLMM 状态与 DSX 识别 |
| **0086** | **polaris 电量计探针**（只读）：放宽 SPMI 白名单到 PMI8998 SID 2，dump 三个 FG 块 |
| **0087** | **polaris 触控驱动**：Synaptics DSX S3330，RMI4 over I²C，PDT 枚举 F01/F12，8ms 轮询上报 |
| **0088** | **8 核降级**：`CPU_ON` 失败或超时改为跳过并计数，不再 panic |

## 关键硬件事实

以下均从 `dtb/polaris_stock/fdt/dtb_00.dtb` 与 `shim/` 实测得到。

- **RAM**：payload 用上段 DDR，`0x1_00000000` 起。6GB 机型到
  `0x1_80000000` 为止，扣掉顶部保留后 ADT 取 `0x7cc00000`（`--ram 6`，
  6/8GB 都安全）；8GB 机型可用 `--ram 8`。
- **GICv3**（`interrupt-controller@17a00000`）：定时器走 Group 1 IRQ
  （虚拟定时器 INTID 19），不是 Apple 芯片上的 FIQ。
- **PSCI**：`/psci` = `arm,psci-1.0`，`method = "smc"`；19.2 MHz 定时器；
  ARMv8.2、无指针认证。MPIDR 的 Aff1 是核序号（`0x000`–`0x700`）。
- **CPU**：8 核，`cpu@0`–`cpu@300`（A55，`capacity-dmips-mhz` 1024）+
  `cpu@400`–`cpu@700`（A75，1740），`enable-method = "psci"`。
- **面板**：1080×2160，stride 4320，splash 区在 `0x9d400000`（ADT 声明
  0x2400000 = 36 MiB，实际缓冲 8.9MB），ABL 连续 splash，无需 refresh kick。
- **UFS**：`ufshc@1d84000`（reg `0x1d84000`+`0x1d90000`，IRQ 0x109），
  与 polaris 同址，0028 可直接用。
- **PMIC**：PM8998 在 SPMI SID 0（PON `0x800`、GPIO `0xc000`，26 个 GPIO），
  PMI8998 在 SID 2（`qpnp,fg` = fg-gen3、`qpnp-smb2`）。SPMI arbiter
  `0xc440000`（observer `0xe600000`、cfg `0xc40a000`）。
- **RPMh**：`qcom,rpmh-rsc` 在 `0x179c0000`（三个 bank：
  `0x179c0000/0x179d0000/0x179e0000`）。注意上游 0062 写的是 SM7150 的
  `0x18220000`。
- **看门狗**：`qcom,wdt@17980000`。0040 是纯桩，不碰硬件，无需改动。
- **触控**：Synaptics DSX **S3330**（in-cell，固件名
  `synaptics_jdi_3330_d5x.fw`），在 `i2c@a98000`（`qupv3_se14`）上，
  地址 `0x20`（ub `0x2c`），IRQ = TLMM gpio125（flags `0x2008`），
  reset = gpio99，SDA/SCL = gpio33/gpio34（mux `qup14`）。
- **按键**：电源键与音量下在 PM8998 PON；音量上是 PM8998 GPIO6
  （input + pull-up，低电平有效）；另有 hall_key 在 TLMM gpio124。

  注意 DTB 里 `gpios` 的第一个 cell 是**控制器 phandle**，不是引脚号：
  `vol_up` 的 `0x46` 是 `pm8998@0/pinctrl@c000`，`hall_key` 和触控 IRQ 的
  `0x36` 是 `pinctrl@03400000`（TLMM）。

更细的推导见 [`NOTES.md`](NOTES.md)。

## 致谢

建立在 Apple 的开源发布（xnu、IOHIDFamily、libpthread、hfs）、
[BearSSL](https://bearssl.org)、
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build)、
[ipsw](https://github.com/blacktop/ipsw)、Qualcomm/小米公开的 Linux 内核源码
（硬件细节）以及 [OrangeFox Recovery](https://orangefox.download) 之上。
iOS 本身是 Apple 的，不随本项目分发。
