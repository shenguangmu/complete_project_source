# 架构与接口契约

> 项目：基于 PYNQ-Z2 (XC7Z020) 的手势识别系统
> 日期：2026-09-14　｜　本文件是**分工边界**与**数据契约**的权威定义
>
> 起点：本工程拷贝自 `legacy/sobel`（已跑通的 Sobel 加速器），
> 原工程保持不动，作为可回滚的参照。

---

## 一、系统总览

```
                    ┌──────────────── PYNQ-Z2 (XC7Z020) ────────────────┐
                    │                                                   │
  OV5640            │   PL (可编程逻辑)              PS (Cortex-A9)      │
  ┌────────┐        │  ┌──────────────────┐        ┌─────────────────┐ │
  │ 500万   │  DVP   │  │ 采集 → 灰度 →    │        │ PYNQ Linux      │ │
  │ 摄像头  ├───────►│  │ 高斯 → Sobel →   │  DDR   │  + Jupyter      │ │
  │        │ 14根线 │  │ 自适应阈值 →     ├───────►│                 │ │
  └────────┘        │  │ 形态学 → ROI     │  512MB │  ┌───────────┐  │ │
                    │  └──────────────────┘        │  │ 轻量 CNN  │  │ │
                    │         ▲                    │  │ (他人负责) │  │ │
  ┌────────┐        │         │ VDMA               │  └───────────┘  │ │
  │ 显示器  │◄───────┤  HDMI Out (720p) ◄─────────┤                 │ │
  └────────┘        │                              │  结果叠加显示    │ │
                    └──────────────────────────────┴─────────────────┘ │
                    └───────────────────────────────────────────────────┘
```

### 分工边界（决策已定）

| 责任方 | 范围 | 交付物 |
|---|---|---|
| **本项目（你）** | PL 全部：DVP 采集、图像预处理链、VDMA、HDMI 输出、DDR 中继 buffer | bitstream / .hwh overlay + PL 侧驱动 |
| **他人** | PS 侧 CNN：模型训练、量化、推理、后处理 | 权重文件 + 推理代码，**只依赖 DDR 契约** |
| ~~不做~~ | ~~PL 侧 CNN 加速~~ | 已评估：见 §五 |

**边界只有一条**：DDR 里的 `gesture_input_buffer`（96×96 uint8 灰度）。
两侧各自把它当黑盒——**这是本项目最重要的设计决策**，
它让 CNN 侧可以在 PC 上独立开发调试，不受板子是否到货影响。

---

## 二、PL 处理链（本项目负责）

按数据流顺序，每个模块独立可测：

> ⚠ **本表已于 2026-09-17 重写**。原先列的是**早期规划的 9 个独立模块**，
> 而实际实现是：**2–7 全部合进了一个 HLS IP（`gesture_preproc`）**，
> 在 96×96 上跑完整条链（重排是为省 33× 算力，见 `src_hls/README.md`）。

| # | 模块 | 输入 → 输出 | 实现 | 状态 |
|---|---|---|---|---|
| 1 | `dvp_capture`（BD 里的 `dvp_capture_0`） | DVP 8bit → AXIS 16bit **RGB565** | **Verilog** | ✅ 已写并验证（`rtl/dvp_capture.v`，TB PASSED 23/23） |
| 1b | `sccb_master` + `ov5640_regs` + `iobuf_wrap` | SCCB 配置摄像头 | **Verilog** | ✅ SCCB TB PASSED 10/10；配置表已换真表（250 条），⚠ 未上板实测 |
| 2–7 | **`gesture_preproc`**（HLS 单一 IP）<br>内含：crop_scale → 高斯 → Sobel → 自适应阈值 → 闭运算 | AXIS 16bit RGB565 → AXIS 8bit 灰度 96×96 | **HLS** | ✅ csim + csynth 全 II=1 + cosim 6/6；IP = `user:hls:gesture_preproc:1.0` |
| 8 | `vdma`（+ `ic_hp1`/`ic_hp2`） | AXIS ↔ DDR（3 帧缓存） | **Xilinx VDMA IP** | ✅ 已集成（显示通路） |
| 8b | `dma_in` / `dma_out`（+ `ic_hp3`） | DDR → 预处理 → DDR | **Xilinx AXI DMA** | ✅ 已集成（CNN 通路） |
| 9 | `hdmi_out` | DDR → HDMI | 视频 IP + **TMDS 编码器** | ⚠ **TMDS 未做** —— BD 导出的 22 个 `hdmi_vid_out_*` 端口在比特流里**悬空**，走 DRC 豁免。**上板不要接 HDMI 线** |

