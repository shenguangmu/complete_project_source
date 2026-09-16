# 纯 GUI 复现指南

全程鼠标操作，不敲任何命令，走完 **HLS → 导出 IP → Vivado 集成 → XSA → 裸机工程**。

> **适用**：Vitis / Vivado **2025.2**
> **对照**：命令行版本见 [`../README.md`](../README.md) §3。两条路等价，选一条即可。
>
> 本指南里的菜单路径与界面元素来自本机实机确认（Vitis Unified IDE 2025.2），
> 但不同分辨率/主题下位置可能略有出入，按名字找即可。

---

## 0. 开始前要做的两件事

### 0.1 生成测试向量（GUI 里没有按钮）

```bash
python sim/gen_vectors.py
```

产出 `sim/vectors/` 下 13 个文件。HLS 的 C 仿真会读它们。

> 嫌麻烦也可以跳过 —— 那样 C 仿真里只有「自一致性」8 组会跑，
> 「外部向量」6 组自动跳过，仍然是 PASS。但建议跑一下，覆盖更全。

### 0.2 设好 `XILINX_VIVADO`（否则打包 IP 会失败）

**导出 IP 那一步要靠 Vivado 完成打包**，而 HLS 是通过环境变量
`XILINX_VIVADO` 找 Vivado 的。没设对就会在最后一步报：

```
INFO: [IMPL 213-8] Exporting RTL as a Vivado IP.
ERROR: [IMPL 213-4] Cannot find Vivado, please check XILINX_VIVADO
      environment variable: D:\vivado_new\2026.1\Vivado
Failed to run synthesis
```

注意前面综合**全都成功了**（能看到 `Estimated Fmax: 138.17 MHz`），
只有打包失败 —— 别以为整个流程挂了。

设置方法：

```bash
# git-bash
export XILINX_VIVADO=D:/BaiduNetdiskDownload/2025.2/Vivado

# cmd（重启 IDE 前先设好，或设成系统环境变量）
set XILINX_VIVADO=D:\BaiduNetdiskDownload\2025.2\Vivado
```

> **报错信息里的路径可能不是你装的版本**。如果机器上以前装过别的
> Vivado 版本，环境变量可能残留了旧路径（上面报的是 `2026.1`）。
> 设成当前实际安装路径覆盖掉它。
>
> **从 GUI 里跑就没这个问题** —— Vitis IDE 会自己把 Vivado 路径配好。
> 这条主要影响命令行调用。

---

## 先读这条：GUI 的 csim 有个「假成功」陷阱

Vitis GUI 打开组件后，会**自动往 `hls_config.cfg` 末尾追加一条**：

```ini
csim.setup=1
```

`setup=1` 的含义是**只编译 `csim.exe`，不运行**。此时日志会打印：

```
INFO: [HLS 200-2035] Skipping execution of C Simulation due to 'setup' option
C-simulation finished successfully
```

**界面显示成功，但一行测试都没跑。**

项目里的 `hls_config.cfg` 已把这一项写成 `csim.setup=0`（编译并执行）。
但 GUI 有可能在你打开组件时又改回 1，所以：

> **跑完 C Simulation 后，一定去 `CONSOLE` 里搜 `TB PASSED`。
> 搜不到就是没真跑，把 `csim.setup` 改成 `0` 再跑一次。**

这是本项目实测踩到的坑，不是猜测。

---

## 为什么要「组件式」而不是直接开 HLS 工程

Vitis 2025.2 **取消了独立的 Vitis HLS 图形界面**。HLS 现在是统一 IDE 里的一个
**Component（组件）**类型：

- 左侧 `VITIS EXPLORER` 里新建 **HLS Component**
- 该组件**必须依附于一个 workspace**
- 顶层、源码、器件等由一个 `hls_config.cfg` 描述

项目根目录已经准备好 `hls_config.cfg`，GUI 向导可以直接引用它，
也可以让向导自己生成。

---

## 第一部分：HLS 组件（Vitis）

### 1.1 启动

双击桌面 **`Vitis 2025.2.lnk`**。

等窗口出现，标题栏显示 `Welcome - Vitis Unified IDE 2025.2` 即就绪（首次约 1 分钟）。

### 1.2 打开 workspace

