# 综合与实现报告

> 赛题 §3.3.5.1 要求提交「综合与实现报告，含**资源占用、时钟频率与关键性能指标**」。
>
> **本文是摘要**；原始报告在工程目录下（未入版本库，可重跑生成）：
>
> | 原始报告 | 路径（重跑后生成） |
> |---|---|
> | 资源占用 | `vivado/gesture_system/utilization.rpt` ← **已入库** |
> | 时序摘要（702 KB） | `vivado/gesture_system/gesture_system.runs/impl_1/bd_video_wrapper_timing_summary_routed.rpt` |
> | DRC | `.../impl_1/bd_video_wrapper_drc_routed.rpt` |
> | 功耗 | `.../impl_1/bd_video_wrapper_power_routed.rpt` |

## 构建环境

| 项 | 值 |
|---|---|
| 工具 | **Vivado 2025.2**（赛题允许 2026.1，本项目用 2025.2） |
| 器件 | `xc7z020clg400-1`（PYNQ-Z2） |
| 顶层 | `bd_video_wrapper` |
| 综合/实现 | **0 error / 0 critical warning** |
| 比特流 | 4,045,692 字节，`Bitgen Completed Successfully` |

> ⚠ **重跑命令**：`vivado -mode batch -source vivado/create_project.tcl`
> （前置：先跑 `vitis-run --mode hls --tcl src_hls/run_gesture.tcl`，
> 因为 BD 需要 HLS 导出的 IP —— 详见根 `README.md`）

---

## 一、资源占用

来自 `utilization.rpt`（Design State: **Routed**）：

| 资源 | 用量 | 可用 | 占比 |
|---|---|---|---|
| Slice LUTs | **11,255** | 53,200 | **21.16%** |
| └ LUT as Logic | 10,456 | 53,200 | 19.65% |
| └ LUT as Memory | 799 | 17,400 | 4.59% |
| Slice Registers | 14,810 | 106,400 | **13.92%** |
| **DSPs**（DSP48E1） | **61** | 220 | **27.73%** |
| **Block RAM Tile** | **25.5** | 140 | **18.21%** |
| **Bonded IOB** | **35** | 125 | **28.00%** |
| BUFGCTRL | 4 | 32 | 12.50% |
| MMCME2_ADV | 1 | 4 | 25.00% |
| └ RAMB36/FIFO | 15 | 140 | 10.71% |
| └ RAMB18 | 21 | 280 | 7.50% |

> 数据取自 `vivado/gesture_system/utilization.rpt`（Design State: **Routed**）。
>
> ⚠ 该表曾写错（LUT 11,178 / 21.01%，抄自旧报告）。
> **以仓库里 `utilization.rpt` 为准** —— 本表数字与它逐项核对过。

**DSP 占用 27.73%，来源已查明（2026-09-18 更正）**：

> ⚠ **本段原先写的完全不对**，原文是：
>
> > "HLS 预处理链里的 `thresh_stage` 用了**整数除法**，被映射到 DSP48E1
> > 的除法器。**这是已知且可量化的优化空间** —— 若改用移位近似，
> > DSP 占用可显著下降。"
>
> **三处都错**：
>
> 1. **不是 `thresh_stage`** —— 它只占 **2** 个 DSP。大头是 `morph_stage` 的 **56** 个。
> 2. **不是整数除法** —— 是腐蚀流水线的**索引乘法** `r1[yy * width + xx]`，
>    被综合成 3 个 **64×66→129 位**乘法器，各吃 16 个 DSP。
> 3. **"改用移位近似可显著下降"是错的建议** —— 实测手写移位/展开后
>    **DSP 从 71 涨到 86**，资源全面变差。
>
> **正确结论**：根因确凿（固定值探针可让它从 71 掉到 15），
> **但改不掉**（HLS 对归纳变量的范围推断不足）。
> 完整的 4 组对照实验见
> [`../src_hls/optimization-report.md`](../src_hls/optimization-report.md)。

---

## 二、时钟频率

来自 `timing_summary_routed.rpt` 的 Clock Summary：

| 时钟 | 周期 (ns) | 频率 (MHz) | 来源 |
|---|---|---|---|
| `clk_fpga_0` | 10.000 | **100.000** | PS7 `FCLK_CLK0` |
| `bd_video_i/clk_wiz_xclk/inst/clk_in1` | 10.000 | 100.000 | 同上（CW 输入） |
| `clk_out1_bd_video_clk_wiz_xclk_0` | 41.667 | **24.000** | Clocking Wizard 输出 → `io_xclk` |
| `cam_pclk` | 41.667 | **24.000** | 摄像头 PCLK（外部输入） |
| `clkfbout_...` | 50.000 | 20.000 | MMCM 反馈 |

**两个时钟域**：系统 100 MHz 与摄像头 24 MHz（`cam_pclk`），
跨域由 `async_fifo`（格雷码指针，标准 CDC 做法）处理。

> Clocking Wizard 参数：100 MHz → 24 MHz，
> **M=12 / D=1 / O=50，VCO = 1200 MHz**（非整数分频，必须用 MMCM）。

