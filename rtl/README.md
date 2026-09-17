# rtl 索引

> 手写 Verilog 模块（不属于 HLS 工程）。用 iverilog 验证 —— **不需要板卡、
> 不需要 Vivado license**，秒级出结果。

## 一键回归

```bash
bash rtl/run_iverilog.sh
```

判定标准是日志里的 `*** TB PASSED ***`。**`finished` 不算数**。
改任何 RTL 之后都应该跑一遍。

## 模块

| 文件 | 作用 | 验证状态 |
|---|---|---|
| `sccb_master.v` | SCCB(I2C) 主控，配置 OV5640 | ✅ TB PASSED (10/10) |
| `dvp_capture.v` | DVP 采集 → AXI4-Stream | ✅ TB PASSED (23/23) |
| `async_fifo.v` | 异步 FIFO（PCLK→sysclk 跨时钟域） | ✅ 由 dvp_capture TB 覆盖 |
| `ov5640_regs.v` | OV5640 寄存器 ROM | ✅ TB PASSED (11/11)。**2026-09-17 已换为真表**（250 条，正点原子来源，固化 640×480 RGB565），⚠ **未上板实测** |
| `iobuf_wrap.v` | IOBUF 三态缓冲包装（SDA 双向） | ⚠️ **Functional 未验证**，但**已过综合/实现**（见下） |

### ⚠ 一个模块有验证盲区

**`ov5640_regs.v` —— TB 不验表内容**（2026-09-17 更新）

TB 验的是**接口行为**（拼接顺序、位宽、关键寄存器值、N_REGS 一致性），
**不验整张表对不对** —— 寄存器值的正确性只能上板看有没有图像。

~~表里的 8 条寄存器值是猜测~~ → ✅ **已换成真表**：250 条，来源是正点原子
`i2c_ov5640_rgb565_cfg.v`，固化为 640×480 RGB565。详见 `ov5640_regs.v` 文件头。

> ⚠ **改了表必须同步改 BD 里 `sccb_0` 的 `N_REGS`**（当前 250）。
> `sccb_master.v` 默认是 64，不一致会**配到一半就停且无任何报错**。

**`iobuf_wrap.v` —— 功能无法用 iverilog 验证**

它例化的是 Xilinx 原语 `IOBUF`，**iverilog 不认识**：

```
error: Unknown module type: IOBUF
```

这是**预期行为**，不是 bug —— 原语只能在 Vivado 里综合。

**当前状态**（2026-09-16）：

| 层次 | 结果 |
|---|---|
| iverilog 功能仿真 | ❌ 跑不了（原语不认） |
| **Vivado 综合 + 实现** | ✅ **通过**（整个 BD 已生成比特流） |
| 板级实测 | ❌ 等板子 |

也就是说，**"能综合进去"已经验过了**，没验的是"三态行为是否符合预期"。
它逻辑极简（一个三态缓冲 + 取反），风险低，但**这是一个已知的验证盲区** ——
上板后如果 SCCB 读不到 ACK，要记得这里没被仿真验证过。

## 为什么这几个模块用 Verilog 而不是 HLS

`src_hls/gesture_preproc.cpp` 里的滤波链用 HLS 表达更省事，但这三个模块不行：

1. **`sccb_master`** —— I2C 位串行时序，HLS 表达不了三态总线与位级握手
2. **`dvp_capture`** —— 需要显式跨时钟域（见下），且要检测 VSYNC/HREF 边沿
3. **`async_fifo`** —— 格雷码指针 + 双时钟，是 CDC 的标准做法

## 三条容易重犯的坑（都已在本目录代码里注释）

### 1. `ap_axiu` 只能挂 AXI-Stream 端口，不能做内部流负载

HLS 侧的问题（csim 通过、csynth 报 `[HLS 214-208]`），记在这里是因为
它和 RTL 的 CDC 是同一类"仿真看不出来"的问题。

### 2. 跨时钟域必须用异步 FIFO，不能逐位同步

PCLK(24 MHz) 与 aclk(100 MHz) 相位无关。多比特数据逐位打两拍会出现
"高位新值 + 低位旧值"的混合态 —— **仿真中所有位同时跳变，看不出问题**，
只在真实硅片上随机出错。

### 3. 边沿检测必须用同一时间快照的信号

`dvp_capture` 里 `cam_data` 必须和 `cam_href` **在同一级寄存器采样**。
如果 href 用了寄存后的值、而数据还用原始信号，两者差一拍，
行首会整体错一个字节。这个 bug 的 TB 现象是"每个像素都是
`{低字节, 下一像素的高字节}`"，很隐蔽。

## 与 HLS 的分工

```
OV5640 ──DVP──► sccb_master(配置) ──► dvp_capture ──AXIS──► gesture_preproc(HLS)
                     ↑                    ↑
                  I2C 位时序          async_fifo 跨时钟域
```

`dvp_capture` 输出的是**一拍一像素的 16bit RGB565 AXIS 流**，
正好是 `gesture_preproc` 的输入格式（`axis_rgb_t`）。两者对接无需转换。

## 下一步

`bd_video.tcl` —— 把 `dvp_capture` 的输出接到 VDMA，加 VTC + 视频输出 IP。
`dvp_capture` 的 AXIS 接口（`m_axis_tdata/tvalid/tready/tlast`）
与 Xilinx 的 `AXI4-Stream Subset Converter` 直接兼容，不需要位宽转换 IP
（16bit 输入，Video In to AXI4-Stream 也吃 16bit RGB565）。
