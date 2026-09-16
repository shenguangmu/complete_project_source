# 手势识别系统 —— GUI 复现指南

用鼠标搭出**视频采集 → 预处理 → HDMI 显示**的 PL 流水线。
全程 Vivado GUI，不需要敲 Tcl 命令。

> **适用范围**：从**加入 RTL 源**到**综合实现**这一段。
>
> **HLS 部分不在这里** —— 那一块见
> `E:\project\docs\GUI复现指南.md`（原 Sobel 工程的指南，已实机验证过）。
> 里面的 HLS 组件操作（建组件、填向导、跑 csim/csynth、导出 IP）
> 与本项目完全通用，只是文件名换成 `gesture_preproc.cpp` /
> `tb_gesture.cpp` / `gesture_config.cfg`。
>
> **适用工具版本**：Vivado / Vitis **2025.2**
> **对照**：命令行版本 `vivado/bd_video.tcl` —— 本文每一步都能在
> Tcl Console 里看到对应命令，出错时可直接对照

---

## 0. 先搞清楚：GUI 走不到哪里

**必须承认的边界**：GUI 能搭出 BD、能 validate、能生成比特流，
但**摄像头和 HDMI 的引脚约束（XDC）必须写文件** —— 那 14 根线
不可能靠拖拽确定物理引脚。

所以本文分两部分：
- **第一～五部分**：加入 RTL 源 → 搭 BD → 验证 → 约束 → 综合（GUI 能做）
- **第六部分**：上板（含前置条件与验证顺序）

> ⚠ 本文**不含 HLS 部分**（建组件、跑 csim/csynth、导出 IP）。
> 那一块见 `E:\project\docs\GUI复现指南.md`，与本项目通用。

### 0.1 前置：先跑一遍命令行版

GUI 里最容易出问题是**漏连**（时钟、复位、AXI 通路）。
漏连的后果是"综合实现比特流全过，上板才炸"。

所以**建议先跑一次命令行版**，拿到一个已知正确的参照：

```bash
vivado -mode batch -source vivado/test_bd_video.tcl
```

看到 `测试完成 — BD 构建成功` 说明参照可用。GUI 搭完后
可以和它逐项对照（见 §3 检查清单）。

### 0.2 设好 `XILINX_VIVADO`

从 GUI 启动 Vitis/Vivado 会自动配好；只有在**命令行**调 HLS 时才需要手动设。

典型症状（导出 IP 那一步失败，但前面综合全都成功）：

```
INFO:  [IMPL 213-8] Exporting RTL as a Vivado IP.
ERROR: [IMPL 213-4] Cannot find Vivado, please check XILINX_VIVADO
      environment variable: D:\vivado_new\2026.1\Vivado
```

> ⚠ 报错里的路径**可能不是你装的版本** —— 本机曾经装过 2026.1 但没装完，
> 环境变量残留了旧路径。设成当前实际安装路径覆盖掉它：
>
> ```bash
> export XILINX_VIVADO=D:/BaiduNetdiskDownload/2025.2/Vivado
> ```
>
> 详见 `E:\project\docs\GUI复现指南.md` §0.2。

---

## 第一部分：把 RTL 加进工程

`rtl/` 下三个文件是**手写 Verilog**，不属于任何 IP 仓库，
必须先作为设计源加入，BD 里才能例化。

### 1.1 打开工程

`File > Open Project` → 选 `vivado/sobel_system.xpr`。

> 没有工程就先跑 `vivado/create_project.tcl` 生成一个。

### 1.2 加入 RTL 源

`Sources` 面板 → 右键 `Design Sources` → **`Add Sources`** →
选 **`Add or create design sources`** → `Next`。

在 `Add Files` 页点 **`Add Files`**，选这**五个**（都在 `rtl/` 下）：

```
rtl/dvp_capture.v      DVP 采集
rtl/async_fifo.v       跨时钟域 FIFO（被 dvp_capture 例化）
rtl/sccb_master.v      SCCB 配置主控
rtl/iobuf_wrap.v       SDA 三态缓冲包装
rtl/ov5640_regs.v      寄存器配置表 ROM
```

> ⚠ **不要勾选 `Copy sources into project`**。保持文件在 `rtl/` 原地，
> 这样以后改 RTL 不用两边同步。
>
> ⚠ 五个都要加 —— 漏了 `async_fifo.v` 会导致 `dvp_capture` 找不到依赖，
> 漏了 `iobuf_wrap.v` 会让 SDA 双向缓冲无法例化。

