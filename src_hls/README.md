# src_hls 索引

> 本目录是**手势识别预处理链**这一套 HLS 工程。
> 原 Sobel 那套已移出本项目（参照在 `legacy/sobel`），见 §二。

## 一、手势预处理链（本项目主体）

| 文件 | 作用 |
|---|---|
| `gesture_preproc.h` | **对外契约**：寄存器映射、参数、几何空间常量 |
| `gesture_preproc.cpp` | HLS 实现：crop_scale → 高斯 → Sobel → 阈值 → 闭运算 |
| `gesture_ref.cpp/.h` | 软件 golden 参考实现（`#ifndef __SYNTHESIS__` 屏蔽，不综合） |
| `tb_gesture.cpp` | csim testbench，5 组用例逐位比对 |
| `run_gesture.tcl` | 构建脚本 |

构建：
```bash
vitis-run --mode hls --tcl src_hls/run_gesture.tcl
```

可选环境变量：`GESTURE_CSIM=0`（跳过 csim）、`GESTURE_COSIM=1`（跑协同仿真）、
`GESTURE_CLOCK=8`（改时钟周期）。

## 二、本目录只有手势识别一条链

Sobel 那套（`sobel_hls.h/.cpp`、`tb_sobel.cpp`、`run_hls.tcl`、
`hls_config.cfg`）**已从本项目移除** —— 它唯一的作用是"已验证的骨架参照"，
而那个参照现在由本仓库 `legacy/sobel/` 完整承担。

> ⚠ **但它的价值还在**：本目录的 `gesture_preproc.cpp` 里
> `win_push()` 那套行缓存骨架（3 行 BRAM + 3 级列移位寄存器）
> **直接搬自 Sobel 那版**。改这部分时，
> `legacy/sobel/src_hls/sobel_hls.cpp` 是最重要的对照参考 ——
> 它是唯一被硬件流程验证过（II=1、时序收敛）的骨架。

---

## 三、必须记住的语义契约

改 `gesture_preproc.cpp` 或 `gesture_ref.cpp` 之前，先读这段。
这里记录的两条都**曾经推导错过一次**，错误版本会通过编译、
看起来也"很接近正确"，只在逐位比对时才暴露。

### 契约 1：3×3 阶段就是标准零填充卷积

```
输出 (Y, X) 的窗口 = 图像 (Y-1..Y+1, X-1..X+1)，越界一律取 0
```

看起来平平无奇，但推导过程有个陷阱：HLS 的流式实现在**内部迭代
坐标**上带一个 (−1, −2) 的常数偏移（3 级列移位寄存器造成），
而这个偏移在**输出数组索引**上恰好抵消 —— 读出第 (x−1) 个值
对应图像列 x−1，写的正是输出下标 (Y, X)。

⚠ 曾经把内部的 (−1, −2) 误当成输出坐标的偏移，于是在流里预先
补了一圈零边框，导致整幅图错位一行两列。**要改这里，先把上面
这段重新推一遍。**

因此 `crop_scale` 输出的是**普通行优先的 96×96**，不做任何预填充；
边界补零由各级自己的 zero-feed（读条件 `x>=1 && x<=width` 之外
喂 0）完成。golden 侧的 `at(r,c)` 越界返回 0 就够，加额外判断
反而会引入语义差异。

### 契约 2：直通 = 原值，且走纯流拷贝

某级 `enable=0` 时，输出就是原值输入。HLS 侧实现为**纯流拷贝**，
不走窗口路径 —— 窗口路径有自身的节拍，直通取值与输出位置不是
恒等关系，照常走会整体错列。

（同一个推导错误的产物：早期版本把直通写成了"带 (1,2) 延迟的
拷贝"，同样是错的。）

### 附带约束：内部流不能用 ap_axiu

`ap_axis` / `ap_axiu` / `hls::axis` **只能挂在 AXI-Stream 接口端口**上。
用作内部 `hls::stream` 的负载会在 csynth 报：

```
[HLS 214-208] The ap_axis|ap_axiu|qdma_axis|hls::axis data types
              must only be used for AXI-Stream ports in the interface.
```

**csim 对此是宽容的**，所以这个错误只在综合时暴露 ——
"csim 通过"不等于"能综合"。

---

## 四、验证状态

| 项 | 状态 |
|---|---|
| **csim 逐位比对** | ✅ **TB PASSED**，5 组用例全过（9216 像素逐位一致） |
| **csynth** | ✅ 通过，**所有循环 II=1**，Est. Fmax 137 MHz |
| **C/RTL 协同仿真** | ✅ **6/6 事务全过**（`cosim finished: PASS`） |
| **IP 导出** | ✅ `user:hls:gesture_preproc:1.0` |
| 板级实测 | ❌ 未做（板子未到） |
| Python golden | ✅ 自检全过 |