左侧 `VITIS EXPLORER` 面板若显示 **"You have not yet opened a workspace."**，
必须先建/开一个 workspace —— **不打开 workspace 无法新建组件**。

点 **`Set Workspace`**（或菜单 `File > Set Workspace`），选择：

```
E:\project\vitis_ws
```

目录不存在时会提示创建，确认即可。

### 1.3 新建 HLS 组件

中间欢迎页的 **HLS Development** 面板 → 点 **`New HLS Component`**。

> 如果欢迎页已关掉：菜单 `File > New Component > HLS`，
> 或在 `VITIS EXPLORER` 空白处右键 → `New Component`。

### 1.4 填向导

向导分几页，按下面填：

| 页面 | 字段 | 填什么 |
|---|---|---|
| 第 1 页 | Component name | `sobel_accel_comp` |
| | Component location | `E:\project`（组件会建在 `E:\project\sobel_accel_comp\`） |
| | **Use an existing configuration file** | ✅ 勾上，选 `E:\project\hls_config.cfg` |
| 第 2 页 | Part | `xc7z020clg400-1`（选 Zynq-7000 系列） |
| | Top Function | `sobel_accel`（勾了 cfg 会自动填好） |
| | Clock Period | `10` ns |
| 第 3 页 | Sources | `src_hls/sobel_hls.cpp` 应已自动列出 |
| | Test Bench | `src_hls/tb_sobel.cpp` 应已自动列出 |

> **勾了 `hls_config.cfg` 之后，后面几页基本都会自动填好**，
> 直接 `Next` 到底即可。cfg 的内容见文末附录。

点 **`Finish`**。

**建好后的目录结构**（实测）：

```
E:\project\sobel_accel_comp\        ← 组件目录（Component name）
├── vitis-comp.json                 组件的元数据
└── sobel_accel\                    ← work_dir
    └── hls\
        ├── csim\                    C 仿真
        └── impl\ip\                 打包出的 IP（component.xml）
```

### 1.5 跑 C 仿真

在 `VITIS EXPLORER` 里展开 **`sobel_accel_comp`** → 展开 **`HLS`**。

右键 **`C Simulation`** → **`Run`**（或点上方工具条的运行按钮）。

**底部 `CONSOLE` 里必须看到：**

```
[1] 自一致性：流式实现 vs 朴素实现
  [gradient] 64x48   hw vs sw : PASS
  ... 共 8 组 ...
[2] 外部向量：流式实现 vs Python golden
  ... 共 6 组 ...
  TB PASSED