`Finish`。

### 1.3 确认模块被识别

展开 `Design Sources`，应能看到**五个**模块名。若没有，
右键工程 → `Refresh Hierarchy`。

---

## 第二部分：搭 Block Design

### 2.1 新建 BD

`Flow Navigator` → `IP INTEGRATOR` → **`Create Block Design`**。

| 字段 | 填什么 |
|---|---|
| Design name | `bd_video` |

> ⚠ **不要叫 `bd_sobel`** —— 原 Sobel BD 要保持不动作为对照。

### 2.2 加 Zynq PS 并**手工配置 HP 口**（最容易错的一步）

画布中央点 **`Add IP`**（或按 `Ctrl+I`），搜索 `ZYNQ7 Processing System`，
双击加入。

**双击 `processing_system7_0` 打开配置**，先不要点任何 `Run Block Automation`。

左侧 `PS-PL Configuration` → 展开 `AXI Non Secure Enablement` → `Slave Interface`：

| 选项 | 值 |
|---|---|
| `S AXI HP0 interface` | ✅ 勾上 |
| `S AXI HP1 interface` | ✅ 勾上 |
| `S AXI HP2 interface` | ✅ 勾上 |
| `S AXI HP3 interface` | ⬜ 不勾 |

`Master Interface` 那一栏：`M AXI GP0 interface` ✅ 勾上。

**点 `OK` 保存。**

> ### ⚠⚠ 这一步的坑（务必读完）
>
> **不要用 `Run Block Automation` 的 `apply_board_preset`。**
>
> 它会把 PS7 **整个重置**成板卡预设，**覆盖掉你刚勾的 HP0/HP1/HP2**。
> 后果是后面 `connect` 时报一句
> `Arguments ... cannot be empty`，
> **而报错位置在你操作的位置之后几十行**，极难往回查。
>
> 原工程踩过这个坑，记在 `README.md` §9.7。
>
> 如果确实需要板卡预设（比如带出 DDR 型号）：
> 先 `Run Block Automation`，**然后再回来重新勾 HP 口**。

### 2.3 加其余 IP

按 `Ctrl+I`，依次搜索并双击加入（共 4 个）：

| 搜索名 | 加入的 IP | 改名为 |
|---|---|---|
| `AXI Direct Memory Access` | AXI VDMA | `vdma` |
| `Video Timing Controller` | v_tc | `v_tc` |
| `AXI4-Stream to Video Out` | v_axi4s_vid_out | `v_axi4s_vid_out` |
| `Processor System Reset` | proc_sys_reset | `rst_100m` |

> ⚠ 我们要的是 **VDMA**（Video DMA）不是普通 `AXI Direct Memory Access`。
> 搜索时认准名字里的 **V**。

### 2.4 配置 VDMA

双击 `vdma`，按下面设置：

| 页面 | 字段 | 值 |
|---|---|---|
| Basic | `Enable` 里 MM2S / S2MM | **两个都勾** |
| Basic | `Number of Frame Stores` | `3` |
| Advanced | `Enable Scatter Gather Engine` | **不勾**（简单模式） |
| Advanced | MM2S `Stream Data Width` | `16` |
| Advanced | MM2S `Line Buffer Depth` | `2048` |
| Advanced | S2MM `Stream Data Width` | `16` |
| Advanced | S2MM `Line Buffer Depth` | `2048` |
| Advanced | `Memory Map Data Width` | `64` |

**`OK` 保存。**

> `16` 是 RGB565 的位宽，一拍一个像素。
> `3` 帧缓存是为了避免"正在写的时候被读"造成的画面撕裂。

### 2.5 配置 VTC

双击 `v_tc`：

| 字段 | 值 |
|---|---|
| `Enable Detection` | **不勾** |
| `Generator Video Format` | **`480p`** |

**`OK` 保存。**

> ⚠⚠ **`Generator Video Format` 的下拉里没有 `640x480` 这个选项。**
> 只有 `720p` / `480p` / `1080p` / `Custom`。
> **640×480 对应 `480p`** —— 选 `Custom` 也行但要多填一堆时序参数。
>
> 命令行版写 `VIDEO_MODE {640x480}` 会直接报
> `[IP_Flow 19-3461] Value '640x480' is out of the range`。

### 2.6 配置 v_axi4s_vid_out（**位宽必须改，否则颜色全错**）

