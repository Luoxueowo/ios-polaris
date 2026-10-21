# 触摸驱动实现参考：Synaptics S3330（RMI4 over I²C）

本文是给 `xnu/patches/0087-polaris-touch-dsx.patch` 的移植依据。所有协议事实来自
mainline Linux `drivers/input/rmi4/`（Synaptics 官方 RMI4 传输/协议实现），
并在实机上用位翻转 I²C 交叉验证过。

## 1. 硬件结论（已确认）

| 项 | 值 | 依据 |
|---|---|---|
| 芯片 | Synaptics **S3330**（DSX） | DTB `synaptics,chip-id-name = "S3330"` |
| I²C 地址 | `0x20`（7 位） | 实测：`0x20` 应答，`0x38`/`0x55`/`0x10` 不应答 |
| 总线 | `i2c@a98000`（QUPv3 SE14） | DTB |
| SDA / SCL | TLMM gpio33 / gpio34（NORTH，func `qup14`=2） | `pinctrl-sdm845.c` |
| 复位 | TLMM gpio99（NORTH，低有效） | `synaptics,reset-on-state=0` |
| 中断 | TLMM gpio125（EAST，flags `0x2008`） | DTB |
| 面板 | JDI NT35596S，1080×2160 | `dsi_jdi_fhd_nt35596s_video_display` |
| 固件 | 烧在芯片 flash，上电自举，**系统不分发** | vendor 无该文件 |
| 电源 | `vdd`=`tp_vddio_vreg`(gpio23 高有效)、`vio`、`avdd`=PM8998 **LDO28**(3.3V) | DTB + 实测 |

> 关键：`synaptics_jdi_3330_d5x.fw` 只在升级时用，正常启动不需要推固件。
> 芯片 ACK 但读回全 0，不是“缺固件”，而是**传输层寻址错 + AVDD 未上电**。

## 2. I²C 传输层（mainline `rmi_i2c.c`，权威）

S3330 走的是 **1 字节寄存器地址 + 页选择寄存器 `0xff`** 的方案，不是 vendor
`syntics_dsx_i2c.c` 那种 2 字节地址。

```c
#define RMI_PAGE_SELECT_REGISTER 0xff
#define RMI_I2C_PAGE(addr) (((addr) >> 8) & 0xff)
```

### 写页选择（切页）

```c
static int rmi_set_page(struct rmi_i2c_xport *rmi_i2c, u8 page)
{
	u8 txbuf[2] = {RMI_PAGE_SELECT_REGISTER, page};   /* 0xff, page */
	retval = i2c_master_send(client, txbuf, sizeof(txbuf));
	rmi_i2c->page = page;
}
```

### 读寄存器

```c
static int rmi_i2c_read_block(struct rmi_transport_dev *xport, u16 addr,
			      void *buf, size_t len)
{
	u8 addr_offset = addr & 0xff;          /* 只发低 8 位 */
	struct i2c_msg msgs[] = {
		{ .addr = client->addr, .len = sizeof(addr_offset),
		  .buf = &addr_offset },           /* 写 1 字节地址 */
		{ .addr = client->addr, .flags = I2C_M_RD,
		  .len = len, .buf = buf },       /* 重复起始 + 读 */
	};
	if (RMI_I2C_PAGE(addr) != rmi_i2c->page)
		rmi_set_page(rmi_i2c, RMI_I2C_PAGE(addr));
	return i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
}
```

### 写寄存器

```c
static int rmi_i2c_write_block(struct rmi_transport_dev *xport, u16 addr,
			       const void *buf, size_t len)
{
	tx_buf[0] = addr & 0xff;              /* 只发低 8 位 */
	memcpy(tx_buf + 1, buf, len);         /* 数据跟在后面 */
	if (RMI_I2C_PAGE(addr) != rmi_i2c->page)
		rmi_set_page(rmi_i2c, RMI_I2C_PAGE(addr));
	i2c_master_send(client, tx_buf, len + 1);
}
```

