# 构建内核

有两种方式拿到 `kernel.development.polaris`：GitHub CI（推荐）和本地构建。
本地构建对宿主环境有硬性要求，先看表。

## 版本兼容矩阵

| 宿主 macOS | Xcode | 结果 |
| --- | --- | --- |
| 15.x Sequoia | 16.x | **不可行**。`iig` 生成 `IORPC.kernelContent`，xnu-8796 没有这个字段；带的还是 macOS 15 SDK |
| 15.x Sequoia | 15.4 | **不可行**。启动时被系统拒绝（实测报错：版本不兼容 macOS Sequoia） |
| 15.x Sequoia | 14.3.1 | **不可行**。同上，且与支持范围差两个大版本 |
| 14.x Sonoma | 15.4 | **可行**，与上游 CI 一致（macos-14 runner） |
| 13.x Ventura | 14.3.1 | **可行**，工具链最贴近 xnu-8796（13.5 配套 Xcode 14.3.1，SDK 13.3） |

Xcode 的兼容性由系统在启动时校验，不能靠改 `Info.plist` 绕过。即使绕过，
构建过程里那些 Apple 开源组件（`mig`、`ctfconvert`、`dtrace`）的
`xcodebuild` 调用也不保证在不支持的宿主上正确。

`MACOS_VERSION=13.5` 指的是**要编译的 xnu 源码版本**（xnu-8796），不是宿主
系统，也不是 SDK 版本。

## 路线 A：GitHub CI（推荐）

macOS runner 预装 Xcode 15.x，正好在支持矩阵里。fork 上游仓库（公开仓库
有免费 macOS 额度）把自己的补丁推上去。

### 1. fork 并把 polaris 补丁放进去

```sh
git clone https://github.com/YOU/ios-polaris
cp /path/to/polaris-ios-kit/xnu/patches/0084-*.patch \
   /path/to/polaris-ios-kit/xnu/patches/0085-*.patch \
   /path/to/polaris-ios-kit/xnu/patches/0086-*.patch \
   ios-polaris/xnu/patches/
git -C ios-polaris add xnu/patches
git -C ios-polaris commit -m "polaris: add keys, touch and battery patches"
git -C ios-polaris push
```

上游 `xnu.yml` 在 push 到 `main` 且改动命中 `xnu/patches/**` 时会自动跑，
也可以手动触发。

### 2. 触发并下载

```sh
gh workflow run xnu.yml -R YOU/ios-polaris \
    -f macos_version=13.5 -f kernel_config=DEVELOPMENT -f machine_config=POLARIS
gh run watch -R YOU/ios-polaris
gh run download -R YOU/ios-polaris -n xnu-kernel -D xnu/out
```

单次约 20 分钟。产物就是 `kernel.development.polaris`。

### 3. 重建 payload 并刷机

```sh
./extra/package-boot.sh
fastboot boot out/shim-polaris-xnu.img
```

脚本负责拷内核、生成 payload、打包镜像、打印 SHA256；默认
`cpus=8 polarispanel=1 polaristouch=1 polarisbattery=1 polarisfb_hz=60`，
`--cpus 4`、`--touch 0` 可以覆盖。别手写 `--cmdline '... \` 那种续行——
单引号里的反斜杠会原样进启动参数。

`polaristouch=1` 和 `polarisbattery=1` 只在 0085/0086 编进内核后才有意义，
它们会分别打印 `POLARIS TOUCH: polaris ...` 和
`POLARIS BATTERY: polaris PMI8998 ...` 的只读探针日志。

## 路线 B：本地构建

需要满足两个条件之一：**macOS 14.x + Xcode 15.4**，或
**macOS 13.x + Xcode 14.3.1**。在 15.x 上没有任何 Xcode 组合可用。

做法：用「磁盘工具」新建一个 APFS 卷（或外接 SSD）装 macOS 14.7，从那个
卷启动，在它里面装 Xcode 15.4。预算约 30 GB 磁盘、1–2 小时。

### 依赖（不需要 Homebrew）

Homebrew 的官方安装脚本已拒绝 Intel Mac
（`Homebrew on macOS is only supported on Apple Silicon processors`）。
`darwin-xnu-build` 的依赖检查只要求这五个命令存在，其中只有 `jq` 真正被调用：

```sh
sudo mkdir -p /usr/local/bin