双击 `v_axi4s_vid_out`，找到 **`Video Format`**（在 `C_S_AXIS_VIDEO_FORMAT`）：

| 值 | 输出的 tdata 位宽 |
|---|---|
| **Format 0** | **16** ← **选这个** |
| Format 1 / 2 | 24 |

**选 `Format 0`**，`OK`。

> ⚠ **默认是 24 位（RGB888），与 VDMA 出来的 16 位（RGB565）不匹配。**
> 不改会看到：
> ```
> [BD 41-2384] Width mismatch when connecting pin:
>   '/v_axi4s_vid_out/s_axis_video_tdata'(24) to pin:
>   '/vdma/m_axis_mm2s_tdata'(16)
>   - Only lower order bits will be connected.
> ```
> **这只是一条 WARNING，不阻塞流程** —— 但"只连低位"意味着
> **颜色会整体错位**。这类"能连上但数据错"的警告最不能忽略。
>
> 画布上悬停能看到端口位宽，改对了应该是 `[15:0]`。

### 2.7 例化摄像头相关模块（**共 4 个，比早期方案多 3 个**）

按 `Ctrl+I`，在搜索框输入模块名，从 **`Modules`** 分类双击加入：

| 搜索 | 实例名 | 作用 |
|---|---|---|
| `dvp_capture` | `dvp_capture_0` | DVP 采集 → AXIS |
| `sccb_master` | `sccb_0` | SCCB 配置摄像头 |
| `ov5640_regs` | `ov5640_regs_0` | 寄存器配置表 ROM |
| `iobuf_wrap` | `iobuf_sda_0` | SDA 三态缓冲 |

再加一个 **IP**（不是 module）：`Ctrl+I` 搜 `Clocking Wizard`，
实例名 `clk_wiz_xclk`，配置见 §2.7b。

> 若搜不到 module，回到 §1.2 确认 5 个 .v 文件都加进了 `Design Sources`。

#### 2.7b 配置 Clocking Wizard

双击 `clk_wiz_xclk`：

| 页面 | 字段 | 值 |
|---|---|---|
| Clocking Options | `Primitive` | **MMCM** |
| Clocking Options | `Primary Input Frequency` | `100.000` MHz |
| Output Clocks | `CLK_OUT1 Requested` | `24.000` MHz |
| Output Clocks | `Reset Type` | **Active Low** |

**`OK` 保存。**

> ⚠ **为什么需要它**：PMOD-CAMERA v1.0 **没有板载晶振**，
> XCLK 必须由 FPGA 产生。
>
> ⚠ **100 → 24 MHz 不是整数分频**，所以必须用 MMCM 而不是简单分频。
> 工具会自动解出 M=12 / D=1 / O=50（VCO = 1200 MHz）。
> 若它报"无法合成"，手动填这三项。

### 2.8 连时钟（**最容易漏，务必逐条对**）

先从 PS 拖出时钟：把 `processing_system7_0` 的 **`FCLK_CLK0`** 接到
`rst_100m` 的 **`slowest_sync_clk`**，再把 `FCLK_RESET0_N` 接到
`rst_100m` 的 **`ext_reset_in`**。

然后 `FCLK_CLK0` 要接到**下面每一个**时钟引脚：

```
processing_system7_0/M_AXI_GP0_ACLK
processing_system7_0/S_AXI_HP0_ACLK
processing_system7_0/S_AXI_HP1_ACLK
processing_system7_0/S_AXI_HP2_ACLK

（每个 AXI Interconnect 都有 4 个时钟引脚，逐个接）
ACLK / S00_ACLK / M00_ACLK / M01_ACLK

vdma/s_axi_lite_aclk
vdma/m_axi_mm2s_aclk
vdma/m_axi_s2mm_aclk
vdma/s_axis_s2mm_aclk
vdma/m_axis_mm2s_aclk

v_tc/clk
v_tc/s_axi_aclk        ← VTC 有【两个】时钟域，别漏
v_axi4s_vid_out/aclk
dvp_capture_0/aclk
```

> ### ⚠⚠ 为什么单独列出来
>
> **AXI Interconnect 的时钟是"每端口一个"的。**
> `ACLK` 是全局的，但 `S00_ACLK` / `M00_ACLK` / `M01_ACLK`
> **必须逐个连**。只连 `ACLK` 会报：
> ```
> [BD 41-758] The following clock pins are not connected to a valid clock source:
> /ic_ctrl/S00_ACLK
> /ic_ctrl/M00_ACLK
> ...
> ```
>
> 同样，**PS 的 `M_AXI_GP0_ACLK` / `S_AXI_HP*_ACLK` 也不会自动跟随 `FCLK_CLK0`**。