---

## 三、关键性能指标

### 3.1 时序

| 指标 | 值 | 判据 |
|---|---|---|
| **WNS**（最差建立裕量） | **+0.265 ns** | 正数 = 收敛 |
| **WHS**（最差保持裕量） | **+0.051 ns** | 正数 = 收敛 |
| TNS / THS | 0.000 / 0.000 | 0 个失败端点 |
| 结论 | ✅ **`All user specified timing constraints are met.`** | |
| 分析端点 | 40,239（建立）/ 35,302（保持） | |

> ### ⚠⚠ **`+0.265` 不是本设计的余量**（2026-09-18 查证）
>
> 一直引用这个数当"我们的时序余量"，**实际上它不是**。
> 查布线报告的 10 条最差 setup 路径，**全部属于
> `bd_video_v_tc_0`（AMD 视频时序控制器 IP）内部**：
>
> ```
> Slack (MET) :   0.265ns
>   Source / Target :  .../bd_video_v_tc_0/<hidden>/<hidden>/<hidden>
>   Logic Levels    :  1  (LUT3=1)
>   Data Path Delay :  9.764ns  (logic 0.642ns (6.6%)  route 9.122ns (93.4%))
>   net (fo=433, routed)  9.122ns        ← 扇出 433 的高扇出网
>   Timing Exception:  MaxDelay Path 10.000ns -datapath_only
> ```
>
> **逻辑只占 0.642 ns，布线占 9.122 ns** —— 是布线问题，不是逻辑深度问题；
> 且路径两端都在加密 IP 内部，**改我们的 RTL/HLS 对它零影响**。
>
> **本项目自己的流水线余量要大得多**：HLS csynth 估计
> `morph_stage` 腐蚀流水线可跑 **143.31 MHz**（目标 100 MHz），**余量 +43%**。
>
> **工程含义（更正）**：后续增加逻辑（如 TMDS 编码器）**不必**因这个数
> 而畏手畏脚 —— 它不是我们逻辑的约束。但仍应复查实现后的时序报告。
>
> 详见 [`../report/design.md` §4.5](../report/design.md) 与
> [`../src_hls/optimization-report.md`](../src_hls/optimization-report.md)。
>
> ### ⚠ **WNS 逐次波动大 —— 这不是噪声，是必须说明的事实**
>
> 同一设计**三次实现**的实测：
>
> | 次 | WNS |
> |---|---|
> | 1 | +0.873 ns |
> | 2 | +1.177 ns |
> | 3 | **+0.265 ns** |
>
> **布线是随机过程**，每次结果不同。而这条路径又恰好是
> **布线主导**（9.1 ns 布线 vs 0.64 ns 逻辑），所以波动更大。
>
> **不隐瞒这一点**：赛题 §3.3.4 要求"保证工程可由他人从零复现"。
> 他人重跑**会得到不同的 WNS**，这是正常的，不是复现失败。

### 3.2 吞吐量（设计目标，非实测）

| 通路 | 速率 | 计算依据 |
|---|---|---|
| 显示通路（VDMA 写 DDR） | ≈ 18 MB/s | 640×480×2 B × 30 fps |
| CNN 通路（预处理） | ≈ 6 MB/s | 614,400 B 读 + 9,216 B 写，10 fps |
| HP 口分配 | 各占独立口 | HP1 写 / HP2 读 / HP3 预处理 |

> ⚠ **这些是按设计参数推算的，不是实测值** —— 板子未到，无实测数据。
> 上板后应补：实际帧率、DMA 吞吐、预处理单帧耗时。

> 📌 关于"预处理 10 fps"这个设计值：按 `design.md` §4.4 的延迟估算，
> 预处理链单帧约 **21.4 ms**（`crop_scale` 占 97%），即**管道本身能跑约 47 fps**。
> 定成 10 fps 是**按 CNN 侧的消费速率取的保守值**，**不是管道上限** ——
> 也就是说这里有 **4 倍以上余量**。
> 实测帧率仍须上板确认（DMA 与 DDR 带宽的实际占比未知）。

### 3.3 未验证项（如实列出）

| 项 | 状态 |
|---|---|
| **板级实测** | ❌ **完全未做**（板子未到） |
| OV5640 配置表能否出图 | ⚠ 已换真表（250 条），**未上板验证** |
| PYNQ overlay 加载 | ⚠ 未验证（含镜像与 2025.2 的兼容性） |
| 功耗实测 | ⚠ 只有 Vivado 估算（`power_routed.rpt`），无实测 |

---

## 四、DRC

| 检查 | 结果 |
|---|---|
| 实现后 DRC | **0 Errors** |
| `NSTD-1` / `UCIO-1` | 各 1 条 Warning —— 22 个 `hdmi_vid_out_*` 端口**未约束**（TMDS 编码器未做） |
| 处理方式 | 走 `write_bitstream` 的 pre-hook 豁免（`constraints/hdmi_drc_hook.tcl`） |

> ⚠ **这 22 个端口在比特流里是悬空的。上板时不要接 HDMI 线。**