---

## 四点五、cosim 死锁：一次绕了三圈的排查

**这是本项目最值得记录的一次调试** —— 不是因为它难，而是因为
**正确的线索一直都在，我却先去改了别的东西**。

### 最终结论

**根因**：顶层函数里 **AXI-Lite 从口（`s_axilite` 标量参数）
与 `#pragma HLS DATAFLOW` 共存**。

**HLS 从一开始就明确警告了**：

```
WARNING: [HLS 200-616] This design uses AXI slave interface in dataflow
        mode, which can result in simulation dead-lock and/or mismatching
        results (due to AXI slave FIFO sizing).
```

含义：AXI-Lite 写通道的 FIFO 深度是固定的，而 DATAFLOW 各阶段的
并行度与之不匹配 —— 握手对不上就死锁。

**症状**（csim 完全看不出来）：

```
// RTL Simulation : 0 / 6 [n/a] @ "1000000635000"     ← 一个事务都不完成
Simulation engine not responding
The simulator has terminated in an unexpected manner.
```

而且**与输入分辨率无关** —— 64×64 和 640×480 表现完全一样。
这一条是**最关键的判据**：说明卡在控制路径，不在数据路径。

### 解法：拆成内外两层

```cpp
/* 内层：纯流，无 AXI-Lite，标量参数按值传递 */
static void preproc_pipeline(src, dst, width, height, ...)   // 普通参数
{
#pragma HLS DATAFLOW
    crop_scale(...);
    gaussian_stage(...);
    ...
}

/* 外层：只有 AXI-Lite 接口，做参数检查后转发 */
void gesture_preproc(src, dst, width, height, ...)           // s_axilite 参数
{
#pragma HLS INTERFACE mode=s_axilite port=width ...
    ...参数检查...
    preproc_pipeline(src, dst, width, height, ...);
}
```

**DATAFLOW 区域里现在只有流，没有 AXI 从口**，握手关系干净了。

**验证**：`[HLS 200-616]` 从 **2 次降到 0 次**，
cosim 从 `0/6` 变成 **`6/6` PASS**，csynth 结果不变
（LUT 24% / DSP 32% / BRAM 12%，全 II=1）。

### ⚠ 我绕的三圈（这才是要记的教训）

| 次 | 我的结论 | 为什么错 |
|---|---|---|
| 1 | "DATAFLOW 里的裸 `for` 循环导致死锁" | **只看日志末行不动就下结论**。实际仿真一直在推进（到 800ms，10 次进度报告）—— 我看到的只是某一时刻的快照 |
| 2 | "仿真规模太大，要跑 7 小时" | **改小分辨率后仿真时间没变**，这个假设当场就该被否掉。我却继续改了一堆 TB 代码 |
| 3 | "TB 串行喂数据撑爆 FIFO 导致死锁" | 改成 DATAFLOW 并行后**仍然 `0/6`** |

**绕圈的代价**：三次改动、两次重跑 cosim（每次 20+ 分钟）。

### 正确的方法论（下次照这个来）

1. **先逐条读 WARNING，尤其是措辞里直接提到故障现象的**
   —— 这次 `200-616` 里明明白白写着 "dead-lock"，第一次运行就有。
2. **判断"卡住"要先确认变量**，不要直接算理论值。
   改一个参数（分辨率）看结果是否变化，比推导更可靠。
3. **"与某参数无关"是极强的线索** —— 说明问题不在那条路径上。
   这次"与分辨率无关"直接指向控制路径，而 AXI-Lite 就是控制路径。
4. **日志末行不动 ≠ 卡死**。要对比两次采样之间的**时间戳**，
   并确认进程是否还活着。

### 前两次改动保留了吗

**保留**，因为它们本身是对的（虽然当初的诊断理由错了）：

| 改动 | 为什么保留 |
|---|---|
| 收尾 `for` 包成 `output_stage()` | HLS 规范要求 DATAFLOW 区域只允许变量声明和函数调用（`[HLS 214-114]`）。这是**规范**，不是可选优化 |
| TB 改成 DATAFLOW 并行喂/收数据 | 更接近真实硬件行为 —— AXI DMA 是一边喂一边收的，不会"先灌完整帧再启动 IP" |

### 想快速跑 cosim 的话：缩小分辨率

640×480 下 cosim 要跑很久（实测仿真时间约 1.3 秒 → 实际数十分钟）。