### 2.9 连复位（**同为重灾区**）

`rst_100m` 的 **`peripheral_aresetn`** 接到下面每一个：

```
（每个 AXI Interconnect 的复位，同样是每端口一个）
ARESETN / S00_ARESETN / M00_ARESETN / M01_ARESETN

vdma/axi_resetn
v_tc/resetn
v_axi4s_vid_out/aresetn
dvp_capture_0/rst_n
```

> ### ⚠⚠ 漏连复位比漏连时钟更危险
>
> 漏连的 `ARESETN` 会被 Vivado **自动 tie-off 到 0**
> （validate 时报 `[BD 41-759]` CRITICAL WARNING）。
>
> 后果：**AXI 互连永远处于复位状态，事务一条都过不去。**
> 而 **综合、实现、生成比特流全部会正常通过** —— 只有上板才暴露。
>
> 看到 `[BD 41-759]` 不要跳过，逐条接上。

### 2.10 加 AXI Interconnect

`Ctrl+I` 搜索 `AXI Interconnect`，加 **4 个**：

| 实例名 | 用途 | 配置 |
|---|---|---|
| `ic_ctrl` | PS 配 IP 的控制通路 | `NUM_SI=1`, **`NUM_MI=5`** |
| `ic_hp1` | 采集数据写 DDR | `NUM_SI=1`, `NUM_MI=1` |
| `ic_hp2` | 显示数据读 DDR | `NUM_SI=1`, `NUM_MI=1` |
| `ic_hp3` | **预处理链的两次 DMA** | **`NUM_SI=2`**, `NUM_MI=1` |

> ⚠ **`ic_ctrl` 必须开 5 个主口**（不是 2 个）：
> M00=vdma、M01=v_tc、**M02=gesture_preproc、M03=dma_in、M04=dma_out**。
> 少开导致悬空、多开导致空口 —— 两者都会在 validate 时暴露。
>
> ⚠ **`ic_hp3` 是 2 个从口 1 个主口**：`dma_in` 的 MM2S 与
> `dma_out` 的 S2MM 各占一个从口，主口接 `ps7/S_AXI_HP3`。
>
> ⚠⚠ **PS 要开 HP3**。回 §2.2 的 PS 配置里勾上
> `S AXI HP3 interface`。漏勾的话后面连 `ps7/S_AXI_HP3` 会报
> `Arguments ... cannot be empty`，而报错位置离真正原因很远。

> **为什么 MM2S 和 S2MM 要分开占两个 HP 口？**
> 摄像头持续写入约 18 MB/s，HDMI 读出同样量级，
> 挤在同一个 HP 口上会互相争抢。分开后各自独立，
> 也便于用 ILA 单独观察。
>
> **为什么预处理链单独占 HP3？**
> 它每帧要读 614400 字节再写 9216 字节。虽然流量比显示通路小
> （10fps 时约 6 MB/s），但和显示通路共用会互相影响 ——
> 尤其会让"处理一帧"的时间变得不可预测。

### 2.10b 加预处理链（gesture_preproc + 两个 DMA）

这是 **CNN 通路**，与显示通路完全独立。

**先加 HLS 导出的 IP**（见 §2.3 的 IP Catalog 步骤），
VLNV 是 `user:hls:gesture_preproc:1.0`，实例名 `gesture_preproc_0`。

> ⚠ 加不进来的话，确认 IP 仓库路径已注册：
> `gesture_comp/solution1/impl/ip`
> （`update_ip_catalog -rebuild` 之后才会出现在搜索里）

`Ctrl+I` 再加两个 **AXI DMA**（普通 DMA，不是 VDMA）：

| 搜索 | 实例名 | 配置 |
|---|---|---|
| `AXI Direct Memory Access` | `dma_in` | 只勾 **MM2S**；Stream 位宽 **16**；MM 位宽 32 |
| `AXI Direct Memory Access` | `dma_out` | 只勾 **S2MM**；Stream 位宽 **8**；MM 位宽 32 |

> ⚠ **位宽不能设错**：
> - `dma_in` 搬的是 RGB565，Stream 侧 **16 bit**
> - `dma_out` 搬的是 96×96 灰度，Stream 侧 **8 bit**
> - 两个的 MM（DDR 侧）都是 **32 bit**
>
> 位宽设错不会报错，只会**数据错位**。

