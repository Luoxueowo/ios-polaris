# 用 QEMU 测试 polaris 的内核

`tools/qemu-polaris.py` 在宿主机上模拟裸机 shim 的加载过程，用来验证**纯内核
改动**，不用碰真机、不会碰到设备数据。

## 它测什么、不测什么

它用 `mkadt.py --qemu` 生成的 ADT：**单核**、GIC 在 QEMU `virt` 的地址
（`0x08000000`）、帧缓冲是 polaris 的 `0x9c000000` / 1080×2400、没有 UFS 节点
（根走内存盘）。

因此下面这些在 QEMU 里**验证不了**：

- polaris 的显示缩放（`polarispanel=1` 那条路径）——面板参数不同；
- UFS 根、PMIC、触控、电量计；
- 多核启动（QEMU ADT 只有 cpu0）。

能验证的是：机器配置、physmap、早期帧缓冲控制台的输出、PRNG、设备树平台
专家、HID 服务注册、panic 路径等与板级 MMIO 无关的部分。

## 环境

```sh
python3 tools/qemu-polaris.py --check-env
```

缺依赖时：

- Arch：`sudo pacman -S qemu-system-aarch64 llvm`
- Debian/Ubuntu：`sudo apt install qemu-system-arm llvm`
- Fedora：`sudo dnf install qemu-system-aarch64 llvm`
- macOS：`brew install qemu llvm`

## 造一个测试 payload

```sh
python3 tools/mkadt.py /tmp/qemu.adt --qemu
python3 tools/mkpayload.py xnu/out/kernel.development.polaris /tmp/qemu.adt \
    /tmp/payload-qemu.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam rd=md0'
```

注意这里**不要**带 `polarispanel`、`polarisfb_native` 或 `cpus=8`：QEMU 的
ADT 只有一个 CPU，帧缓冲几何也不是 polaris 的。

## 运行

```sh
# 20 秒冒烟测试
python3 tools/qemu-polaris.py /tmp/payload-qemu.bin /tmp/qemu_run --secs 20

# 实时串口输出
python3 tools/qemu-polaris.py /tmp/payload-qemu.bin /tmp/qemu_run --live-serial

# 有 panic 就失败（CI/回归用）：没 panic 返回 0，panic 返回 2，白屏/解码不全返回 3
python3 tools/qemu-polaris.py /tmp/payload-qemu.bin /tmp/qemu_run \
    --kernel xnu/out/kernel.development.polaris --fail-on-panic

# 停在开机状态，GDB stub 在 :1234
python3 tools/qemu-polaris.py /tmp/payload-qemu.bin /tmp/qemu_run --gdb
gdb -ex "set architecture aarch64" -ex "target remote localhost:1234"
```

`--hmp 'x /8gx 0xfffffe...'` 可以在停止后追加 monitor 命令；`--cpu` 可换
CPU 型号（默认 `cortex-a76`，对应 Kryo 470 / A75 的 `ID_AA64MMFR0`）。

## 产物

输出目录里：

- `fb.png`：帧缓冲原图（QEMU 这一路是 1080×2400）
- `fb.txt`：从帧缓冲解码出的 ASCII 控制台文字
- `regs.txt`：结束时经 QMP dump 的寄存器
- `qemu.log`：guest 异常（中断、data abort、translation fault）
- `result.json`：自动判定结果（`no_panic_observed`、`panic`、
  `blank_screen`、`incomplete_decode`）

`fb.txt` 是最有用的一项：早期控制的 `POLARIS EARLY n: ...` 阶段标记会原样
出现在里面，可以直接看出卡在哪一步。