### 为什么有些用 Verilog 有些用 HLS

| 判据 | 用 Verilog | 用 HLS |
|---|---|---|
| 需要精确控制时钟域/边沿 | ✅ DVP 采集 | ❌ |
| 需要例化原语（MMCM/BUFR） | ✅ **本项目需要**（Clocking Wizard 产生 XCLK） | ❌ |
| 是"每像素一次运算"的规整流水 | ❌ | ✅ 灰度/滤波/阈值/形态学 |
| 需要频繁改参数调优 | ❌ | ✅ 阈值/增益/核大小 |

> ### ⚠ XCLK 生成**需要**（2026-09-17 更正）
>
> **曾经有过一次反复，记录在此避免再犯：**
>
> | 日期 | 方案 | XCLK |
> |---|---|---|
> | 最初 | PMOD-CAMERA v1.0 | **PL 必须给** 24 MHz |
> | 2026-09-15 | 改为正点原子 ATK-OV5640 | 模块板载有源晶振，**不需要** PL，线数 14→13 |
> | **2026-09-17** | **改回 PMOD-CAMERA v1.0** | **PL 必须给** 24 MHz（模块无晶振） |
>
> 所以本节原先"XCLK 生成已不需要"的结论**已作废**。
> 现在 BD 里保留了 **Clocking Wizard `clk_wiz_xclk`**：
> 100 MHz → 24 MHz（M=12 / D=1 / O=50，VCO = 1200 MHz），
> 输出引到外部端口 `io_xclk`。
>
> **换模块的连锁影响**（每次换都要把这四处重新对一遍，不能只改选型那一句）：
> ① 接线根数　② XCLK 方向　③ 约束文件　④ BD 模块

**`dvp_capture` 必须是 Verilog**：I2C/SCCB 状态机、VSYNC/HREF 边沿检测、
跨时钟域（PCLK 域 → 系统时钟域）——这三件事用 HLS 写是自找麻烦。

---

## 三、接口契约（关键）

### 3.1 给 CNN 的输入 buffer

| 项 | 值 |
|---|---|
| **位置** | PS DDR，由 VDMA 写入 |
| **格式** | `uint8` 灰度，行优先连续存放 |
| **尺寸** | **96 × 96**（9216 字节） |
| **对齐** | 4 字节对齐（DMA 要求） |
| **取值范围** | 0–255，**不做归一化**（归一化由 CNN 侧负责） |
| **物理地址** | 由 PL 侧驱动分配后**写入寄存器**告知 CNN 侧，**不硬编码** |

### 3.2 握手寄存器

参照现有 `sobel_driver.h` 的寄存器风格，新增 AXI-Lite 状态寄存器：

| 偏移 | 名称 | 方向 | 含义 |
|---|---|---|---|
| `0x00` | `CTRL` | 写 | bit0 = `capture_start`（启动采集） |
| `0x04` | `STATUS` | 读 | bit0 = `frame_ready`，bit1 = `busy` |
| `0x10` | `INPUT_ADDR` | 读/写 | **96×96 buffer 的物理地址**（CNN 侧读这个） |
| `0x18` | `FRAME_SEQ` | 读 | 帧序号，每次写完 +1（用于丢帧检测） |
| `0x20` | `THRESH` | 写 | 自适应阈值的手动偏置 |
| `0x28` | `ROI_X` / `ROI_Y` | 写 | ROI 位置（调试用） |

**握手时序**：

```
PL 写完一帧 ──► frame_ready=1, FRAME_SEQ++
                        │
CNN 侧轮询到 ───────────┘
     │
     ├─► 读 INPUT_ADDR 指向的 9216 字节
     │
     └─► 回写 frame_ready=0（表示已消费）
```

> **不用中断的原因**：现有驱动是轮询 `ap_done`（README §8 已知限制）。
> 中断改造留到功能跑通之后，先用轮询把链路验证完。
> 若后续上中断，PL 的 `interrupt` 输出接 PS 的 `IRQ_F2P`，
> 需在 BD 里开 `PCW_USE_FABRIC_INTERRUPT`。

### 3.3 对拍机制（跨侧协作的保障）

**两侧都依赖同一份数据文件**，这是避免"我认为我传对了"的唯一办法。

```
PL 侧导出：把 DDR 里某帧的 9216 字节 dump 成 .bin
                │
                ├─► 你用它检查：预处理是否切出了干净的手部轮廓
                │
                └─► CNN 侧的 Python 脚本读同一个 .bin，
                    在 PC 上可视化、调模型
```