**连线**：

| 从 | 到 |
|---|---|
| `ic_ctrl/M02_AXI` | `gesture_preproc_0/s_axi_control` |
| `ic_ctrl/M03_AXI` | `dma_in/S_AXI_LITE` |
| `ic_ctrl/M04_AXI` | `dma_out/S_AXI_LITE` |
| `dma_in/M_AXI_MM2S` | `ic_hp3/S00_AXI` |
| `dma_out/M_AXI_S2MM` | `ic_hp3/S01_AXI` |
| `ic_hp3/M00_AXI` | `ps7/S_AXI_HP3` |
| `dma_in/M_AXIS_MM2S` | `gesture_preproc_0/src` |
| `gesture_preproc_0/dst` | `dma_out/S_AXIS_S2MM` |

> ⚠ **`src` / `dst` 是 HLS 的端口名**（C 函数参数名），
> 不是 `s_axis` / `m_axis`。HLS 2025.2 用参数名命名 axis 端口。

### 2.11 连接数据通路

| 从 | 到 |
|---|---|
| `ps7/M_AXI_GP0` | `ic_ctrl/S00_AXI` |
| `ic_ctrl/M00_AXI` | `vdma/S_AXI_LITE` |
| `ic_ctrl/M01_AXI` | `v_tc/ctrl` |
| `dvp_capture_0/m_axis` | `vdma/S_AXIS_S2MM` |
| `vdma/M_AXI_S2MM` | `ic_hp1/S00_AXI` |
| `ic_hp1/M00_AXI` | `ps7/S_AXI_HP1` |
| `vdma/M_AXIS_MM2S` | `v_axi4s_vid_out/video_in` |
| `vdma/M_AXI_MM2S` | `ic_hp2/S00_AXI` |
| `ic_hp2/M00_AXI` | `ps7/S_AXI_HP2` |
| `v_tc/vtiming_out` | `v_axi4s_vid_out/vtiming_in` |

> ⚠ **`v_axi4s_vid_out` 不需要 AXI-Lite** —— 它只有
> `vid_io_out` / `video_in` / `vtiming_in` 三个接口，**纯流式，无需配置**。
> 所以 `ic_ctrl` 只开 2 个主口，别多开一个悬空。

### 2.12 引出摄像头信号（外部端口）

⚠⚠ **端口名是 `io_*` 不是 `cam_*`** —— 因为这块模块的
**XCLK 要 FPGA 输出、SDA 是双向**，不能用全输入的命名。

**输入端口**（右键 `dvp_capture_0` 对应引脚 → `Make External`）：

| 端口 | 方向 | 位宽 | 来源 |
|---|---|---|---|
| `io_pclk` | 输入 | 1 | `dvp_capture_0/pclk` |
| `io_vsync` | 输入 | 1 | `dvp_capture_0/cam_vsync` |
| `io_href` | 输入 | 1 | `dvp_capture_0/cam_href` |
| `io_d` | 输入 | **8**（改 `[7:0]`） | `dvp_capture_0/cam_data` |

**输出端口**（右键对应引脚 → `Make External`）：

| 端口 | 方向 | 来源 |
|---|---|---|
| `io_xclk` | **输出** | `clk_wiz_xclk/clk_out1` |
| `io_scl` | **输出** | `sccb_0/scl` |

**双向端口**：

| 端口 | 方向 | 来源 |
|---|---|---|
| `io_sda` | **双向** | `iobuf_sda_0/io_pad` |

> ⚠ **`io_pclk` 必须设频率**（它是输入时钟）：
> ```tcl
> set_property CONFIG.FREQ_HZ 24000000 [get_bd_ports io_pclk]
> ```
> 不设会在 validate 时报 `[BD 5-670]`。
>
> ⚠ **输出/双向端口不要设 FREQ_HZ** —— 它们不是时钟输入。
>
> ⚠ **不要额外引复位端口**。`dvp_capture` 只有一个 `rst_n`，
> 已由 `peripheral_aresetn` 驱动，再连一次会报
> `[BD 5-676] The sink is already connected to another source`。

**别忘了连 SCCB 的内部连线**（这些不是外部端口，是模块之间）：