```

> ⚠️ **只看到 `C-simulation finished successfully` 而没有 `TB PASSED`，
> 就是没真跑** —— 见本文开头「假成功陷阱」，把 `csim.setup` 改成 `0` 重跑。
>
> 若 6 组外部向量显示「缺失」，说明没跑 §0，或向量目录没被找到 ——
> 不影响结论，但建议回去跑一下。
>
> **报错时**：`CONSOLE` 里会有 clang 的原始编译错误，
> 位置一般指向 `sobel_hls.cpp` 或 `tb_sobel.cpp`。

### 1.6 跑 C 综合

同一个 `HLS` 节点下，右键 **`C Synthesis`** → **`Run`**（约 1 分钟）。

**看两处：**

1. `CONSOLE` 里出现 `Finished C Synthesis`
2. 右侧或弹出的报告里 **Performance Estimates** 段：

```
|   Latency (cycles) | ... |    Interval   | Pipeline
|   min   |   max    | ... | min |   max   |   Type
|       1 |  2077706 | ... |   1 | 2077707 |   no
```

**关键看 `Interval` 那一列的 min 是不是 1** —— 是 1 就说明流水线达成了
每周期 1 像素（II=1），本设计的核心指标。

再看看 **Utilization Estimates**，应接近：

| 资源 | 值 |
|---|---|
| LUT | ~1826 |
| FF | ~903 |
| DSP | 1 |
| BRAM_18K | 3 |

### 1.7 导出 IP（关键一步）

在 `HLS` 节点下右键 **`Package`**（有些版本叫 `Export` / `Package IP`）→ **`Run`**。

**产出**在：

```
E:\project\sobel_accel_comp\sobel_accel\hls\impl\ip\
```

里面有 `component.xml`、`hdl/`、`drivers/`。

> **注意产物形态**：`export_design` 产出的是 **IP 目录**（`component.xml` 结构），
> **不是 `.xci` 文件**。所以下一步 Vivado 里要用
> `IP Catalog → Add Repository` 注册目录，**不是** `Add Sources` 加文件。
> 这是本项目的踩坑点之一，详见 README §9.8。

---

## 第二部分：Vivado 集成

### 2.1 启动

双击桌面 **`Vivado 2025.2.lnk`**，等主界面出现。

### 2.2 新建工程

`File > Project > New`（或欢迎页 `Create Project`）→ `Next`：

| 页 | 填什么 |
|---|---|
| Project Name | `sobel_system` |
| Project Location | `E:\project\vivado` |
| Project Type | **RTL Project**，勾 `Do not specify sources at this time` |
| Default Part | `xc7z020clg400-1`（Zynq-7000 / Zynq-7020） |
| | 若装了板卡文件，也可选 `Boards` 里的 PYNQ-Z2 / Zybo Z7-20 |

`Finish`。

### 2.3 把 HLS IP 加进 IP Catalog

左侧 `Flow Navigator` → **`PROJECT MANAGER` → `IP Catalog`**。

在 `IP Catalog` 窗口里右键空白处 → **`Add Repository...`**
（或 `IP Catalog` 工具条的 `Add Repository` 按钮）。

浏览到：

```
E:\project\sobel_accel_comp\sobel_accel\hls\impl\ip
```

选中目录本身，`Select`。弹出确认框直接 `OK`。

> 加对了的话，`IP Catalog` 搜索框里打 `sobel` 就能搜到
> **`sobel_accel`**（分类在 `User IP` 或 `HLS` 下）。
>
> 忘了路径？`vivado/check_ip.tcl` 会把实际找到的目录打印出来，
> 它的查找逻辑同时覆盖 GUI 和命令行两条流程的产物位置。

### 2.4 建 Block Design

`Flow Navigator` → **`IP INTEGRATOR` → `Create Block Design`**。

- Design name: `sobel_bd`
- `OK`

### 2.5 加 Zynq PS

画布中点 **`+`**（`Add IP`）→ 搜 `ZYNQ` → 双击 **`ZYNQ7 Processing System`**。

然后**双击**画布上刚出现的 `processing_system7_0` 打开配置，切到
**`PS-PL Configuration`** 页，在左侧树里：

| 树节点 | 设置 |
|---|---|
| `PS-PL Configuration > AXI Non Secure Enablement > Master Interface` | 勾 **`M AXI GP0 interface`** |
| `PS-PL Configuration > AXI Non Secure Enablement > Slave Interface` | 勾 **`S AXI HP0 interface`** |

> **这两个是必须的**：GP0 走控制（配寄存器），HP0 走数据（DMA 读写 DDR）。
> 少了 HP0，后面 DMA 的数据口没地方连。

`Clock Configuration > PL Fabric Clocks` 里确认 **`FCLK_CLK0` 勾上，频率 `100` MHz**。

`OK` 保存。

> 若用板卡预设，可直接跑 `Run Block Automation`（见 2.6）让它自动配 DDR/UART，
> 但**跑完要回来检查 HP0 是否还在**（板卡预设有时会重置接口配置）。

### 2.6 加 AXI DMA

点 **`+`** → 搜 `DMA` → 双击 **`AXI Direct Memory Access`**。

双击它打开配置：

- **`Enable Scatter Gather Engine`** → **取消勾选**（用简单模式）
- `Width of Buffer Length Register` 保持默认（26）
- `Memory Map Data Width` → `32`
- `Stream Data Width` → **`8`**（和 Sobel IP 的 8-bit 数据对齐）
- `Max Burst Size` → `64`（可选，提高带宽）

`OK`。

### 2.7 加 Sobel IP

点 **`+`** → 搜 `sobel` → 双击 **`sobel_accel`**。

### 2.8 加复位模块

点 **`+`** → 搜 `System Reset` → 双击 **`Processor System Reset`**。

### 2.9 自动连线（推荐）

点画布上方的 **`Run Connection Automation`**（或 `Run Block Automation` 先跑）。

弹窗里默认会全勾上，直接 `OK`。Vivado 会自动接好：

- 复位
- `DDR` / `FIXED_IO` 引出为外部端口
- **GP0 → AXI Interconnect → DMA 的 `S_AXI_LITE` + Sobel 的 `s_axi_control`**
- **DMA 的 `M_AXI_MM2S` / `M_AXI_S2MM` → `S_AXI_HP0`**
- DMA 的部分时钟

> ⚠️ **自动连线会漏掉 DMA 的 `m_axi_s2mm_aclk`。**
> 这是实测踩到的：Validate 时报
> ```
> [BD 41-758] The following clock pins are not connected to a valid clock source:
> /axi_dma_0/m_axi_s2mm_aclk
> ```
> 这个引脚是 **S2MM 通道写回 DDR 用的时钟**，漏了它 DMA 收完数据写不回去，
> **必须接上**。

### 2.9b 补齐 DMA 时钟 + 内存互联（**必做，两步都别漏**）

自动连线在 DMA 这块有两个坑，**都实测踩到过**：漏连时钟、漏连 S2MM 回来。

先在 **Tcl Console**（Vivado 窗口底部）跑这段，它会把 DMA 时钟和
S2MM 回来的通路一次补齐（已完成的会自动跳过）：

```tcl
# --- (1) DMA 三个时钟引脚 ---
set clk [get_bd_pins processing_system7_0/FCLK_CLK0]
foreach p {s_axi_lite_aclk m_axi_mm2s_aclk m_axi_s2mm_aclk} {
    set pin [get_bd_pins axi_dma_0/$p]
    if {[get_bd_nets -quiet -of_objects $pin] eq ""} {
        connect_bd_net $clk $pin
        puts "时钟已接: $p"
    } else {
        puts "时钟本来就有: $p"
    }
}