### probe 的探测顺序

```c
devm_regulator_bulk_get(..., {"vdd", "vio"}, ...);
regulator_bulk_enable(...);              /* 先上电 */
of_property_read_u32(..., "syna,startup-delay-ms", &startup_delay);
msleep(startup_delay);
/* 写页选择 0：确认能通信，并把 PSR 置于已知状态 */
error = rmi_set_page(rmi_i2c, 0);
```

> 这一步就是我们的 bug：我们发 2 字节地址，芯片把第 2 个字节当数据吞掉；
> 用 1 字节读 `0x00` 时立即返回了 `0x40`，证明芯片是活的、数字部分在应答。

## 3. RMI4 协议层

### 3.1 PDT（Function Descriptor Table，mainline `rmi_driver.c`）

**扫描位置不是 0x0000**，而是从 `0x00E9` 向下到 `0x0005`，步长 6：

```c
for (addr = pdt_start; addr >= pdt_end; addr -= RMI_PDT_ENTRY_SIZE) { ... }
/* PDT_START_SCAN_LOCATION = 0x00E9, PDT_END_SCAN_LOCATION = 0x0005, ENTRY_SIZE = 6 */
```

每个功能一条 6 字节描述符（**基址都是 1 字节**，不是 2 字节）：

```
buf[0] query_base     (1)
buf[1] command_base   (1)
buf[2] control_base   (1)
buf[3] data_base      (1)
buf[4] int_src_count(3) | function_version(3)   (1)
buf[5] function_number                        (1)
```

- F01 的 `function_number = 0x01`
- F12 的 `function_number = 0x12`（2D 触摸）
- 结束条件：`function_number == 0x00 || 0xff`（`RMI4_END_OF_PDT`）
- 基址是**页内偏移**，跨页用页选择寄存器 `0xff`

### 3.2 F01（`rmi_f01.c`）—— 设备识别 / 复位 / 配置

query 布局（`RMI_F01_BASIC_QUERY_LEN = 21`）：

| 字段 | 位置 |
|---|---|
| manufacturer_id | query[0] |
| product info | `(query[2]&0x7f)<<7 | (query[3]&0x7f)` |
| 生产日期 | query[5]=年, query[6]=月, query[7]=日 |
| product_id[10] | query[11..20]（ASCII） |

命令寄存器（F01 `cmd_base`）：

```c
#define RMI_F01_CMD_DEVICE_RESET 1      /* 向 command 写 1 = 软复位 */
```

控制寄存器 `ctrl0`（F01 `ctrl_base`）位：

```c
sleep_mode[1:0]        /* 0 = normal */
RMI_F01_CTRL0_NOSLEEP_BIT      BIT(2)
RMI_F01_CTRL0_CHARGER_BIT      BIT(5)
RMI_F01_CTRL0_REPORTRATE_BIT   BIT(6)
RMI_F01_CTRL0_CONFIGURED_BIT   BIT(7)   /* 配置完成后置位 */
```

状态寄存器（F01 `data_base`）：

```c
RMI_F01_STATUS_CODE(status)       = status & 0x0f
RMI_F01_STATUS_BOOTLOADER(status) = status & 0x40
RMI_F01_STATUS_UNCONFIGURED(status)= status & 0x80
```

### 3.3 F12（2D 触摸，`rmi_f12.c`）

F12 的寄存器布局由 **register descriptor** 动态描述，多数地址不写死：

- Query0 `BIT(0)` 表示必须用 register descriptor；`BIT(3)` = has_dribble
- `Control 8`（sensor tuning）subpacket 0：`max_x`(le16) + `max_y`(le16)
- `Query 29`：DPM resolution（把 max_x/max_y 换算成 mm）
- finger 数 = Data1 描述符的 `num_subpackets`

**Data1 报告格式（每个触点 8 字节）**：

