# 与上游 ios-polaris 的差异

对比时间 2026-10-20，基准为 `github.com/dipa-studio/ios-polaris` HEAD
`11da58b`（2026-10-19）。上游面向 polaris（Redmi Note 10 Pro，SM7150），
不支持 polaris。

## 已对齐

- CI 内核已包含上游 0072-0081 的功能：内核字符串里有 `POLARIS NET`、
  `polarisusb`、`ue0`、`polarislog`、`polarissample`、`POLARIS FB`、
  `PolarisHIDTouch`、`PolarisBattery`、`polaris_ufs`。
- `tools/mkiosroot.sh` 与上游内容完全一致。
- `tools/polaris-root-tweaks.py` 在本 kit 的激活改动之前与上游一致；
  上游只往已存在的容器里写种子，本 kit 还会创建容器（提交 `aabc9c7`）。
- ADT/payload 工具是同一套设计；本 kit 增加了 polaris 的 CPU 拓扑、
  DTB 尾部数据和 D22AP 的 `/product` 身份。

## 本 kit 缺少的部分

1. **本地编译内核。** 本 kit 已逐字节收录上游全部 84 个补丁文件
   （0001-0081），重编不再需要另拉上游仓库。但编译本身仍需要
   `blacktop/darwin-xnu-build`（固定 `6639065`）和 Xcode 15.x，
   所以 CI 内核和 ADT 仍是需要跟踪的产物。
2. **上游工具。** `tools/polaris-init.S`、`tools/polaris-log-pull.sh`、
   `tools/polaris-usbnet.sh`，以及 OrangeFox/adb 恢复模式拉日志的流程
   都还没有。本 kit 有 `polaris-log.py`／`polaris-crash.py` 解码器，
   但没有把日志取出来的手段。
3. **文档。** 上游的 `README.md`、`NOTES.md`、`AGENTS.md`、
   `docs/QEMU_TESTING.md` 都已按 polaris 改写进本 kit；上游原文存档在
   `docs/upstream/`，用于对照（其板级参数面向 polaris）。
4. **v15 根镜像附加项。** 上游 v15 增加了 USB 以太网的
   `preferences.plist`（ue0，192.168.7.2/24）。本 kit 的新镜像里没有，
   开机不需要。
5. **shim 的平台覆盖。** 上游 shim 同时探测 polaris；本 kit 的 shim 只支持
   polaris。这是有意为之。
6. **polaris 的触控与电量计。** 上游 0060 的触控后端只支持 Goodix
   GT9896 / Focaltech（SE `0xa84000`），而 polaris 是 Synaptics DSX
   S3330（`i2c@a98000`、地址 `0x20`、IRQ GPIO 125、reset GPIO 99），
   0063 的 Goodix 打包修正因此不适用。0062 的电池代码面向 PM6150 系列，
   polaris 是 PMI8998（`fg-gen3` + `smb2`，RPMh RSC 在 `0x179c0000`）。
   音量键已由 0084 适配，电源键沿用 PMIC PON，无需改动。

## 本 kit 的增补

- polaris 补丁为 `xnu/patches/0082`-`0086`：显示缩放、早期 framebuffer
  几何、PM8998 音量键、触控（Synaptics DSX）与电量计（PMI8998）的只读
  探针。编号放在 0081 之后，是因为补丁按文件名顺序应用，而它们要修改的
  文件由 0046/0058/0060/0062 创建。
- polaris 的 DTB 拼装，以及保留 D22AP `/product` 节点的 ADT。
- macOS 原生根镜像构建（`extra/build-root-macos.sh`：hdiutil、
  newfs_hfs、`-owners on`、原生 APFS/HFSX）和 `tools/raw2simg.py`。
- 按上游 v14 的镜像布局创建 `mobileactivationd` 系统容器和 data ark。

## 下一步

- 用带激活容器的镜像重建根分区、重刷 userdata，验证锁屏。
- 诊断方面：导入上游的拉日志工具，或者用 0077 的 USB 实时日志
  （`polarisusb=2` + `tools/polaris-usbnet.sh`）。
- 触控与电量计目前只有只读探针（`polaristouch=1` + `polarisbattery=1` +
  `polarispanel=1`）。先用日志确认 SE14 是否带 ABL 加载的 I2C 固件、
  哪个 wrapper1 RCG 在驱动它，以及 PMI8998 三个 FG 块里的 SOC/电压偏移，
  再写报文解析与电量上报。
- 8 核默认已启用；首次启动若在 PSCI 处 panic，说明 A75 簇上不了电，
  按 `cpus=5` → `cpus=6` → `cpus=8` 分步定位。
