# Sobel 边缘检测加速器（Vitis HLS + AXI DMA + Zynq）

在 Zynq-7000 上用 Vitis HLS 实现 Sobel 边缘检测算子，接口为
**AXI4-Stream（数据）+ AXI4-Lite（控制）**，通过 **AXI DMA** 与 PS 的 DDR
做 DDR→DDR 的整帧处理，并配有裸机驱动、三层仿真平台和一键集成脚本。

> **状态（本机实测）**
> - HLS：csim **TB PASSED**（14 组）、csynth 成功（**II=1**，Est. Fmax 138.17 MHz）、IP 已导出
> - Vivado：IP 可被识别、Block Design 构建通过、**综合 + 实现 + 生成比特流全部跑通**
> - **时序收敛**：WNS **+1.100 ns**，TNS = 0（11709 个终点全过）
> - 整设计资源：LUT **6.54%**、FF 4.15%、BRAM 2.50%、DSP 1 个；功耗 1.696 W
> - 驱动：主机仿真跑通，边界检查全部生效
> - **未导出 XSA、未经板级实测**
>
> 数据详见 §7，报告在 `vivado/sobel_system.runs/impl_1/`。

---

## 目录

1. [架构](#1-架构)
2. [目录结构](#2-目录结构)
3. [复现流程](#3-复现流程)
4. [接口与寄存器](#4-接口与寄存器)
5. [驱动 API](#5-驱动-api)
6. [仿真平台](#6-仿真平台)
7. [实测综合数据](#7-实测综合数据)
8. [已知限制与扩展](#8-已知限制与扩展)
9. [踩过的坑](#9-踩过的坑)
10. [参考](#10-参考)

---

## 1. 架构

```
        PS (ARM Cortex-A9)                        PL
  ┌──────────────────────┐
  │                      │  M_AXI_GP0    ┌──────────────┐
  │   DDR (输入帧)        ├──────────────►│ s_axi_ctrl   │
  │                      │               │  (AXI-Lite)  │
  │                      │               └──────┬───────┘
  │                      │                      │ width/height
  │                      │                      │ thresh/gain
  │                      │                      ▼
  │                      │  S_AXI_HP0    ┌──────────────┐
  │                      │◄─────────────►│  AXI DMA     │
  │   DDR (输出帧)        │   (HP 口)     │ MM2S / S2MM  │
  │                      │               └──┬────────┬──┘
  └──────────────────────┘                  │        │
                                    AXI4-Stream       │ AXI4-Stream
                                            ▼        │
                                     ┌─────────────────────┐
                                     │    sobel_accel      │
                                     │  行缓存 → 3x3窗口    │
                                     │  → Sobel → 饱和     │
                                     └─────────────────────┘
```

**数据通路**：PS 把输入图放 DDR → DMA MM2S 读出来送 Sobel → Sobel 输出经
DMA S2MM 写回 DDR → PS 读回结果。全程一次搬运，无中间缓冲。

### Sobel IP 内部结构

```
src (AXI-Stream, 8bit)
      │
      ▼
 ┌─────────────────────────────────────┐
 │ 3 行 BRAM 行缓存（按 y%3 轮转）      │
 │   写: lb[y%3]   读: lb[(y+2)%3]      │
 │                 读: lb[(y+1)%3]      │
 └──────────────┬──────────────────────┘
                │ 每个行缓存后接 3 级列移位寄存器
                ▼
        [x-3][x-2][x-1]  →  3x3 窗口
                │
                ▼
        Gx / Gy 卷积 → |Gx|+|Gy| → ×gain>>8 → 阈值 → 饱和
                │
                ▼
dst (AXI-Stream, 8bit)   PIPELINE II=1
```

**输出延迟**：流式处理的固有特性 —— 读到 `(y,x)` 时算的是 `(y-1, x-2)`
处的边缘强度。延迟是常数，不影响结果，只是输出流整体后移。
边界用补零处理，输出图与输入图**同尺寸**。

---

## 2. 目录结构

```
project/
├── README.md                    ← 本文件（唯一文档：复现流程 + 寄存器手册 + 踩坑）
├── .gitignore                   忽略所有可重建的产物
├── src_hls/                     HLS 源码与工程脚本
│   ├── sobel_hls.cpp            核心：行缓存/窗口生成/Sobel/接口
│   ├── sobel_hls.h              常量、寄存器定义、axis 类型
│   ├── tb_sobel.cpp             C 仿真 testbench（两段式验证）
│   └── run_hls.tcl              建工程 + csim + csynth + 导出 IP
├── sim/                         仿真平台
│   ├── gen_vectors.py           生成测试图 + Python golden 向量
│   └── compare.py               输出比对 / 差异分析 / 出图
├── sw/                          PS 端裸机驱动
│   ├── sobel_driver.h           寄存器映射 + API 声明
│   ├── sobel_driver.c           驱动实现（含 cache 维护）
│   ├── sim_dma.c                主机仿真用的模拟 DMA（仅 SOBEL_SIM_BUILD）
│   └── main.c                   Demo
├── vivado/                      Vivado 集成
│   ├── create_project.tcl       一键建工程 + 注册 IP + BD + 综合 + 导出 XSA
│   ├── bd_sobel.tcl             Block Design 构建
│   ├── check_ip.tcl             IP 冒烟测试（秒级）
│   └── constraints/sobel_io.xdc 约束
├── host/
│   └── sobel_ref.py             Python golden 参考模型
├── hls_config.cfg               Vitis HLS 组件的配置（GUI 流程用）
└── docs/
    └── GUI复现指南.md            纯鼠标操作的复现流程（Vitis 组件 → Vivado BD → 裸机）
```

> **不想敲命令**：见 [`docs/GUI复现指南.md`](docs/GUI复现指南.md)，
> 全程 GUI 走完 HLS → IP → BD → XSA → 裸机工程。

运行时生成、已被 `.gitignore` 忽略、可随时重建：
`sobel_accel/`（HLS 工程与导出的 IP）、`vivado/sobel_system/`（Vivado 工程）、
`sim/vectors/`（测试向量）、`build/`（本地编译产物）、`src_hls/tb_paths.h`。

---

## 3. 复现流程

从零到可上板，五步。每步都有**可检验的输出**，不过就别往下走。

> **纯 GUI 版本**：见 [`docs/GUI复现指南.md`](docs/GUI复现指南.md)。
> 两条路等价，产出的 IP 完全一致，可以混用 ——
> 比如用命令行跑 HLS，用 GUI 看综合报告。
> 唯一的例外是**步骤 1 生成向量没有 GUI 入口**，两条路都要敲一次命令。

### 3.0 环境

| 组件 | 版本 | 本机路径 |
|---|---|---|
| Vitis（含 HLS） | 2025.2 | `D:\BaiduNetdiskDownload\2025.2\Vitis` |
| Vivado | 2025.2 | `D:\BaiduNetdiskDownload\2025.2\Vivado` |
| Python | 3.x + NumPy | — |
| （可选）主机 C++ 编译器 | 支持 C++17 | 用于不开 HLS 就验证算法 |

> **2025.2 的重要变化**：没有独立的 `vitis_hls` 命令了，改用
> `vitis-run --mode hls --tcl <脚本>`。
> 2023.2 及更早把所有 HLS 命令换成 `vitis_hls -f <脚本>` 即可。

**先设环境变量**，否则 HLS 导出 IP 时会报 `Cannot find Vivado`：

```bash
# bash / git-bash
export XILINX_VIVADO=D:/BaiduNetdiskDownload/2025.2/Vivado

# cmd
set XILINX_VIVADO=D:\BaiduNetdiskDownload\2025.2\Vivado
```

---

### 步骤 1／5 ── 生成测试向量（秒级）

```bash
cd project
python sim/gen_vectors.py
```

**产出**：`sim/vectors/` 下 6 组 `*_in.txt` / `*_gold.txt` + `manifest.txt`。

**核验**：目录里应有 13 个文件（6×2 + 清单）。

```bash
ls sim/vectors/ | wc -l      # 期望 13
```

> 换阈值/增益：`python sim/gen_vectors.py --thresh 64`

---

### 步骤 2／5 ── 跑 HLS：csim → csynth → 导出 IP（约 1 分钟）

```bash
vitis-run --mode hls --tcl src_hls/run_hls.tcl
```

**产出**
- `sobel_accel/solution1/csim/` —— C 仿真
- `sobel_accel/solution1/syn/report/` —— 综合报告
- `sobel_accel/solution1/impl/ip/` —— **导出的 IP 目录**（含 `component.xml`）

**核验（三项都要看）**

```bash
# 1) 终端应打印 TB PASSED（csim 的 stdout 直接回显）

# 2) 接口是否真的成了 AXI-Stream，而不是退化成 ap_none
grep "Setting interface mode on port 'sobel_accel/src" \
     sobel_accel/solution1/solution1.log
# 期望看到 4 行，都带 'axis'，实际端口名是 src_V_data_V 等
#   ... on port 'sobel_accel/src_V_data_V' to 'axis' (register, both mode)
#   ... on port 'sobel_accel/src_V_keep_V' to 'axis' ...
#   ... on port 'sobel_accel/src_V_strb_V' to 'axis' ...
#   ... on port 'sobel_accel/src_V_last_V' to 'axis' ...
# 【关键】出现 to 'ap_none' 就说明 INTERFACE 指令被丢弃了，见 §9.2

# 3) TLAST 端口是否存在（AXI DMA 的 S2MM 依赖它）
grep -c TLAST sobel_accel/solution1/impl/ip/hdl/verilog/sobel_accel.v
# 期望 > 0（实测 17）。为 0 说明用了裸 stream 类型，见 §9.6
```

**只看某一步**（2025.2 的 `--tcl` 后面不能再跟参数，所以用环境变量）：

```bash
SOBEL_HLS_ONLY=csim   vitis-run --mode hls --tcl src_hls/run_hls.tcl
SOBEL_HLS_ONLY=csynth vitis-run --mode hls --tcl src_hls/run_hls.tcl
```

---

### 步骤 3／5 ── 验证 IP 能被 Vivado 识别（秒级）

```bash
vivado -mode batch -source vivado/check_ip.tcl
```

**核验**：输出里必须包含

```
src              (axis  )
dst              (axis  )
s_axi_control    (aximm )
>>> VLNV : user:hls:sobel_accel:1.0
      WIDTH        0x10
      HEIGHT       0x18
      THRESH       0x20
      GAIN         0x28
```

偏移应与 §4 的表格一字不差。若有出入，同步改 `sw/sobel_driver.h`
与 `src_hls/sobel_hls.h` 里的 `SOBEL_REG_*`。

---

### 步骤 4／5 ── 建 Vivado 工程与 Block Design

先只建工程和 BD 不跑综合（几十秒，用来确认脚本正确）：

```bash
cd vivado
vivado -mode batch -source create_project.tcl -tclargs --synth 0
```

**核验**：输出末尾应出现

```
>>> BD 'sobel_bd' 构建完成
>>> 顶层设为 sobel_bd_wrapper
```

且**全程没有 `CRITICAL WARNING`**（尤其不能有 `does not have TLAST port`）。

要完整综合 + 实现 + 导出 XSA（较慢，几十分钟）：

```bash
vivado -mode batch -source create_project.tcl          # 默认 --synth 1
```

**产出**：`vivado/sobel_system/sobel_system.xsa` 与 `utilization.rpt`。

换器件：`-tclargs --part xc7z010clg400-1`。

---

### 步骤 5／5 ── 编译并运行裸机程序

1. Vitis 里用 `sobel_system.xsa` 新建 **Application Project**
   （standalone，处理器选 `ps7_cortexa9_0`）
2. 把 `sw/` 下的 `sobel_driver.h`、`sobel_driver.c`、`main.c` 拷进 `src/`
3. **核对基地址**与 `xparameters.h` 一致：

```c
XPAR_SOBEL_ACCEL_0_BASEADDR          // IP 控制口
XPAR_AXI_DMA_0_BASEADDR                      // DMA
```

4. 串口 115200，下载运行。应看到 Demo 打印耗时、吞吐与 ASCII 边缘图

---

### 无硬件也能复现的部分

上板之前，下面三条在普通 PC 上就能跑，覆盖了绝大部分逻辑。

**A. 算法正确性** —— HLS 的 C 代码本身就是普通 C++，可直接本地编译：

```bash
VITIS_INC=D:/BaiduNetdiskDownload/2025.2/Vitis/include
g++ -std=c++17 -O2 -I src_hls -I "$VITIS_INC" \
    -o build/tb src_hls/sobel_hls.cpp src_hls/tb_sobel.cpp
./build/tb            # 期望 TB PASSED
```

**B. Python 参考模型自检**

```bash
python sim/compare.py            # 期望「全部一致」
```

**C. 驱动逻辑**（模拟 DMA，无需硬件）

```bash
gcc -DSOBEL_SIM_BUILD -I sw -o build/demo \
    sw/sobel_driver.c sw/sim_dma.c sw/main.c
./build/demo          # 期望三处边界检查都被拦截
```

> A 需要 `ap_int.h` / `hls_stream.h` / `ap_axi_sdata.h`，位于
> `<Vitis安装>/include/` 下（2025.2 是
> `D:/BaiduNetdiskDownload/2025.2/Vitis/include`）。
> 必须用 **C++17**，因为 `ap_axiu` 用了 `if constexpr`。

---

### 常见失败与对策

| 现象 | 原因 | 对策 |
|---|---|---|
| `Cannot find Vivado` | 没设 `XILINX_VIVADO` | 见 §3.0 |
| `option '--input_file' cannot be specified more than once` | `--tcl` 后跟了参数 | 改用 `SOBEL_HLS_ONLY=` 环境变量 |
| 综合日志出现 `to 'ap_none'` | `INTERFACE axis` 带了 `bundle=`，指令被丢弃 | 去掉 `bundle=`，见 §9.2 |
| `does not have TLAST port` | 用了裸 `hls::stream<ap_uint<8>>` | 换 `ap_axiu<8,0,0,0>`，见 §9.6 |
| `Arguments ... cannot be empty` | 某引脚不存在，多为 PS7 被 board preset 重置 | 见 §9.7 |
| `read_ip` 找不到文件 | `export_design` 产出的不是 `.xci` | 用 `ip_repo_paths` 注册，见 §9.8 |
| 板上结果随机错 | cache 没同步 | `sobel_run` 已封装，见 §5 |

---

## 4. 接口与寄存器

### 4.1 接口一览

| 接口 | C 类型 | 协议 | 用途 |
|---|---|---|---|
| `src` | `hls::stream<ap_axiu<8,0,0,0>>` | AXI4-Stream | 输入灰度像素流 |
| `dst` | `hls::stream<ap_axiu<8,0,0,0>>` | AXI4-Stream | 输出边缘图流 |
| `s_axi_control` | 标量 `width`/`height`/`thresh`/`gain` | AXI4-Lite | 配置与状态 |
| `ap_clk` / `ap_rst_n` | — | 时钟 / 低有效复位 | 所有接口共用一个时钟 |

**Stream 信号**：`TDATA`(8) / `TKEEP`(1) / `TSTRB`(1) / `TVALID` / `TREADY` / `TLAST`。
一个 beat 一个像素。无 `TUSER` —— 不传行首标记，IP 靠 `WIDTH/HEIGHT` 寄存器
自己数行列，所以 DMA 送来的数据必须**严格按行连续，不能有 padding**。

> **TLAST 由 IP 显式置位**，落在整帧最后一个像素上。AXI DMA 的 S2MM 靠它
> 判定一次传输结束 —— **少了它 DMA 会一直等下去**。
>
> 注意：裸的 `hls::stream<ap_uint<8>>` 综合出来**只有 TDATA/TVALID/TREADY，
> 没有 TLAST**，Vivado 会报 `Interface connected to S_AXIS_S2MM does not have
> TLAST port`。必须用带 `last` 成员的 axis 结构体。见 §9.6。

### 4.2 寄存器映射

| 偏移 | 名称 | 访问 | 复位值 | 说明 |
|---|---|---|---|---|
| `0x00` | CTRL | W | 0x0 | bit0=`ap_start`，bit1=`auto_restart` |
| `0x04` | STATUS | R | — | bit0=`ap_ready`，bit1=`ap_done`，bit2=`ap_idle` |
| `0x08` | — | R | — | 保留 |
| `0x10` | WIDTH | R/W | 0 | 图像宽度，1..1920 |
| `0x18` | HEIGHT | R/W | 0 | 图像高度，1..1080 |
| `0x20` | THRESH | R/W | 0 | 阈值 0..255，0 = 不二值化 |
| `0x28` | GAIN | R/W | 256 | Q8 增益，256 = ×1.0，0..4095 |

**这些偏移已用导出的 IP 实测核对过**，取自
`sobel_accel/solution1/impl/ip/drivers/sobel_accel_v1_0/src/xsobel_accel_hw.h`：

```c
#define XSOBEL_ACCEL_CONTROL_ADDR_AP_CTRL     0x00
#define XSOBEL_ACCEL_CONTROL_ADDR_WIDTH_DATA  0x10
#define XSOBEL_ACCEL_CONTROL_ADDR_HEIGHT_DATA 0x18
#define XSOBEL_ACCEL_CONTROL_ADDR_THRESH_DATA 0x20
#define XSOBEL_ACCEL_CONTROL_ADDR_GAIN_DATA   0x28
```

> **偏移规律**：Vitis HLS 给 AXI-Lite 标量参数按 8 字节对齐分配，
> 所以是 `0x10 / 0x18 / 0x20 / 0x28` 这样递增。
> 增删参数或改顺序**都会改变偏移**，必须重新核验。

**CTRL (0x00)**

| 位 | 名称 | 说明 |
|---|---|---|
| 0 | `ap_start` | 写 1 启动一次处理。完成后硬件不清零，软件需写 0 或写 `CTRL=0` |
| 1 | `auto_restart` | 结束后自动重启。本设计未使用，保持 0 |

**STATUS (0x04)**

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | `ap_ready` | 1 = 可接受新的 `ap_start` |
| 1 | `ap_done` | 1 = 本次处理已完成 |
| 2 | `ap_idle` | 1 = 内核空闲 |
| 3 | `ap_continue` | 与 `ap_continue` 握手相关，本设计未使用 |

典型轮询：

```c
Xil_Out32(base + 0x00, 0x01);                            // ap_start
while (!(Xil_In32(base + 0x04) & 0x02)) { /* 等 ap_done */ }
Xil_Out32(base + 0x00, 0x00);                            // 清 ap_start
```

> IP 另生成了 `GIE(0x04) / IER(0x08) / ISR(0x0c)` 中断寄存器。
> **本驱动不使用中断**，走轮询。改中断驱动的做法见 §8。

### 4.3 算法与参数

```
Gx   = (p00 + 2*p10 + p20) - (p02 + 2*p12 + p22)     水平梯度（响应竖直边缘）
Gy   = (p00 + 2*p01 + p02) - (p20 + 2*p21 + p22)     垂直梯度（响应水平边缘）
mag  = (|Gx| + |Gy|) * GAIN >> 8
out  = (mag > THRESH) ? 255 : min(mag, 255)
```

用 **L1 范数** `|Gx|+|Gy|` 而非 `sqrt(Gx²+Gy²)`：免开方、纯整数、可与
Python 模型逐位对齐；幅值比真实梯度模约大 8%，做边缘检测足够。

| 参数 | 效果 |
|---|---|
| `GAIN = 256` | 原样输出，适合观察梯度幅值 |
| `GAIN < 256` | 整体变暗，弱边缘被压掉 |
| `GAIN > 256` | 整体变亮，超过 255 的部分饱和 |
| `THRESH = 0` | 不做二值化，输出灰度幅值图 |
| `THRESH > 0` | 二值化边缘图（只有 0 和 255） |

### 4.4 数据流与尺寸

- 输入输出都是 **8-bit 单通道灰度**，每像素 1 字节
- 一帧字节数 = `WIDTH × HEIGHT`，AXI DMA 的传输长度寄存器填这个值
- 输出图与输入图**同尺寸**（边界补零，不裁剪）

### 4.5 怎么核验偏移

**方式一 —— 看生成的驱动头文件（最权威）**

```
sobel_accel/solution1/impl/ip/drivers/sobel_accel_v1_0/src/xsobel_accel_hw.h
```

`XSOBEL_ACCEL_CONTROL_ADDR_xxx_DATA` 宏即实际偏移。

**方式二 —— 跑 `vivado/check_ip.tcl`**，它会直接把偏移打印出来。

**方式三 —— Vivado 的 Address Editor** 只能看到 `s_axi_control` 的基址，
偏移仍需方式一。

**方式四 —— Vitis 的 `xparameters.h`**

```c
#define XPAR_SOBEL_ACCEL_0_BASEADDR                 0x40000000
#define XPAR_SOBEL_ACCEL_0_S_AXI_CONTROL_HIGHADDR   0x43C0FFFF
```

### 4.6 改了寄存器布局要同步哪些地方

1. `src_hls/sobel_hls.h` —— `SOBEL_REG_*` 宏
2. `sw/sobel_driver.h` —— 同名宏（两份必须一致）
3. 本文档 §4.2 的表格
4. `sw/sim_dma.c` —— 主机仿真时模拟寄存器行为（若涉及状态位）

---

## 5. 驱动 API

```c
#include "sobel_driver.h"

sobel_t dev;
sobel_init(&dev, IP_BASEADDR, DMA_BASEADDR);
sobel_set_size(&dev, 640, 480);
sobel_set_thresh(&dev, 0);          // 0 = 输出灰度幅值
sobel_set_gain(&dev, 256);          // 256 = ×1.0

sobel_run(&dev, src_buf, dst_buf);  // 阻塞式处理一帧
printf("%u 周期\n", sobel_last_cycles(&dev));
```

`sobel_run` 内部做了三件容易被忽略的事：

1. **`Xil_DCacheFlushRange(src)`** —— 输入图刷出 cache
2. 启动 DMA 与 IP，轮询等 `ap_done`
3. **`Xil_DCacheInvalidateRange(dst)`** —— 作废输出范围的 cache

> ⚠️ **第 1、3 步是 Zynq 上最容易踩的坑**。AXI DMA 走 HP 口直接读写 DDR，
> **不经过 CPU 的 L1/L2**。漏掉 flush 会读到旧数据，漏掉 invalidate
> 会读到 cache 里的旧值 —— 两者都表现为"结果随机错误"，且随地址和
> cache 状态变化，极难定位。驱动已封装，调用者只需保证 4 字节对齐。

驱动还会检查：空指针、尺寸越界（>1920×1080）、地址未对齐，
三者都返回 `SOBEL_ERR_PARAM`，不会把错误传给硬件。

### 无板卡也能验证驱动

```bash
gcc -DSOBEL_SIM_BUILD -I sw -o demo \
    sw/sobel_driver.c sw/sim_dma.c sw/main.c
./demo
```

实测输出（本机）：

```
[ OK ] 配置 64x48  thresh=0  gain=256
[ OK ] 处理完成
       边缘像素  : 852 / 3072
>>> 边界测试
       超大宽度       -> 已拦截 (期望 -1)
       空指针输入     -> 已拦截 (期望 -1)
       未对齐源地址   -> 已拦截 (期望 -1)
```

---

## 6. 仿真平台

三层验证，互相独立：

| 层 | 手段 | 验证什么 | 命令 |
|---|---|---|---|
| 1 | HLS `csim` | 流式实现 vs 朴素实现（8 组自洽）+ Python golden（6 组跨实现） | `run_hls.tcl` |
| 2 | Python | 向量化 vs 逐像素实现 | `python sim/compare.py` |
| 3 | 驱动主机仿真 | 参数检查/地址运算/DMA 调用顺序 | `-DSOBEL_SIM_BUILD` |

**第 1 层**的 testbench 分两段。第一段拿伪随机图和几何图比较
`sobel_accel()`（流式行缓存实现）与 `sobel_ref_sw()`（朴素逐像素实现），
两者循环结构完全不同，任何 off-by-one 都会暴露；第二段再和 Python golden
比，抓"C 和 Python 同时写错同一个约定"的情况。

testbench 用**双线程**：生产者线程灌输入，主线程收输出。
单线程会死锁 —— 输入流写满后卡住，而设计又因输出流满不能继续消费。

实测结果：

```
[1] 自一致性：流式实现 vs 朴素实现
  [gradient] 64x48   hw vs sw : PASS
  [checker]  64x48   hw vs sw : PASS
  [shapes]   64x64   hw vs sw : PASS
  [ramp]     64x48   hw vs sw : PASS
  [noise]    61x47   hw vs sw : PASS
  [single]   1x1     hw vs sw : PASS     ← 退化尺寸
  [thin]     1x32    hw vs sw : PASS     ← 退化尺寸
  [flat]     33x33   hw vs sw : PASS     ← 全常值
[2] 外部向量：流式实现 vs Python golden
  [gradient]/[checker]/[shapes]/[ramp]/[noise]/[odd]  全部 PASS
  TB PASSED
```

比对单份输出（比如板上回传的）：

```bash
python sim/compare.py --out hw_out.txt --gold sim/vectors/shapes_gold.txt
```

会报告差异像素数、PSNR、差异形态（边界 vs 内部），并导出并排 PNG。

---

## 7. 实测数据

`xc7z020clg400-1`，目标时钟 10 ns（100 MHz）。

分两组：**① HLS 对 Sobel IP 本身的估计**（csynth 报告），
**② Vivado 对整个 Block Design 的实现结果**（含 PS7 + DMA + 互联 + Sobel）。

### 7.1 Sobel IP 本身（HLS csynth 估计）

| 指标 | 值 | 来源 |
|---|---|---|
| **流水线 II** | **1**（Target II = 1，Final II = 1） | `csynth.rpt` |
| 时序估计 | 7.238 ns < 10 ns | `csynth.rpt` |
| **Estimated Fmax** | **138.17 MHz** | `csynth.rpt` |
| LUT | 1826（3%） | `csynth.rpt` |
| FF | 903（~0%） | `csynth.rpt` |
| DSP | 1 | `csynth.rpt` |
| BRAM_18K | 3（1%） | `csynth.rpt` |

`All loop constraints were satisfied`。资源占用低是因为关键路径短、
算法全整数；唯一的乘法 `(|Gx|+|Gy|) * gain` 综合成 1 个 DSP。

### 7.2 整个 Block Design（Vivado 实现后实测）

报告：`vivado/sobel_system.runs/impl_1/sobel_bd_wrapper_*.rpt`

**时序 — 收敛**

| 指标 | 值 |
|---|---|
| **WNS** | **+1.100 ns** |
| TNS | 0.000 ns（失败终点 0 / 11709） |
| WHS | +0.029 ns |
| THS | 0.000 ns（失败终点 0 / 11709） |
| WPWS | +3.750 ns |
| 时钟 | `clk_fpga_0`，10.000 ns / 100.000 MHz |

WNS 为正且 TNS = 0，**全部 11709 个时序终点都满足约束**。

**资源占用**

| 资源 | 使用 | 可用 | 占比 |
|---|---|---|---|
| Slice LUTs | 3479 | 53200 | 6.54% |
| Slice Registers | 4413 | 106400 | 4.15% |
| Block RAM Tile | 3.5 | 140 | 2.50% |
| DSPs | 1 | 220 | 0.45% |
| BUFGCTRL | 1 | 32 | 3.13% |

**功耗**（`Report Power`，默认无开关活动率假定）

| 项 | 值 |
|---|---|
| Total On-Chip Power | 1.696 W |
| Dynamic | 1.559 W |
| Device Static | 0.137 W |

> 注意：功耗是按**默认活动率**估算的，没跑实际仿真波形反标。
> 真实运行功耗要上板测量，或至少用 `write_saif` 反标。

> 这一批数字是 **S2MM 修复之后**重新实现的结果（比特流已生成）。
> 修复前（S2MM 悬空）是 LUT 2726 / FF 3356 / WNS +1.963 ns ——
> 补上 S2MM 的 AXI 通路后，LUT 增 753、FF 增 1057、时序终点从 8630 增到 11709，
> WNS 从 +1.963 降到 +1.100 ns（仍有余量）。

> **为什么 7.2 的数字比 7.1 大**：7.1 只算 Sobel IP，
> 7.2 包含整个 BD —— PS7 硬核接口、AXI DMA、两个 AXI 互联
> （`axi_smc` + `axi_mem_intercon`）、复位模块。
> LUT 从 1826 → 3479、FF 从 903 → 4413 的增量主要来自
> DMA 与互联的控制逻辑，不是 Sobel 本身。

### 7.3 吞吐

II=1 即每时钟 1 像素。100 MHz 下理论 **100 Mpx/s**，
1080p（207 万像素）约 **20.8 ms/帧**（≈ 48 fps）。
csynth 报告中主循环最大延迟 2,077,704 周期 ≈ 20.78 ms，与此吻合。

> 实际端到端吞吐会被 **DMA 带宽**限制，通常低于这个数。
> 1024×768 灰度约 786 KB，HP 口带宽足够；但小图时 DMA 启动开销占比高。

---

## 8. 已知限制与扩展

### 当前限制

- **最大 1920×1080**，由 `SOBEL_MAX_WIDTH/HEIGHT` 决定（改大需重新综合）
- **8-bit 单通道灰度**，彩色图需先转灰度
- **无 TUSER**，不传行首标志；IP 靠 `WIDTH` 自己数行列，
  所以 DMA 送来的数据必须严格按行连续
- **DMA 用简单模式**（非 Scatter-Gather）
- 输出边界 1 行 / 2 列是补零（不裁剪），与 OpenCV 的 `BORDER_DEFAULT` 不同
- **未做中断**，驱动轮询 `ap_done`
- **未导出 XSA**，因此**未经板级实测**
  （Vivado 侧已跑到生成比特流、时序收敛，见 §7.2）

### 扩展

**改成中断驱动**：IP 已生成 `GIE/IER/ISR` 寄存器。把 `interrupt` 输出接到
PS 的 `IRQ_F2P`（BD 里开 `PCW_USE_FABRIC_INTERRUPT`），驱动改用 `XScuGic`
注册 ISR，省掉轮询开销。

**改成分块流水线**：`sobel_run` 目前一次搬完整帧。大图可切成若干 tile
交给 DMA，让 MM2S/S2MM 重叠，提高带宽利用率。

**更大的分辨率**：当前行缓存按 `BLOCK` 映射成 3 个 BANK（每行轮流命中一个），
1920 宽只占 1 个 BRAM_18K，余量很大。放宽 `SOBEL_MAX_WIDTH` 到 4096 是安全的。

**改成 Scatter-Gather**：BD 里把 `c_include_sg` 设为 1，驱动改用
`XAxiDma_BdRing` API，可支持非连续缓冲与环形队列。

---

## 9. 踩过的坑

都是本项目实际调试中撞到的，记下来省得重复踩。

**9.1　2025.2 没有 `vitis_hls` 命令**
只有 `vitis-run --mode hls`。而且 `--tcl <脚本>` 后面**不能再跟参数**，
否则报 `option '--input_file' cannot be specified more than once`。
传参给 tcl 脚本要用环境变量。

**9.2　`#pragma HLS INTERFACE axis` 不接受 `bundle=`**
写了不报错，只警告 `unexpected pragma parameter 'bundle'`，然后**整条指令
被忽略**，端口退化成 `ap_none` 单根线。症状是综合日志里出现
`Setting interface mode on port 'xxx' to 'ap_none'`。**一定要检查这行
是不是 `to 'axis'`**。这个 bug 不会让 csim 失败，只有上板/连 BD 才炸。

**9.3　axis 端口名 = C 函数参数名**
不是惯用的 `s_axis_video`。本项目是 `src` / `dst`。
连 BD 前先看 `impl/ip/component.xml` 的 `busInterface name=`，
或跑 `check_ip.tcl`。

**9.4　tcl 往 C 宏注入路径会被多层转义吃掉引号**
`-DTB_VEC_DIR="E:/project/..."` 经 tcl → Makefile → clang 之后引号没了，
展开成一堆未声明标识符。解决办法是让 tcl 生成 `.h` 文件
（本项目 `src_hls/tb_paths.h`）再用 `-I` 指过去。

**9.5　Zynq 上 DMA 与 cache 必须手动同步**
见 §5。

**9.6　裸 `hls::stream<ap_uint<8>>` 不生成 TLAST**
综合日志一切正常，只有 Vivado 的 `validate_bd_design` 会冒出
`CRITICAL WARNING: Interface connected to S_AXIS_S2MM does not have TLAST port`。
查生成的 `.v` 确认端口里确实没有 `TLAST`。
换成 `hls::stream<ap_axiu<8,0,0,0>>` 并显式写 `w.last = ...` 即可。
验证：`grep TLAST sobel_accel/solution1/impl/ip/hdl/verilog/*.v`。

**9.7　`apply_bd_automation ... apply_board_preset 1` 会重置 PS7 配置**
它把你设好的 `PCW_USE_S_AXI_HP0 {1}` 覆盖掉，导致 `ps7/S_AXI_HP0` 不存在，
后面 `connect_bd_intf_net` 报 `Arguments ... cannot be empty` ——
而报错位置在几十行之外，很难往回查。
`bd_sobel.tcl` 因此在每个关键 `connect` 前都加了引脚存在性断言。

**9.8　`export_design -format ip_catalog` 产出的是 IP 目录，不是 `.xci`**
`impl/ip/` 下只有 `component.xml` + `hdl/` + `drivers/` + 一个 zip。
Vivado 里正确的导入方式是
`set_property ip_repo_paths <dir> [current_project]` +
`update_ip_catalog -rebuild`，**不是 `read_ip`**。

**9.9　Tcl 的 `regexp` 默认 `.` 不匹配换行**
写 `{busInterface.*?name="src"}` 去匹配跨行 XML 一定失败。
要 `regexp -all -inline {<tag>.*?</tag>}` 切块后在块内单行匹配。

**9.10　2025.2 的 `axis<T>` 是新模板**
字段是 `.data` / `.last` / `.keep` / `.strb`，定义在 `ap_axi_sdata.h`，
不是老的 `ap_axis` 裸结构。用 `ap_axiu<W,...>` 别名最省事。
需要 **C++17**（内部用了 `if constexpr`）。

**9.11　GUI 里跑 csim 会「假成功」**
Vitis GUI 往 `hls_config.cfg` 追加的 `csim.setup=1` 含义是
**只编译 `csim.exe`，不运行**。日志会打印
`Skipping execution of C Simulation due to 'setup' option`，
紧接着 `C-simulation finished successfully` ——
**一行测试都没跑，界面却显示成功**。
判断方法：`CONSOLE` 里搜 `TB PASSED`，搜不到就是没跑。
把 `csim.setup` 改成 `0` 重跑才真正执行。
详见 `docs/GUI复现指南.md`。

**9.12　GUI 的 HLS 组件目录布局与命令行不同**
命令行建在 `<工程根>/sobel_accel/solution1/impl/ip`；
GUI 建在 `<工程根>/<组件名>/<work_dir>/hls/impl/ip`
（默认 `<工程根>/sobel_accel_comp/sobel_accel/hls/impl/ip`）。
两个名字都能在向导里改。`check_ip.tcl` 与 `create_project.tcl`
的 IP 查找已用通配覆盖两种布局。

**9.13　导出 IP 那一步依赖 `XILINX_VIVADO` 环境变量**
综合全都成功（能看到 `Estimated Fmax: 138.17 MHz`），
却在最后打包时报
`ERROR: [IMPL 213-4] Cannot find Vivado, please check XILINX_VIVADO
environment variable`。
原因：`export_design` 要靠 Vivado 打包成 IP，HLS 用这个环境变量找 Vivado。
**报错信息里的路径可能是机器上残留的旧版本路径**（比如以前装过 2026.1）。
把它设成当前实际安装路径即可：

```bash
export XILINX_VIVADO=D:/BaiduNetdiskDownload/2025.2/Vivado
```

从 Vitis GUI 里跑不受影响（IDE 会自己配好）。

**9.14　改了源码但复用了旧构建目录，会看到「幽灵警告」**
综合日志里出现 `unknown escape sequence '\p'` 之类、
且指向**当前源码里根本不存在反斜杠**的行 —— 那是上一次构建的残留。
清掉 `hls/syn`、`hls/csim` 重跑即可。
（本项目已顺手在所有 `#pragma` 前加了空行，切断与上方注释的续行歧义，
从源头消除这类警告。）

**9.15　DMA 的 `M_AXI_S2MM` 悬空，Vivado 不会报错**
用 GUI 的 `Run Connection Automation` 建 BD 时，它生成的内存互联
**只有一个从接口**（`NUM_SI=1`），于是只接得下 MM2S，
**`axi_dma_0/M_AXI_S2MM` 没有连到 `S_AXI_HP0`**。
这是 DMA 写回结果的通路，悬空的后果是板上结果写不回 DDR、程序挂死。

**最坑的地方是没有任何报错**：`validate_bd_design` 通过、
综合实现全过、时序收敛 —— 只在 **`Address Editor`** 里显示成
`Incomplete Paths`。很容易一路跑到底才发现。

检查方法：BD 文件里搜 `M_AXI_S2MM` —— 正常应出现 2 次
（引脚声明 + 连线），只出现 1 次就是没连。

对照：`vivado/bd_sobel.tcl` 建互联时显式写了
`CONFIG.NUM_SI {2}` 并连了 `S01_AXI`，还有引脚存在性断言，
不会静默放过。GUI 流程需要手动补，见 `docs/GUI复现指南.md` §2.9b。

---

## 10. 参考

- Vitis HLS 接口杂注：UG1399 *Vitis High-Level Synthesis User Guide*
- AXI DMA 驱动：PG021 *AXI DMA v7.1 LogiCORE IP Product Guide*
- Zynq cache 一致性：UG585 *Zynq-7000 TRM* 第 3 章