**格式约定**：裸 `.bin`（无头），`uint8`，行优先，96×96，共 9216 字节。

**工具已就绪**（`host/dump_frame.py`，已测通）：

```bash
python host/dump_frame.py make-test --out test.bin          # 造可预测的测试帧
python host/dump_frame.py stats board.bin                   # 统计（判全黑/全白）
python host/dump_frame.py compare board.bin test.bin        # 逐像素比对
python host/dump_frame.py show board.bin --png out.png      # 出图
python host/dump_frame.py show board.bin --side-by-side golden.bin --png cmp.png
```

> **没有文件头的理由**：加了头就要两侧同步解析逻辑。
> 裸 `.bin` 任何工具（含 HLS 的 C 代码）都能直接 `fread`。
> 元信息写在旁边的 `.txt` 比塞进文件头更灵活。
>
> `stats` 子命令会打印 **4×4 分块均值** —— 这一项能快速区分
> "整体偏移"和"只有一块有内容（ROI 位置问题）"。

---

## 四、BD 改造

> **⚠ 本节的历史部分已过时**：`bd_sobel.tcl` 已从本项目移除
> （参照工程在 `legacy/sobel`）。当前唯一的 BD 是 **`bd_video`**，
> 见 `vivado/README.md`。

### 4.1 原 Sobel BD（已移除，仅存档说明）

```
PS ──M_AXI_GP0──► ic_ctrl ──┬──► sobel_accel/s_axi_control
                            └──► dma0/S_AXI_LITE
PS ──S_AXI_HP0──◄── ic_mem ◄─┬── dma0/M_AXI_MM2S
                             └── dma0/M_AXI_S2MM
dma0/M_AXIS_MM2S ──► sobel_accel/src
sobel_accel/dst ────► dma0/S_AXIS_S2MM
```

### 4.2 当前 BD：`vivado/bd_video.tcl`

> **状态**：已建成并验证（validate + 综合通过）。
> 实际拓扑见 `vivado/README.md`，下面是当初规划时的描述。

```
                    ┌──► [sobel 通路，原样保留]
                    │
PS ──M_AXI_GP0──► ic_ctrl ──┬──► vdma/S_AXI_LITE
                            ├──► v_tc (Video Timing Controller)
                            └──► 采集模块的控制寄存器
                    ┌──► [新增] ov5640_capture 控制
                    │
PS ──S_AXI_HP1──◄── ic_mem ──► vdma/M_AXI_MM2S  (读帧给 HDMI)
PS ──S_AXI_HP2──◄────────────  vdma/M_AXI_S2MM  (写采集帧到 DDR)
```

**新增 IP**：

| IP | 用途 | 关键配置 |
|---|---|---|
| `axi_vdma` | 视频专用 DMA，带帧缓存管理 | 3 帧缓存，Genlock 关闭 |
| `v_tc` | 生成/检测视频时序 | 1280×720@60 或 30 |
| `v_axi4s_vid_out` | AXIS → 视频时序 | 配 `v_tc` |

**HP 端口分配理由**：
- **HP0** 留给原 Sobel 通路（回归测试不受影响）；
- **HP1** 给 VDMA 读通道（HDMI 显示）；
- **HP2** 给 VDMA 写通道（摄像头采集）。

720p@30 RGB565 持续写入约 **55 MB/s**，加上读回与 CNN 访问，
**单 HP 口带宽不够且会和 Sobel 通路抢**，必须分开。

> ⚠ **BD 修改前先备份 `.xpr`**。BD 是本项目最脆弱的环节——
> 现有工程能跑通是花了代价的（见原 README §9 的踩坑记录，尤其 9.7：
> `apply_bd_automation ... apply_board_preset 1` 会重置 PS7 配置）。

---

### 4.3 gesture_preproc 的集成方式（2026-09-15 定案）

**决策：从 DDR 分叉，不从 `dvp_capture` 分叉。**

```
【显示通路】摄像头原图直通，与预处理完全解耦
dvp_capture ─AXIS(16bit)─► VDMA S2MM ─► HP1 ─► DDR(帧缓存) ─► VDMA MM2S ─► HP2 ─► HDMI

【CNN 通路】从 DDR 取同一帧
DDR(帧缓存) ─► dma_in(MM2S) ─► gesture_preproc ─► dma_out(S2MM) ─► DDR(96×96) ─► CNN
```

**为什么不用 `axis_broadcaster` 从采集侧分叉**（这是被否掉的第一方案）：