# jq：真实需要（解析 release.json 和 KDK manifest）
curl -fsSL -o /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64
chmod +x /tmp/jq && sudo install -m 755 /tmp/jq /usr/local/bin/jq

# gum / xcodes / cmake / ninja：只出现在存在性检查里（cmake、ninja 全文无调用；
# gum 只驱动交互式版本菜单；xcodes 只用于自动下载 Xcode）
for c in gum xcodes cmake ninja; do
    printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/local/bin/$c >/dev/null
    sudo chmod 755 /usr/local/bin/$c
done
```

必须装进 `/usr/local/bin`：`build.sh` 会重写 `PATH`，只保留 Xcode 工具链、
`/usr/bin:/bin:/usr/sbin:/sbin`，最后才附上 `/usr/local/bin`。

### 构建

```sh
export DEVELOPER_DIR=/Applications/Xcode_15.4.app/Contents/Developer
xcrun --find iig              # 必须指向 Xcode_15.4
xcrun --show-sdk-version      # 14.x

git init -q /tmp/dxb
git -C /tmp/dxb fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build \
    663906528d1cd5ea8fde7de6f16de73db9511549
git -C /tmp/dxb checkout -q FETCH_HEAD
cp xnu/patches/*.patch xnu/patches/*.sh /tmp/dxb/patches/
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' /tmp/dxb/build.sh

cd /tmp/dxb
MACOS_VERSION=13.5 MACHINE_CONFIG=POLARIS KERNEL_CONFIG=DEVELOPMENT ./build.sh
```

构建到后半段会检查 `/Library/Developer/KDKs/KDK_13.5_22G74.kdk`，缺失时自动
下载 Kernel Debug Kit（约 1–1.5 GB）并用 `sudo installer` 安装，需要再输一次
密码。

### KDK 下载中断

`build.sh` 里的 `curl` 没有断点续传，网络一抖就从头再来（半截文件留在
`/tmp/KDK.dmg`）。国内走代理时这一步最容易失败。先确认 GitHub 通：

```sh
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com
```

返回 `000` 说明解析到的 `198.18.x.x`（Clash TUN 的 fake-IP）不可用，换节点或
关掉 TUN 再说。能通之后，手动下载并安装（`-C -` 可续传）：

```sh
KDK_URL=$(curl -fsSL https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json \
    | jq -r '.[] | select(.name=="Kernel Debug Kit 13.5 build 22G74") | .url')
curl -L -C - --retry 10 --retry-delay 5 -o /tmp/KDK.dmg "$KDK_URL"

hdiutil attach /tmp/KDK.dmg
sudo installer -pkg '/Volumes/Kernel Debug Kit/KernelDebugKit.pkg' -target /
hdiutil detach '/Volumes/Kernel Debug Kit'
ls -d /Library/Developer/KDKs/KDK_13.5_22G74.kdk
```

装上之后重跑 `extra/build-kernel-macos.sh`，它会跳过下载直接编译。

产物在 `<构建目录>/dxb/build/xnu.obj/kernel.development.polaris`，或用
`--replace` 让它自己拷回 `xnu/out/`。

## 为什么本机（Intel + macOS 15.8）不值得

三条都不在支持矩阵里：宿主系统、可用 Xcode、以及在这条链上已经失效的
Homebrew。一次性成本 1–2 小时加 28 GB，收益只是省掉 CI 的等待。而当前真正
缺的是 polaris 的硬件日志（0085/0086 探针从未跑过），CI 一次就能给。