做法：把 `gesture_preproc.h` 的 `GESTURE_IN_WIDTH/HEIGHT` 临时改成 64。
TB 已改成**自适应 ROI 参数**，不用改 TB。
用例 4（手算绝对校验）有编译期判断，非 96×96 输入时会自动跳过并说明原因，
**不会给出错误结论**。

### 综合结果（xc7z020-clg400-1，目标 100 MHz）

| 指标 | 值 | 占比 |
|---|---|---|
| LUT | 13,184 | **24%** |
| FF | 10,769 | 10% |
| BRAM | 34 | 12% |
| DSP | 71 | **32%** |
| 顶层 slack | +0.00 ns | 时序收敛 |

各阶段延迟（周期）：crop_scale ~207 万（读满整帧 640×480 是大头）、
gaussian 9,821、sobel 9,822、thresh 18,443、morph 19,066。

> ### [!] DSP 占 32%，但**归属与原先写的不符**（2026-09-18 更正）
>
> 本节原先写的是"主要来自 `thresh_stage` 里的整数除法"——**那是错的**。
> 逐模块查 `csynth.rpt` 得到的实际分布：
>
> | Stage | DSP |
> |---|---|
> | **`morph_stage`** | **56（占全设计 79%）** |
> | `crop_scale` | 4 |
> | `thresh_stage` | 2 |
> | `sobel_stage` | 1 |
> | `gaussian_stage` | 0 |
>
> **教训：DSP 的归属要逐模块查表，不能凭"哪里有除法"推断。**
>
> **降 DSP 的尝试失败过**（三种改法，详见 `gesture_preproc.cpp` 里
> morph_stage 的注释）：唯一能降的改法让 **II 从 1 退化成 2**，
> 省 17 个 DSP 换掉一半吞吐 —— 不划算，已回退。
>
> 剩余 DSP 来自腐蚀 pipeline 里若干带 16 位常数魔数的乘法器，
> **性质尚未查清**。若要继续优化，先弄清它们是什么再动手。

### 5 组 csim 用例（不是凑数，每组对应一类真实故障）

| # | 用例 | 抓什么 |
|---|---|---|
| 1 | 全链开启 | 基本功能正确性 |
| 2 | 全链关闭 | 各级直通路径；直通写错会整帧错列 |
| 3 | 极小 ROI 96×96 | 缩放步长退化到 1；步长为 0 会除零 |
| 4 | 灰度绝对校验 | 手算预期值，抓"参考实现和被测实现一起错" |
| 5 | 非法参数 | 应在读 stream 前返回，否则 TB 会挂住超时 |

用例 4 的存在很关键：前 3 组都是"自比对"，若 C++ golden 本身
理解错了，自比对会一起错、看起来是通过的。用例 4 用与两个实现
都无关的手算公式做绝对校验。

---

## 五、下游状态

**这个 HLS IP 已经被接进 BD 并驱动起来了**（2026-09-15）：

| 环节 | 位置 | 状态 |
|---|---|---|
| IP 导出 | `user:hls:gesture_preproc:1.0` | ✅ |
| 进 BD | `vivado/bd_video.tcl`（`gesture_preproc_0` + `dma_in` + `dma_out`） | ✅ 综合 + 实现 + 比特流 |
| PS 侧驱动 | `sw/preproc_driver.c` | ✅ 主机自检 24/24 |

**驱动里用到的寄存器偏移直接从本 IP 生成的官方头文件取**：
```
gesture_comp/solution1/impl/ip/drivers/
    gesture_preproc_v1_0/src/xgesture_preproc_hw.h
```

⚠ 状态位在 `CTRL(0x00)`，不在 `0x04`（那是 GIE）。
本项目在 sobel_driver 上踩过这个坑，`preproc_driver` 从一开始就用对。

### 还没做的

1. **上板实测** —— 等板子与摄像头到货。
   ⚠ 上板前必读 `docs/hardware-checklist.md` §3.3（引脚万用表复核）。
2. ~~**`rtl/ov5640_regs.v` 的寄存器表** —— 占位表，上板前唯一的软件阻塞项~~
   ✅ **2026-09-17 已解决**：换为真实配置表（250 条，正点原子来源，
   固化为 640×480 RGB565）。⚠ **但仍未上板实测** —— 表内容对不对
   只能上板看有没有图像。详见 `rtl/ov5640_regs.v` 文件头。

### 与 CNN 侧对接

DDR 契约是 **96×96 uint8 灰度**（`PREPROC_OUT_PIXELS` = 9216 字节），
地址由 PS 侧驱动告知，对拍用裸 `.bin` + `host/dump_frame.py`。
详见 `docs/architecture-contract.md` §3。