broadcaster 要求**所有输出都 ready 才接收输入**。
而 `gesture_preproc` 是 HLS 的 `ap_ctrl_hs` 模式 ——
**未 `ap_start` 时 `tready=0`**。

CNN 不需要 30 fps，`gesture_preproc` 大部分时间空闲。于是：
`gesture_preproc` 空闲 → broadcaster 反压 → VDMA 收不到数 →
**HDMI 显示也一起卡死**。这个反压是常态化的，不是偶发。

**DDR 分叉的收益**：
- 显示通路一字未动，CNN 通路出任何问题都不影响画面
- `gesture_preproc` 按 PS 的节奏跑（10 fps 都够），不必死磕 30 fps 时序
- 同一份 DDR 数据在 PC 上也能拿来对拍 Python golden

**代价**：多一次 DDR 往返（614 KB/帧读）。三个 HP 口各自独立，占比很小。

**HP 端口最终分配**：

| 口 | 用途 |
|---|---|
| HP0 | 原 Sobel 通路（`bd_sobel.tcl`），本 BD 不碰 |
| HP1 | VDMA S2MM：摄像头帧写 DDR |
| HP2 | VDMA MM2S：DDR 读帧送 HDMI |
| HP3 | 预处理链的两次 DMA（读原图 + 写 96×96） |

**触发方式：帧触发 + 轮询**（与现有驱动风格一致）。

PS 侧顺序（⚠ 不能反）：
```
检测新帧 → 先武装 dma_out(S2MM) → 再启动 dma_in(MM2S) → ap_start
        → 轮询 ap_done → 置 frame_ready
```
S2MM 必须先武装，否则预处理输出的第一拍没有接收方。

**实测资源**（2026-09-15，xc7z020）：

| 资源 | 用量 | 占比 |
|---|---|---|
| Slice LUTs | 12,735 | 23.94% |
| Slice Registers | 15,736 | 14.79% |
| Block RAM | 25.5 | 18.21% |
| DSPs | 61 | 27.73% |

DSP 偏高**不在** `thresh_stage`（它只占 2 个）——实测大头在 `morph_stage`（56 个）。
降 DSP 的尝试失败过（代价是 II 退化），详见 `src_hls/README.md`。

---

## 五、为什么 CNN 不放 PL（决策记录）

这是被反复问到的问题，结论与依据存档在此，避免重复论证。

| 约束 | XC7Z020 实际值 | 一个微型 CNN 的需求 | 判断 |
|---|---|---|---|
| DSP48E1 | **220** | `Conv(1→8,3×3)` 一层全并行 = 72 个乘法器 | 单层就吃掉 1/3 |
| LUT | 53,200 | 多层流水 + 权重 ROM 寻址 | 会超 50% |
| 动态功耗 | 现有设计 1.696 W | 全并行会顶到板卡供电/散热上限 | 有风险 |
| 开发工期 | — | 自研 line buffer + 权重调度 + 定标 | **以月计** |
| 替代方案 | — | Cortex-A9 (650 MHz) 跑定点推理 | **10–30 ms/帧** |

**关键判断**：手势识别 demo 的目标是 30 FPS，PS 侧 30 ms/帧
**完全够用**——因为瓶颈根本不在推理，在摄像头采集与预处理。
把 CNN 放 PL 是"用最贵的资源解最容易的问题"。

**这条决策的可辩护性**（竞赛答辩时会被问）：
不是"PL 做不到"，而是**"异构划分应当沿数据量 × 操作次数这条线切"**——
PL 做每像素一次操作的带宽型任务，PS 做需要循环迭代与权重的算力型任务。

---

## 六、PYNQ 改造说明

现有工程是裸机 + Vitis standalone。改为 PYNQ 的收益：

| 项 | 裸机 | PYNQ | 收益 |
|---|---|---|---|
| Cache 一致性 | 手动 `Xil_DCacheFlush` | **自动**（`allocate` 的 buffer 一致） | **省掉 README §5 整节坑** |
| 看图调试 | UART `printf` + ASCII | Jupyter + matplotlib | 大幅改善 |
| 调用 IP | `Xil_Out32(BASE+off, v)` | `ip.write(off, v)` | 等价 |
| DMA | `XAxiDma_SimpleTransfer` | `dma.sendchannel.transfer()` | 等价 |
| 加载 overlay | XSA → Vitis → JTAG | `Overlay("x.bit")` | 一行 |

**BD 与 HLS 不需要因为 PYNQ 而改动**——这是现有工程最大的价值。