# --- (2) 内存互联扩到 2 个从接口，接上 S2MM 回来 ---
set_property -dict [list CONFIG.NUM_SI {2}] [get_bd_cells axi_mem_intercon]
if {[get_bd_nets -quiet -of_objects [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]] eq ""} {
    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                        [get_bd_intf_pins axi_mem_intercon/S01_AXI]
    puts "S2MM 已接回内存互联"
} else {
    puts "S2MM 本来就有"
}
```

如果新增的 `S01_AXI` 缺时钟/复位，画布上会标红，或用 `validate_bd_design`
报出来，照提示拖线补上即可（`S01_ACLK` 接同一个 `FCLK_CLK0`，
`S01_ARESETN` 接复位模块的 `peripheral_aresetn`）。

> ⚠️ **为什么必须补 S2MM**：`M_AXI_S2MM` 是 **DMA 把结果写回 DDR 的通路**。
> 悬空的话 MM2S 能读输入，但结果永远写不回去，板上表现为挂死或超时。
> **Vivado 不会为此报错**，实现照样通过 —— 只在 Address Editor 里
> 显示成 `Incomplete Paths`。很容易漏掉。
>
> 对照组：`vivado/bd_sobel.tcl`（命令行流程）在建互联时就显式写了
> `CONFIG.NUM_SI {2}` 并接了两条线，还加了引脚存在性断言，
> 所以不会静默放过。

接完 `Ctrl+S` 保存。

### 2.10 手动补接 AXI-Stream（自动化不会接）

自动连线**不包含** AXI-Stream。手动拖两条线：

| 从 | 到 |
|---|---|
| `axi_dma_0` 的 **`M_AXIS_MM2S`** | `sobel_accel_0` 的 **`s_axi_control` 旁边那个 `src`** |
| `sobel_accel_0` 的 **`dst`** | `axi_dma_0` 的 **`S_AXIS_S2MM`** |

> **端口名是 `src` / `dst`，不是 `s_axis_video` / `m_axis_video`。**
> HLS 2025.2 的 axis 端口直接用 C 函数参数名命名。
> 在画布上把鼠标悬停在 IP 的接口上能看到名字。
>
> 接好后接口连线应显示为**深色实线**（表示协议匹配成功）。
> 如果是**红色虚线**，说明协议不匹配，多半是 2.6 里的 `Stream Data Width` 没设成 8。

### 2.11 检查连线

画布上地址编辑器（`Address Editor` 标签页）应自动分配好：

| 从 | 到 | 地址 |
|---|---|---|
| `processing_system7_0/M_AXI_GP0` | `axi_dma_0/S_AXI_LITE` | 如 `0x40400000` |
| `processing_system7_0/M_AXI_GP0` | `sobel_accel_0/s_axi_control` | 如 `0x40410000` |

**记下 `sobel_accel_0/s_axi_control` 的地址**和 `axi_dma_0` 的地址 ——
写裸机程序时要用（不过 Vitis 会从 XSA 自动生成 `xparameters.h`，通常不用手抄）。

回到 `Diagram` 标签页，点工具条的 **`Validate Design`**（`F6`）。

**弹窗应显示 "Validation successful"，且底部 `Messages` 里没有
`CRITICAL WARNING` 和 `ERROR`。**

两种常见的校验报错，对照处理：

| 报错 | 原因 | 处理 |
|---|---|---|
| `[BD 41-758] ... /axi_dma_0/m_axi_s2mm_aclk` | 自动连线漏了 DMA 时钟 | §2.9b |
| `Interface connected to S_AXIS_S2MM does not have TLAST port` | IP 是旧版（裸 stream 类型） | 按 README §9.6 重新导出 IP |

> `41-758` 也可能点出 `m_axi_mm2s_aclk` —— 一并按 §2.9b 那段处理即可，
> 它对三个时钟引脚都生效。

**另外记得扫一眼 `Address Editor` 标签页**（Validate 不会替你查这个）：

每个 Network 下面应该都有从设备。如果哪个 Network 显示
**`Incomplete Paths`**，说明该通路上有主设备悬空 —— 最常见的就是
`axi_dma_0/M_AXI_S2MM` 没接（见 §2.9b）。
**这个问题 Vivado 的实现流程不会报错，只会静默通过**，
但板上表现为结果写不回 DDR、程序挂死。

可对照实测的正确状态：

| Network | 主设备 → 从设备 |
|---|---|
| 0 | `axi_dma_0/M_AXI_MM2S` → `processing_system7_0/S_AXI_HP0` |
| 1 | `axi_dma_0/M_AXI_S2MM` → `processing_system7_0/S_AXI_HP0` |
| 2 | `processing_system7_0/M_AXI_GP0` → `axi_dma_0/S_AXI_LITE` 与 `sobel_accel_0/s_axi_control` |

### 2.12 保存并生成 wrapper

1. `Ctrl+S` 保存 Block Design
2. `Sources` 面板里右键 `sobel_bd.bd` → **`Create HDL Wrapper`**
3. 选 **`Let Vivado manage wrapper and auto-update`** → `OK`

### 2.13 综合与实现

`Flow Navigator` 左侧：

1. 点 **`Generate Bitstream`**（会自动把 `Synthesis` 和 `Implementation` 都跑完）

   或分步：`Run Synthesis` → 完成后 `Run Implementation` → 再 `Generate Bitstream`

约几十分钟。完成后弹窗选 `View Reports` 或直接 `Cancel`。

**看 `Design Timing Summary`：** `WNS` 应为**正数**（时序收敛）。

**对照实测值**（本项目在这台机器上的真实结果，供判断是否正常）：

| 指标 | 实测值 |
|---|---|
| WNS / TNS | **+1.100 ns** / 0.000 ns |
| WHS / THS | +0.029 ns / 0.000 ns |
| 全部时序终点 | 11709 个，**0 个失败** |
| Slice LUTs | 3479 / 53200（**6.54%**） |
| Slice Registers | 4413 / 106400（4.15%） |
| Block RAM Tile | 3.5 / 140（2.50%） |
| DSPs | 1 / 220（0.45%） |
| Total On-Chip Power | 1.696 W（Dynamic 1.559 W） |

> 数字明显偏大或 WNS 为负就要查了。注意这些是**整个 Block Design** 的
> 占用（含 PS7、DMA、互联），比 HLS 报告里单算 Sobel IP 的数字大是正常的。

报告位置：`vivado/sobel_system.runs/impl_1/sobel_bd_wrapper_*.rpt`

### 2.14 导出 XSA

`File > Export > Export Hardware`：

- **勾上 `Include bitstream`**
- 文件名：`sobel_system.xsa`
- 路径：`E:\project\vivado`

`Finish`。

---

## 第三部分：裸机程序（Vitis）

### 3.1 新建 Platform 组件

回到 **Vitis**（已在运行的窗口）。

`File > New Component > Platform`：

| 字段 | 填什么 |
|---|---|
| Component name | `sobel_platform` |
| XSA | `E:\project\vivado\sobel_system.xsa` |
| Operating System | `standalone` |
| Processor | `ps7_cortexa9_0` |

`Finish`。等它把 BSP 建好（几分钟，`CONSOLE` 里会刷进度）。

### 3.2 新建 Application 组件

`File > New Component > Application`：

| 字段 | 填什么 |
|---|---|
| Component name | `sobel_app` |
| Platform | `sobel_platform`（选刚建的） |
| Domain | `standalone_ps7_cortexa9_0` |
| Template | **`Empty Application (C)`** |

`Finish`。

### 3.3 加入驱动源码

在 `VITIS EXPLORER` 里展开 `sobel_app` → 右键 **`src`** → **`Import Sources...`**
（或直接把文件从资源管理器拖进 `src`）。

选中这四个（`E:\project\sw\` 下）：

- `sobel_driver.h`
- `sobel_driver.c`
- `sim_dma.c` ← **不导入**，那是主机仿真用的
- `main.c`

> **只导入 `sobel_driver.h` / `sobel_driver.c` / `main.c` 三个**，
> 不要导入 `sim_dma.c`（它和驱动里的 `sim_sobel_execute` 配套，
> 只在 PC 上编译时才用，导进来会和 BSP 冲突）。

### 3.4 确认基地址

`main.c` 里这两个宏来自 `xparameters.h`，一般不用改：

```c
XPAR_SOBEL_ACCEL_0_BASEADDR
XPAR_AXI_DMA_0_BASEADDR
```

**核对方法**：`VITIS EXPLORER` 里展开 `sobel_platform` →
`ps7_cortexa9_0 > standalone_ps7_cortexa9_0 > include > xparameters.h`，
打开搜这两个宏，看是否存在。

> 若名字对不上（Vivado 里改过 IP 实例名），把 `main.c` 里的宏改成实际名字，
> 或直接用 2.11 记下的地址字面量。

### 3.5 编译

右键 `sobel_app` → **`Build`**（或工具栏锤子图标）。

**`CONSOLE` 里应出现 `Build Finished`，无 error。**

### 3.6 上板运行

1. 板子接好 JTAG + 串口，上电
2. 右键 `sobel_app` → **`Run`** → 选 **`Launch Hardware`**
3. 打开串口终端（Vitis 里：`Terminal > Serial Monitor`，波特率 **115200**，
   端口选板子的 COM 口）

**应看到**：

```
=====================================================
  Sobel 边缘检测加速器 —— 驱动 Demo
  图像 64x48 (3072 字节)
  模式：Zynq 裸机
