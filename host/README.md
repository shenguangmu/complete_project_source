# host 索引

> PC 侧工具。三个文件各管一件事 —— **互相独立，可以单独用**。

## 三个工具的关系

```
   ┌─────────────────────────────────────────────────────┐
   │  gesture_golden.py     Python 参考实现（第三方对拍） │
   │      ↓ 产出 .bin                                     │
   │  dump_frame.py         帧比对/出图（两侧共用）        │
   │      ↑ 读 .bin                                       │
   │  gesture_overlay.py    板上驱动（PYNQ）              │
   └─────────────────────────────────────────────────────┘
```

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `gesture_golden.py` | **PC** | 预处理链的 Python 参考实现 |
| `dump_frame.py` | **PC + 板** | 帧数据的转储、比对、出图 |
| `gesture_overlay.py` | **板（PYNQ）** | 加载 overlay、驱动整条流水线 |

---

## gesture_golden.py —— 第三方对拍

**为什么需要它**：HLS 的 csim 是"HLS 实现 vs C++ golden"比对。
如果那个 C++ golden 本身理解错了，两边会**一起错**，测试照样通过。

Python 版本是**完全独立的第二实现**，三者互证：

```
        HLS 实现
       ↙        ↘
C++ golden      Python golden
```

```bash
python gesture_golden.py --self-test                       # 自检（无需文件）
python gesture_golden.py --input f.bin --width 640 --height 480 \
                         --out result.bin --png result.png
```

---

## dump_frame.py —— 帧比对工具

**用在两个地方**，这正是它的价值：板上 dump、PC 比对 ——
**同一份数据文件**，能直接回答"是 PL 传错了还是 CNN 读错了"。

```bash
python dump_frame.py make-test --out test.bin        # 造可预测的测试帧
python dump_frame.py stats board.bin                 # 统计 + 4x4 分块均值
python dump_frame.py compare board.bin test.bin      # 逐像素比对
python dump_frame.py show board.bin --png out.png    # 出图（放大 4 倍）
python dump_frame.py show board.bin --side-by-side golden.bin --png cmp.png
```

### 数据格式（与 CNN 侧的契约）

```
裸 .bin，无文件头
uint8，96x96，行优先
共 9216 字节
```

> **不加文件头是故意的** —— 加了就要两侧同步解析逻辑。
> 裸 `.bin` 任何工具（含 HLS 的 C 代码）都能直接 `fread`。

### ⚠ 中文 Windows 的一个坑

`stats` 里的标记用的是 **ASCII `[OK]` / `[!!]`，不是 `✓` / `⚠`**。

原因：中文 Windows 的控制台编码是 **GBK**，打印 `✓`（U+2713）会抛
`UnicodeEncodeError: 'gbk' codec can't encode character`。

写任何面向中文 Windows 的 CLI 工具都要注意这条 ——
**Unicode 符号在 GBK 控制台下会直接崩**。

### `stats` 的 4×4 分块均值有什么用

能快速区分两类完全不同的故障：

| 现象 | 多半是什么 |
|---|---|
| 只有某一块有内容，其余全 0 | **ROI 位置错了**（裁剪窗口没对准） |
| 整体均匀但全黑/全白 | **阈值问题** |
| 分块值呈梯度但有偏移 | **数据流对齐问题** |

---

## gesture_overlay.py —— PYNQ 板上驱动

```python
from gesture_overlay import GesturePipeline
g = GesturePipeline()              # 加载 overlay
g.print_info()                     # 先看 IP 认出来没有
g.setup_dma()                      # 分配 DMA 缓冲
g.config()                         # 配参数
g.fill_test_pattern()              # 无摄像头时填测试图
g.run_once()                       # 跑一帧
g.show()                           # Jupyter 里出图
```

### 三个设计点

**1. 地址不硬编码** —— 全部从 `overlay.ip_dict` 读。
重新综合后地址会变，硬编码必然出错。

**2. 执行顺序不能反**（与裸机 C 驱动同一套）：
```
① 先武装 dma_out(S2MM)  ② 再启 dma_in(MM2S)  ③ 最后 ap_start
```
反了的话预处理输出的第一拍没有接收方，数据会丢。

**3. 用 `pynq.allocate` 而不是 numpy 数组** ——
`allocate` 出来的 buffer 是 **cache 一致的**，不用手动 flush/invalidate。
这是 PYNQ 相对裸机最大的便利（裸机漏了 cache 维护会拿到旧数据，且不报错）。

> ⚠ **`ignore_version=True` 可能需要**：PYNQ 镜像基于某个 Vivado 版本，
> 与本项目的 2025.2 不一致时 `Overlay()` 会报版本错误。先不加，报错再加。

> ⚠ **若 `io_pclk` 没有波形**：先查 `rtl/ov5640_regs.v` 的配置表。
> ✅ 2026-09-17 已由占位表换成真表（250 条，固化 640×480 RGB565），
> **但未上板实测** —— 若仍无波形，可能是表内容/接线/时序问题，
> 不再像以前那样"必然是占位表的锅"。
> 用 `fill_test_pattern()` 可以在无摄像头时验证数据通路。

---

## 三个工具的共同约定

参数常量（尺寸、寄存器偏移）都**硬写在各自文件里**，来源是：

| 常量 | 来源 |
|---|---|
| 96×96 / 9216 | `src_hls/gesture_preproc.h` |
| 寄存器偏移 | 官方 `xgesture_preproc_hw.h` |
| 控制位语义 | 官方 `xgesture_preproc.c` |

**改任何一处都要同步改另外两处和相关源码。**
这些值在 `gesture_golden.py` / `gesture_overlay.py` / `dump_frame.py`
里各自定义了一遍 —— 是有意为之：**三个工具要能独立运行**，
不依赖共享模块（那样任一文件缺失就全不能用）。
