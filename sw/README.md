# sw 索引

> PS 侧代码。**只有一套驱动**，对应 `bd_video` 这一个 BD。

## 一键回归

```bash
bash sw/build_preproc_sim.sh     # 预处理链驱动的主机自检
```

判定标准是 `*** PREPROC DRIVER SIM PASSED ***`。

---

## 只有一套驱动

| 驱动 | 对应 BD | 控制什么 | 状态 |
|---|---|---|---|
| `preproc_driver.c/.h` | `bd_video.tcl` | gesture_preproc + 两个 DMA | ✅ 自检 24/24 |

Sobel 那套驱动（`sobel_driver.c/.h`、`main.c`、`sim_dma.c`）
**已从本项目移除**，参照在 `legacy/sobel`。

> ⚠ 但 `sobel_driver` 里那个 **D2 坑**（状态位在 CTRL(0x00) 而非 0x04）
> 的完整记录仍在 `legacy/sobel/sw/sobel_driver.h`，值得一读 ——
> 本驱动从一开始就用对了位置，正是因为它踩过。

---

## 文件清单

### 手势预处理链（新，主力）

| 文件 | 作用 |
|---|---|
| `preproc_driver.h` | 寄存器定义 + API 声明 |
| `preproc_driver.c` | 驱动实现（双模式：目标 / 主机仿真） |
| `preproc_sim.c` | **仅供主机仿真**的朴素预处理实现 |
| `main_preproc.c` | 自检主程序（24 项检查） |
| `build_preproc_sim.sh` | 一键编译运行 |

---

## 关键设计点

### 1. 寄存器偏移全部来自官方生成的头文件

不凭记忆写：

```
gesture_comp/solution1/impl/ip/drivers/
    gesture_preproc_v1_0/src/xgesture_preproc_hw.h   ← 偏移
                          xgesture_preproc.c          ← 控制位语义
```

### 2. ⚠ 状态位在 `CTRL(0x00)`，不在 `0x04`

```
0x00  AP_CTRL   ← 控制 + 状态位都在这
0x04  GIE       ← 全局中断使能（不是状态！）
0x08  IER       ← 通道中断使能
0x0C  ISR       ← 通道中断状态
0x10  参数 0（按 8 字节对齐）
```

控制位：`ap_start`=bit0、`ap_done`=bit1、`ap_idle`=bit2、`ap_ready`=bit3。

**本项目的起点工程（`legacy/sobel/`）就在这个坑上栽过**：
驱动轮询 `0x04` 永远等不到 `AP_DONE`，而主机仿真自己造了个假
STATUS 值，所以看起来是通的 —— **上板才会炸**。
完整记录见 `legacy/sobel/sw/sobel_driver.h` 的注释。

`preproc_driver` 从一开始就用正确的位置，正是因为踩过。

### 3. ⚠ 执行顺序不能反

```
1. 先武装 dma_out（S2MM）—— 让它准备好接收
2. 再启动 dma_in（MM2S）—— 开始供数
3. 最后写 ap_start
4. 轮询 ap_done
```

**反了的后果**：预处理输出的第一拍没有接收方（S2MM 还没武装），
那部分数据会丢 —— 表现为输出图像开头缺几行，或 S2MM 报 DMA 错误。

### 4. ⚠ 阈值偏置是有符号的

`thresh_offset` 是 `int8` 范围（-128..127）。写硬件时要**转成补码**：

```c
reg_wr(ip_base, PREPROC_REG_THRESH_OFFSET, (uint32_t)(int32_t)dev->thresh_offset);
```

直接 `(uint32_t)(-8)` 会变成 `0xFFFFFFF8`，IP 侧当成巨大的正数 ——
**表现为输出全黑或全白**，而你会去查阈值算法，想不到是类型转换。

### 5. Cache 一致性

Zynq 上 DMA **绕过 cache** 直接读写 DDR，必须手动维护：

```c
/* 让 DMA 看到 CPU 刚写的输入数据 */
CACHE_FLUSH(src, PREPROC_IN_BYTES);
... DMA 搬运 ...
/* 让 CPU 看到 DMA 刚写的结果 */
CACHE_INVALIDATE(dst, PREPROC_OUT_BYTES);
```

漏了 flush：DMA 读到旧数据。
漏了 invalidate：CPU 读到旧结果 —— **两种都表现为"数据不对"**，
而不会报任何错。原工程 README §5 有详细记录。

---

## 从主机仿真到真机

主机仿真模式用 `-DPREPROC_SIM_BUILD` 编译，**共用同一份控制流**，
只替换最底层的几个访问原语（`reg_rd` / `reg_wr` / cache 宏）。

⚠ **不要给仿真模式另写一套逻辑** —— 那样验证的是假的。
`sobel_driver` 上正是这个坑：仿真自己造假状态值，掩盖了 D2 那个 bug。

真机编译时去掉该宏，并在 Vitis 工程里加入 BSP。

---

## 它对应的 BD

驱动控制的三个 IP 都在 `vivado/bd_video.tcl` 里：

```
gesture_preproc_0   ← HLS 预处理链（AXI-Lite 配参数）
dma_in              ← MM2S，读 DDR 里的 640×480 RGB565 进预处理
dma_out             ← S2MM，把 96×96 灰度写回 DDR
```

**地址不硬编码** —— 从 `.hwh` 提取（`ip_contract.py` 可做），
或直接用 PYNQ 的 `overlay.ip_dict`（`host/gesture_overlay.py` 就是这么做的）。

## 当前状态

| 项 | 状态 |
|---|---|
| 主机自检 | ✅ 24/24 通过（`bash sw/build_preproc_sim.sh`） |
| 真机编译 | ❌ 未做（需板子 + XSA 建 Vitis 工程） |
| 板级实测 | ❌ 未做（板子未到） |

## 待补

| 项 | 说明 |
|---|---|
| **SCCB 寄存器表** | `rtl/ov5640_regs.v` —— ✅ **2026-09-17 已换为真表**（250 条，正点原子来源，固化 640×480 RGB565）。⚠ **未上板实测** |
| **与 CNN 侧的接口** | 输出 buffer 的地址需要由驱动告知对方，目前还没实现协议（`host/dump_frame.py` 已备好对拍格式） |
| **`sccb_0` 的 N_REGS** | ⚠ BD 里必须是 **250**（与 `ov5640_regs.v` 一致）。`sccb_master.v` 的默认值是 64，不一致会**配到一半就停且无报错** |
| **`ov5640_regs` 拼接顺序** | ⚠ `tbl_data = {reg_addr[15:0], value[7:0]}`，高 16 位是寄存器地址。反了会往错误寄存器写值，而 SCCB 波形看起来完全正常（见 `rtl/tb/tb_ov5640_regs.v`） |
| 中断模式 | 现在是轮询 `ap_done`；要改中断需在 BD 开 `PCW_USE_FABRIC_INTERRUPT` |
| XCLK 配置 | Clocking Wizard 是 BD 里配的，驱动不需要管 ✓ |
