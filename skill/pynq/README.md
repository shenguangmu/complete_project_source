# PYNQ 工具集

> 四个独立工具，**只依赖 PYNQ overlay 的产物**（`.hwh` / 比特流），
> 不依赖任何具体题目代码。换题目、换板卡仍可用。

**运行环境**：Python 3.8+，`numpy`；`dma_guard.py` 另需 PYNQ 环境（只在板卡上跑）。

## 为什么需要这几个工具

从「硬件做好了」到「能验证它对不对」之间，有四件高度重复、且**错了很难查**的事：

| 痛点 | 工具 |
|---|---|
| 原始 `.hwh` 实测 **307 KB ≈ 77,000 tokens**，直接读进上下文会瞬间吃掉整个窗口 | `ip_contract.py` |
| 同一个寄存器偏移要在 Python 驱动 / 裸机 C / 测试骨架里**抄三遍** | `gen_host_stub.py` |
| "比对失败"不说清错在哪等于没说 | `golden_compare.py` |
| DMA + cache 漏维护**不报错、只出错数据** | `dma_guard.py` |

---

## 1. `ip_contract.py` —— 从 `.hwh` 提取接口契约

把原始 `.hwh` 压成**紧凑 JSON 契约**（通常 < 3 KB），只保留决策需要的信息：
寄存器偏移、位域、地址范围、接口清单。

> **核心约定：原始 `.hwh` 永远不要直接 Read，一律通过本工具。**

```bash
python ip_contract.py board.hwh                          # 摘要：有哪些 IP、各占多少寄存器
python ip_contract.py board.hwh --ip my_accel_0          # 只看某个 IP
python ip_contract.py board.hwh --json contract.json     # 完整契约 → JSON
python ip_contract.py board.hwh --ip my_accel_0 --format c --prefix MY_IP
```

**失效条件**：依赖 `.hwh` 的 XML 结构，**Xilinx 大版本变更可能改结构**
（本项目在 2025.2 验证）。解析失败时看工具报的是哪个标签找不到。

---

## 2. `gen_host_stub.py` —— 从契约生成主机侧代码

读一次契约，生成三份代码：

1. **PYNQ Python 驱动类**（寄存器名、位域掩码、AXI-Lite 访问）
2. **裸机 C 头文件**（偏移 + `AP_START`/`AP_DONE` 时序）
3. **测试骨架**（喂测试向量、与黄金值比对）

```bash
python gen_host_stub.py contract.json --ip my_accel_0 --lang py -o driver.py
python gen_host_stub.py contract.json --ip my_accel_0 --lang c  -o driver.h
python gen_host_stub.py contract.json --ip my_accel_0 --lang test -o tb.py
```

**失效条件**：生成的是**骨架**，不保证业务逻辑正确 ——
它保证的是"**寄存器偏移与位域没抄错**"。

> ⚠ **HLS 的状态位在 `CTRL`(0x00)，不在 `GIER`(0x04)**。
> 这是个经典误用（把 `0x04` 当 STATUS），且**主机仿真发现不了** ——
> 因为仿真自己造了个假 STATUS 值。本工具从契约取真实偏移，可避开。

---

## 3. `golden_compare.py` —— 输出比对 + 指标报告

两个独立功能：

```bash
# ① 逐位比对，报出**第一个**不一致的索引、期望值、实际值
python golden_compare.py compare hw_out.bin golden.bin --shape 96x96 --dtype uint8

# ② 从 HLS/实现报告抽指标，生成可对比的 markdown 表
python golden_compare.py report --csynth csynth.rpt --impl impl.rpt
```

**为什么有用**：
- "比对失败"如果不说清错在哪，等于没说 —— 本工具定位到**首个**不一致点
- `csynth.rpt` 几百行，人肉找 II / Latency / 资源既慢又容易漏
- **比赛要求的"优化前后对比表"就是这个 `report` 输出**

**失效条件**：`compare` 要求两个文件**元素类型与数量一致**；
reshape 的 `--shape` 必须与数据布局匹配（行优先）。

---

## 4. `dma_guard.py` —— DMA 搬运 + cache 一致性

封装 Zynq 上最容易出错的一环：**DMA 绕过 CPU cache，而 cache 漏维护不报错**。

```python
from dma_guard import DmaTransfer
DmaTransfer(src_buf, src_len).to(dst_buf)   # 自动处理 flush/invalidate
```

**失效条件**：
- 针对 **Zynq-7000 的 ARM Cortex-A9**。**Zynq UltraScale+ / Versal 的缓存架构不同**，不可直接套用。
- 需要 buffer 按 **cache line 对齐**。
- 只在**真实板卡**上有意义 —— 主机侧跑不了。

---

## 汇总

| 工具 | 通用性 | 已验证 | 未验证 |
|---|---|---|---|
| `ip_contract.py` | 高 | 压缩比 307 KB → < 3 KB（实测） | 非 2025.2 版本 |
| `gen_host_stub.py` | 高 | 生成逻辑经主机自检 | 上板 |
| `golden_compare.py` | 高 | 比对定位逻辑 | 上板 |
| `dma_guard.py` | **中**（限 Zynq-7000） | — | **上板**（无板跑不了） |

> 四个工具都不依赖本项目的任何代码，但都依赖 PYNQ / 裸机环境。
> **无板时只能做静态检查。**