| 从 | 到 |
|---|---|
| `sccb_0/tbl_addr` | `ov5640_regs_0/tbl_addr` |
| `ov5640_regs_0/tbl_data` | `sccb_0/tbl_data` |
| `sccb_0/sda_oe` | `iobuf_sda_0/io_drv` |
| `sccb_0/sda_o` | `iobuf_sda_0/io_out` |
| `iobuf_sda_0/io_in` | `sccb_0/sda_i` |

> ⚠ **别把 `io_drv` / `io_in` / `io_out` 当成外部端口** ——
> 它们是 `iobuf_wrap` 的**内部引脚**，在上面的连线里作为目标出现。
> 唯一要引出到外部的是 **`io_pad`**（重命名为 `io_sda`，见上表）。
>
> 这两个名字很像，但用途完全不同：
>
> | 名字 | 在哪 | 作用 |
> |---|---|---|
> | `iobuf_sda_0/io_pad` | 模块引脚 | **引出为外部端口 `io_sda`** |
> | `iobuf_sda_0/io_drv` / `io_in` / `io_out` | 模块引脚 | 只在 BD 内部连到 `sccb_0` |

> ⚠ `tbl_addr` 两边**位宽必须一致**（都是 8 位）。
> 不一致会报 `[BD 41-2383] Width mismatch`，高位置悬空 ——
> 表一旦超过 2^位宽 项就会**静默读错**。

### 2.13 引出 HDMI 输出

右键 `v_axi4s_vid_out` 的 **`vid_io_out`** 接口 → **`Make External`**。

重命名为 `hdmi_vid_out`。

> ⚠ **`vid_io_out` 是接口（interface）不是散引脚** ——
> 找不到 `vid_data` / `vid_hsync` 这些名字，这是正常的。
>
> ⚠ **TMDS 编码这一步本 BD 故意没做。**
> `vid_io_out` 出来的是**并行视频信号**，HDMI 需要的是 TMDS 差分对
> （8b/10b 编码）。这一步作为独立模块下一步做 ——
> 把它塞进这个 BD 会让"数据通路是否通"和"HDMI 能否显示"两个问题纠缠。

### 2.14 地址分配

切到 **`Address Editor`** 标签页，右键 → `Assign All`。

应自动得到（与命令行版一致）：

| 从设备 | 地址 |
|---|---|
| `vdma/S_AXI_LITE` | `0x4300_0000` |
| `v_tc/ctrl` | `0x43C0_0000` |

**记下这两个地址** —— 写 PYNQ 驱动或裸机程序时要用。
也可以从导出的 `.hwh` 里读（别手抄，见 §4）。

---

## 第三部分：验证

### 3.1 Validate（必做）

工具条 **`Validate Design`**（`F6`）。

**弹窗显示 "Validation successful" 还不够** —— 必须去
底部 **`Messages`** 面板，把 `CRITICAL WARNING` **逐条读完**。

### 3.2 检查清单

| 检查项 | 应该是什么 | 不符怎么办 |
|---|---|---|
| `[BD 41-758]` 时钟未连接 | **没有** | §2.8 逐条补 |
| `[BD 41-759]` 输入引脚悬空 | **没有** | §2.9 逐条补（**危险！**） |
| `[BD 41-2384]` 位宽不匹配 | **没有** | §2.6 把格式改成 0 |
| `[BD 41-676]` 重复驱动 | **没有** | §2.12 删掉多余的 `cam_rst_n` |
| Address Editor 的 `Incomplete Paths` | **没有** | 有则说明该通路上有主设备悬空 |

> **`Incomplete Paths` 是最容易被忽略的一项** ——
> Validate 不查它，综合实现也不报错，只在 Address Editor 里显示。
> 板上表现为数据写不回 DDR、程序挂死。

### 3.3 把检查命令化（推荐）

GUI 里逐条核对很累，可以**只跑验证部分**的 Tcl。
在 `Tcl Console`（Vivado 底部）粘贴：

```tcl
validate_bd_design

# 查所有 AXI 互连的主/从口是否都有连接
foreach c [get_bd_cells -filter {NAME =~ "ic_*"}] {
    foreach ip [get_bd_intf_pins -of_objects $c] {
        set inm [get_property NAME $ip]
        if {[string match "*_AXI" $inm]} {
            if {[llength [get_bd_intf_nets -of_objects $ip]] == 0} {
                puts "悬空: [get_property NAME $c]/$inm"
            }
        }
    }
}
puts "检查完毕 —— 上面没有输出就是全接了"
```

### 3.4 生成 wrapper