=====================================================

[ OK ] 初始化完成
[ OK ] 配置 64x48  thresh=0  gain=256
[ OK ] 处理完成
       耗时      : xxxxx 周期  (xx.xx us @ 666666667 Hz)
       吞吐      : xxx.xx Mpx/s
       边缘像素  : 852 / 3072
>>> 边界测试
       超大宽度       -> 已拦截 (期望 -1)
       空指针输入     -> 已拦截 (期望 -1)
       未对齐源地址   -> 已拦截 (期望 -1)
```

后面还会打印一张 ASCII 边缘图，能看出色带边缘和方块轮廓。

---

## 附录 A：`hls_config.cfg` 内容

项目根目录已有此文件，向导里勾选即可。

**核心的几项（需要你维护）：**

```ini
part=xc7z020clg400-1

[hls]
syn.file=./src_hls/sobel_hls.cpp
syn.top=sobel_accel
tb.file=./src_hls/tb_sobel.cpp
clock=10
```

| 键 | 含义 |
|---|---|
| `part` | 目标器件。换板子改这里 |
| `syn.file` | 综合的源文件（相对 cfg 所在目录） |
| `syn.top` | 顶层函数名 |
| `tb.file` | C 仿真 testbench（不填则 GUI 里没有 C Simulation） |
| `clock` | 时钟周期，单位 ns。10 = 100 MHz |

**GUI 会自动追加的项**（不用手写，但要知道含义）：

```ini
package.output.format=ip_catalog   # 导出 IP 目录而非 .xci
flow_target=vivado
sim.O=1                            # 优化等级
csim.clean=1                       # 每次 csim 前清理
csim.setup=0                       # ⚠️ 0=编译并执行，1=只编译不跑
csim.profile_tripcount=1
```

> `csim.setup` 是唯一**必须盯着**的一项 —— 见本文开头的「假成功陷阱」。
>
> **GUI 会重写这个文件**：打开组件后，工具会把开头的说明注释压掉、
> 并重新排列追加项。这是正常行为，不是出错。手写的注释可能丢失。

---

## 附录 B：GUI 与命令行两条路的对照

| 阶段 | 命令行 | GUI |
|---|---|---|
| 生成向量 | `python sim/gen_vectors.py` | **无对应按钮，仍需命令行** |
| HLS 综合 | `vitis-run --mode hls --tcl src_hls/run_hls.tcl` | Vision IDE → HLS Component |
| C 仿真 | 同上（含 csim） | 右键 `C Simulation > Run` |
| 导出 IP | 同上（含 export） | 右键 `Package > Run` |
| 建 Vivado 工程 | `vivado -mode batch -source vivado/create_project.tcl` | `File > Project > New` 向导 |
| Block Design | `vivado/bd_sobel.tcl` | 画布上手动拖 |
| 导出 XSA | `create_project.tcl` 自动 | `File > Export > Export Hardware` |
| 裸机工程 | Vitis 里手建 | 同 |

**建议**：GUI 适合**理解流程**和**调试**（能看综合报告、能单步改配置）；
命令行适合**重复构建**。两者产出的 IP 完全一致（同一个 HLS 内核），
可以混用 —— 比如用命令行跑 HLS，用 GUI 看报告。

---

## 附录 C：GUI 常见问题

| 现象 | 原因 / 对策 |
|---|---|
| `New HLS Component` 是灰的 | 没打开 workspace。先 `Set Workspace` |
| **csim 报成功但没有 `TB PASSED`** | **`csim.setup=1` 只编译不运行。改成 `0` 重跑**（见文首） |
| **综合成功但打包 IP 报 `Cannot find Vivado`** | **`XILINX_VIVADO` 没设或指向旧版本。见 §0.2** |
| IP Catalog 里搜不到 `sobel_accel` | 仓库目录加错了。要指向含 `component.xml` 的那层 `impl/ip`，不是上层 |
| AXI-Stream 连线是红虚线 | `Stream Data Width` 不匹配。DMA 侧设成 8 |
| `Validate Design` 报 TLAST | IP 是旧版（裸 stream 类型）。重新导出，见 README §9.6 |
| `[BD 41-758] ... not connected to a valid clock source` | 自动连线漏了 DMA 时钟，常见是 `m_axi_s2mm_aclk`。见 §2.9b |
| `[Netlist 29-160] Cannot set property 'iostandard' ... objects of type 'pin'` | **无害，忽略**。Vivado 为 PS7 生成的 OOC 约束（`.gen/` 下）把 `get_ports` 作用域到了 IP 实例上，于是拿到的是 pin 而非 port。PS7 的 DDR 是硬核脚，电气标准由 PS 配置决定，本就不该用 IOSTANDARD 设。实现能正常收敛 |
| Address Editor 里某个 Network 显示 `Incomplete Paths` | **主设备悬空，常见是 `M_AXI_S2MM` 没接**。见 §2.9b。**实现不会报错，但板上必挂** |
| 综合后 `Interval` 的 min 不是 1 | `PIPELINE II=1` 没生效。检查 `sobel_hls.cpp` 里的 pragma 是否被改动 |
| Vitis Python 脚本报编码错 | 用户名含非 ASCII 时 Vitis CLI 的已知问题。**用 GUI 反而没这个问题** |
| 导出 XSA 时没有 `Include bitstream` | 还没 `Generate Bitstream`。先跑完综合实现 |
| 手写的 cfg 注释消失了 | GUI 会重写 `hls_config.cfg`，属正常。别把关键信息只写在注释里 |
| 日志里有 `unknown escape sequence` | 多半是**旧 job 的残留日志**（改了源码但复用了构建目录）。清掉 `hls/syn`、`hls/csim` 重跑即可 |
