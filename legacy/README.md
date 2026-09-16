# legacy/sobel —— 原 Sobel 加速器工程

> ⚠ **这是本项目的起点，不是主线。**
> 主线代码在仓库根目录（手势识别系统）。
>
> 保留它是因为：本项目多处引用它作为**参照** ——
> 尤其是 `src_hls/gesture_preproc.cpp` 的 3×3 行缓存骨架
> （`win_push()`）直接搬自这里的 `src_hls/sobel_hls.cpp`，
> 那是唯一经过完整硬件流程验证（csynth II=1、时序收敛）的骨架。

---

## 它是什么

Zynq-7000 上的 Sobel 边缘检测加速器：

```
PS ──GP0──► AXI-Lite ──┬──► sobel_accel/s_axi_control
                       └──► axi_dma/S_AXI_LITE
PS ──HP0──◄── ic_mem ◄─┬── dma0/M_AXI_MM2S
                       └── dma0/M_AXI_S2MM
dma0/M_AXIS_MM2S ──► sobel_accel/src
sobel_accel/dst ────► dma0/S_AXIS_S2MM
```

- **HLS**：`src_hls/sobel_hls.cpp` —— 已验证 **csim PASS / csynth II=1 / WNS +1.100 ns**
- **BD**：`vivado/bd_sobel.tcl`
- **驱动**：`sw/sobel_driver.c` —— 含主机仿真模式
- **完整文档**：`README.md`（**§9 的踩坑记录值得一读**）

---

## 目录结构

```
legacy/sobel/
├── README.md                 完整工程文档（含 §9 踩坑，9 条）
├── docs/GUI复现指南.md        纯 GUI 复现流程（本机实测过）
├── hls_config.cfg            HLS 工程配置
├── src_hls/
│   ├── sobel_hls.cpp/.h      Sobel 加速器（★ 被主项目引用的骨架）
│   ├── tb_sobel.cpp
│   └── run_hls.tcl
├── sw/                       裸机驱动 + 主机仿真
├── host/sobel_ref.py         Python golden 参考
├── sim/                      测试向量生成与比对
└── vivado/
    ├── bd_sobel.tcl          Block Design
    ├── create_project.tcl    一键建工程
    ├── check_ip.tcl          检查 IP 接口
    └── constraints/sobel_io.xdc
```

---

## ⚠ 这个工程里有一个**值得看的坑**

`sw/sobel_driver.h` 里记录了一个**只有上板才会暴露**的驱动器 bug：

> 驱动的状态位本该读 `CTRL(0x00)` 的 bit1，却写成了读 `0x04`。
> 而 `0x04` 实际是 **GIER（全局中断使能）**，不是状态寄存器。
>
> **为什么一直没发现**：主机仿真自己在 `0x04` 位置写了假的状态值，
> 所以仿真"完美通过"。真机上轮询 `0x04` 永远等不到 `AP_DONE`。

**这个 bug 已修**（本目录里的代码是修好的版本），但**教训保留在注释里** ——
新项目 `sw/preproc_driver.c` 从一开始就用对的位置，正是因为踩过。

详见 `README.md` 与 fpga-dev skill 的 `09-pitfalls.md` D2。

---

## 相关

- **主项目**：仓库根目录（手势识别系统）
- **这个工程的角色**：参照 / 起点。已跑通综合实现比特流、时序收敛