1. `Ctrl+S` 保存
2. `Sources` 面板右键 `bd_video.bd` → **`Create HDL Wrapper`**
3. 选 `Let Vivado manage wrapper and auto-update` → `OK`

---

## 第四部分：约束与综合

### 4.1 引脚约束（**GUI 做不了，必须写文件**）

摄像头 14 根 + HDMI 的物理引脚**只能写 XDC**。

**好消息：摄像头那部分已经写好了**，直接加进工程即可：

```
vivado/constraints/video_io.xdc
```

加入方式：`Sources` → 右键 `Constraints` → `Add Sources` → 选该文件。

**里面已经包含**（端口名 `io_*`）：

| 内容 | 说明 |
|---|---|
| PCLK 时钟（24 MHz） | `create_clock` |
| 跨时钟域声明 | PCLK ↔ sysclk 异步 |
| **14 个摄像头引脚** | J2→Pmod A、J3→Pmod B |
| SCCB 上拉 | `io_sda` / `io_scl` |
| 输入延时 | DVP 源同步接口 |

> ⚠⚠ **上电前必须万用表复核引脚** —— 模块原理图是"镜像编号"，
> XDC 按镜像解读推导，但**未经实测**。
> 插错方向会 **3V3/GND 反接烧板**。
> 步骤见 `video_io.xdc` 末尾的「上电前验证」章节。

**HDMI 那部分还是模板**（第四层，注释状态）—— 因为 BD 里还没有
TMDS 编码器和像素时钟输出，端口数量对不上，补齐后才能启用。

> ⚠ **`iobuf_wrap.v` 需要额外的 XDC 约束吗？**
> 不需要。`IOBUF` 原语会由 Vivado 自动推断成 IOB 上的三态缓冲，
> 只要引脚约束写了 `IOSTANDARD` 就行。

### 4.2 综合与实现

`Flow Navigator` → **`Generate Bitstream`**
（会自动跑完 Synthesis + Implementation）。

约几十分钟。完成后选 `View Reports`。

> **时序不收敛时**：先看 `Implementation` → `Report Timing Summary`，
> 再决定是降频还是加流水级。
>
> ⚠ **先跑一次综合看资源**。参考值（2026-09-15 实测，含全部模块）：
> LUT 24.11% / FF 14.86% / BRAM 18.21% / **DSP 27.73%**。
> 如果实测明显偏离，多半是某个模块没被正确加入。

---

## 第五部分：常见问题

### 报"Arguments ... cannot be empty"

**八成是 PS7 的接口被覆盖了。** 回到 §2.2，
确认 `S_AXI_HP1` / `S_AXI_HP2` 还在配置里。

这个报错的特点是**位置在你操作的地方之后几十行**，
看到它先往回翻，查 PS 配置。

### 画布上连线是红色虚线

协议不匹配。最常见是位宽没设对 —— 查 §2.4（VDMA 的 Stream Data Width）
和 §2.6（`v_axi4s_vid_out` 的 Format）。连对了应该是**深色实线**。

### 找不到 `vid_io_out` 这个引脚

它是**接口**不是引脚。在画布上 IP 的边框上找那个粗边的小方块，
悬停会显示接口名。

### validate 过了但上板不通

**九成是 `[BD 41-759]` 那类悬空** —— 见 §3.2 的检查清单。
这类问题的特征：**所有工具流程都通过，只有真实硬件不工作。**

### 想对照命令行的正确版本

打开 `vivado/bd_video.tcl`，每一步都有注释说明**为什么这么连**。
本文的每一步在 Tcl Console 里都会留下对应的 `connect_bd_*` 命令，
两相对照即可。

---

## 附录：完整数据通路

```
   OV5640
      │ DVP（8bit 数据 + PCLK/HREF/VSYNC）
      ▼
 dvp_capture_0 ──AXIS(16bit RGB565)──► vdma/S_AXIS_S2MM
                                            │
                                      (3 帧缓存)
                                            │
            ┌───────────────────────────────┘
            │
            ├──► vdma/M_AXI_S2MM ──► ic_hp1 ──► ps7/S_AXI_HP1 ──► DDR
            │
            └──► vdma/M_AXI_MM2S ◄── ic_hp2 ◄── ps7/S_AXI_HP2 ◄── DDR
                        │
                        ▼
              vdma/M_AXIS_MM2S ──AXIS(16bit)──► v_axi4s_vid_out/video_in
                                                      │
                                            v_tc/vtiming_out ──► vtiming_in
                                                      │
                                                      ▼
                                              vid_io_out（并行视频）
                                                      │
                                          【TMDS 编码 —— 未做，下一步】
                                                      ▼
                                                  HDMI 输出

  PS 控制（GP0）──► ic_ctrl ──┬──► vdma/S_AXI_LITE   (0x4300_0000)
                              └──► v_tc/ctrl         (0x43C0_0000)
```