**需要准备的**：
1. PYNQ 镜像 **v3.0.1**（对应 Vivado 2025.2 生成的设计需核对兼容性，
   若 `Overlay` 加载报版本错，用 `pynq.Overlay(..., ignore_version=True)`）；
2. 导出 `.bit` + `.hwh`（Vivado 里 `write_hw_platform` 或直接从
   `sobel_system.gen` 取 `hw_handoff`）；
3. 确认 IP 的 VLNV 名——用 `overlay.ip_dict` 打印，不要猜。

---

## 七、开发顺序（板子到货前可完成的部分）

**板子未到，但这三件事完全不受影响**，且都是下游的阻塞项：

| 顺序 | 任务 | 产物 | 不需要硬件 |
|---|---|---|---|
| 1 | 手势数据集（6 类 × 96×96 灰度） | 冻结的数据集 + `dump_frame.py` | ✅ |
| 2 | `ov5640_capture` Verilog + 自检 TB | iverilog 仿真通过 | ✅ |
| 3 | `adaptive_thresh` + `morph_close` HLS | csim + cosim 通过 | ✅ |
| 4 | `bd_video.tcl` | Vivado `validate_bd_design` 通过 | ✅ |
| 5 | 转接板焊接 | 实物 | 需材料 |

**任务 1 是最高优先级**——它阻塞 CNN 侧，而 CNN 侧的开发周期最长。

---

## 八、当前状态与未验证项

> 按"说清楚什么没验证"的原则记录。

| 项 | 状态 |
|---|---|
| 视频通路 BD（`bd_video`） | ✅ **已建成并验证**（`validate_bd_design` 通过，AXI 无悬空） |
| `dvp_capture` 采集 | ✅ **已写并验证**（`rtl/dvp_capture.v`，iverilog TB PASSED 23/23） |
| SCCB 主控 | ✅ 已写并验证（`rtl/sccb_master.v`，TB PASSED 10/10） |
| HLS 预处理链 | ✅ 已综合（`gesture_preproc`，`user:hls:gesture_preproc:1.0`） |
| 建工程→综合→实现→比特流→XSA | ✅ **2026-09-17 完整跑通**（0 error / 0 critical warning） |
| 时序 | ✅ `All user specified timing constraints are met`，**WNS = +1.177 ns**（RTL 级） |
| PS7 DDR 参数 | ✅ 已修正为 `MT41K256M16 RE-125` 并重跑验证 |
| 摄像头选型 | ✅ **已定（2026-09-17）：PMOD-CAMERA v1.0，直插 Pmod A+B** |
| **`ov5640_regs.v` 寄存器表** | ❌ **已替换为真表但未上板实测**（250 条，正点原子来源，固化为 640x480） |
| 板级实测 | ❌ **完全未做**（板子未到） |
| 引脚分配表 | ⚠ XDC 映射是**推理**的（原理图"镜像编号"），**接线前必须万用表实测复核**，插错会烧板 |
| HDMI 输出 | ❌ 未实现（无 TMDS 编码器；22 个端口在比特流里悬空，**上板不要接 HDMI 线**） |
| PYNQ 镜像与 2025.2 的兼容性 | ⚠ 未验证 |
| PS 侧 CNN | ❌ 未开始（**他人负责**） |

### 换模块的历史（避免再次反复）

选型改过一次又改回来了，**换模块会连锁影响四处**
（接线根数 / XCLK 方向 / 约束文件 / BD 模块）：

| 日期 | 方案 | XCLK |
|---|---|---|
| 最初 | PMOD-CAMERA v1.0 | PL 必须给 24 MHz |
| 2026-09-15 | 正点原子 ATK-OV5640 | 模块板载晶振，不需要 PL（线数 14→13） |
| **2026-09-17** | **改回 PMOD-CAMERA v1.0** | **PL 必须给** 24 MHz |

那次反复导致 `io_xclk` 一度被误判为"约束缺失"（实际 `video_io.xdc:183` 有 `Y18`）。
**教训**：判断约束在不在，要 `grep` 约束文件或回读实现报告，不能凭印象。

---

## 九、数据来源

- 引脚约束：`原厂 PYNQ-Z2 资料目录\PYNQ-Z2_v1.0_master.xdc`（TUL 原厂）
- 板卡与共享引脚：同目录 `PYNQ-Z2资料汇编.md`
- 现有工程接口与踩坑：`legacy/sobel/README.md`（本工程内副本同名）
- 分工与选型决策：2026-09-14 与用户确认