```c
#define F12_DATA1_BYTES_PER_OBJ  8
// 偏移 0 : object type（0x01 finger, 0x02 stylus, 0x03 palm, ...）
// 偏移 1-2: X (u16 little-endian)
// 偏移 3-4: Y (u16 little-endian)
// 偏移 5  : Z
// 偏移 6  : WX
// 偏移 7  : WY
```

- attention 处理**不写寄存器清中断**：读 data 寄存器即清中断
- 完整读数据包 = 读 `data_base` 起 `pkt_size` 字节，Data1 偏移由 descriptor 计算

> 完整解析 register descriptor 较繁琐；第一版可先读 `data_base` 起的数据块，
> 按 8 字节/对象解析（需先用 descriptor 或经验值定位 Data1 偏移）。

## 4. 电源

| 轨 | 来源 | 现状 |
|---|---|---|
| `vdd` / `vio`（数字 I/O） | TLMM gpio23（`tp_vddio_vreg`，高有效，startup-delay 4ms） | ✅ 已拉高 |
| `avdd`（模拟前端） | PM8998 **LDO28**，基址 `0x5b00`，ENABLE `+0x46` bit7 | ❌ 实测 `en=0`，未开 |

- PM8998 LDO 寄存器布局（`qcom_spmi-regulator.c`，LDO 通用）：
  - `ENABLE = base+0x46`，写 `0x80` 使能，`0x00` 关闭
  - `VOLTAGE_RANGE = base+0x40`，`VOLTAGE_SET = base+0x41`
  - `TYPE = base+0x04`，`SUBTYPE = base+0x05`
  - `LDO28 base = 0x5b00`（LDO1=0x4000，步长 0x100）
- 数字部分靠 `vdd` 就够应答；**触摸传感（坐标）需要 `avdd`**。

## 5. 我们当前实现的错误清单

1. **寻址宽度错**：`dsx_read/dsx_write` 发 2 字节地址（`wide=true`），S3330 要
   1 字节 offset。→ 2 字节读恒 0，1 字节读已返回 `0x40`。
2. **没有写页选择**：启动第一步应该 `write([0xff, 0x00])`（`rmi_set_page(0)`）。
3. **AVDD 未上电**：`ldo28 en=0`，模拟前端没电，即便协议通了也出不了坐标。
4. （次要）复位时序：vendor 用 GPIO 复位（reset 低 5ms → 高 → 等 200ms）与
   mainline 的“软复位写 F01 command=1”二选一；我们走 GPIO 那条，符合 DTB。

## 6. 正确实现清单（待改）

1. `dsx_read(reg, buf, len)`：1 字节 offset；`reg > 0xff` 时先 `write([0xff, reg>>8])`。
2. `dsx_write(reg, buf, len)`：1 字节 offset + 数据；跨页同上。
3. 启动序列：
   1. gpio23 拉高（vdd/vio）
   2. **写页选择 `[0xff, 0x00]`**
   3. 读 PDT（页 0，6 字节/项）→ 找到 F01（0x01）、F12（0x12）
   4. 读 F01 query → 打印 product_id（应是 `S3330` 相关）
   5. 写 F01 `ctrl0`：清 sleep，置 `CONFIGURED`（bit7）
   6. F12 配置 + 轮询 `data_base` 读坐标
4. AVDD：加 SPMI 写函数（CMD 通道），`write(0x5b46, 0x80)` 使能 LDO28，boot-arg 门控。

## 7. 参考文件

- `drivers/input/rmi4/rmi_i2c.c`      传输层（寻址 + 页选择，权威）
- `drivers/input/rmi4/rmi_f01.c`      F01：识别 / 复位 / ctrl0 / status
- `drivers/input/rmi4/rmi_f12.c`      F12：2D 报告（待取回补全）
- `drivers/input/rmi4/rmi_driver.c`   PDT 遍历 + init（待取回）
- `drivers/regulator/qcom_spmi-regulator.c`  PM8998 LDO 寄存器
- LineageOS sdm845 `drivers/input/touchscreen/synaptics_dsx/`  旧 2 字节方案，仅参考复位/供电