### 已经接进 BD 的模块（对照用）

| 模块 | 在 BD 里的位置 |
|---|---|
| `sccb_master` + `ov5640_regs` + `iobuf_wrap` | 见 §2.7、§2.12（SCCB 通路） |
| `gesture_preproc` + `dma_in` + `dma_out` | 见 §2.10b（CNN 通路） |
| Clocking Wizard | 见 §2.7b（产生 24MHz XCLK） |

### 仍然没做的

| 项 | 为什么 |
|---|---|
| **HDMI 的 TMDS 编码** | `vid_io_out` 出来的是**并行视频**，HDMI 需要 TMDS 差分对。而且 BD 里没有像素时钟输出（`vid_io_out` 不携带时钟），补齐要加 MMCM + 编码器 |
| **OV5640 寄存器表** | `rtl/ov5640_regs.v` 目前是**占位表**，不足以让摄像头出图 |

---

## 第六部分：上板

⚠ **上板前有两个前置条件**，缺一不可：

| 前置 | 说明 |
|---|---|
| **摄像头寄存器表** | `rtl/ov5640_regs.v` 是占位表。不换真表，`io_pclk` 永远没波形 |
| **引脚万用表复核** | 模块原理图是镜像编号，映射是**推理**出来的。**插错会烧板** |

### 6.1 生成比特流

```bash
vivado -mode batch -source vivado/create_project.tcl
```

它会**从头建工程** → 建 BD → 综合 → 实现 → 生成比特流 → 导出 XSA。
约 20–40 分钟。

产出：
```
vivado/gesture_system/gesture_system.xsa      ← 含比特流
vivado/gesture_system/utilization.rpt         ← 资源报告
```

> ⚠ 只想先看 BD 是否合法（不跑实现，约 1 分钟）：
> ```bash
> vivado -mode batch -source vivado/create_project.tcl -tclargs --synth 0
> ```

### 6.2 加载到板子

两条路，**取决于有没有 PYNQ 镜像**：

| | PYNQ 路线（推荐） | 裸机路线 |
|---|---|---|
| 镜像 | PYNQ（SD 卡） | 无 |
| 加载 | `Overlay("x.bit")` | JTAG 下载 |
| 驱动 | **Python**（`host/gesture_overlay.py`） | 编译 `sw/preproc_driver.c` |
| 调试 | Jupyter 看图 | UART printf |

**PYNQ 路线**（推荐）：
```python
from gesture_overlay import GesturePipeline
g = GesturePipeline()
g.print_info()          # 先看 IP 认出来没有
g.setup_dma()
g.config()
g.fill_test_pattern()   # 无摄像头时也能验证数据通路
g.run_once()
g.show()                # Jupyter 里出图
```

> ⚠ **PYNQ 镜像与本项目 Vivado 版本的兼容性未验证**。
> 报版本错误时加 `ignore_version=True`。

### 6.3 验证顺序（省时间的关键）

上电后**按这个顺序查**，能快速区分"FPGA 没工作"和"摄像头没配上"：

```
① io_xclk 有没有 24 MHz      ← FPGA 侧（Clocking Wizard 输出）
② io_scl 有没有在跑           ← SCCB 在工作
③ io_pclk 有没有波形          ← 有 = 摄像头配置成功，无 = 配置失败
④ io_href / io_vsync 有没有脉冲
⑤ 最后才查数据线
```

**前两步把问题范围砍掉一半**：
- ① 没有 → 是 PL 的时钟问题，与摄像头无关
- ① 有、② 有、③ 没有 → SCCB 没配上，去查 `sccb_master.cfg_error`
  和寄存器表内容

### 6.4 结果对拍

板上跑出来的 96×96 结果，与 PC 上的 golden 对比：

```bash
# 板上（Jupyter 里）
g.stats()
g.out_buf.tofile("board.bin")

# PC 上
python host/dump_frame.py stats board.bin
python host/dump_frame.py compare board.bin golden.bin
```

数据格式是**裸 .bin，96×96 uint8，9216 字节**（见 `host/README.md`）。
