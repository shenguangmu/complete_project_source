# 手势识别系统 —— PL 侧

> **本项目从本仓库 `legacy/sobel/` 下的 Sobel 加速器工程复制改造而来。**
> 改造中 Sobel 相关内容已从主线移除，那个参照工程完整保留在 `legacy/sobel/`。
> 详见下文「原 Sobel 工程在哪」。
>
> ## 当前进度（2026-09-16）
>
> | 部分 | 内容 | 状态 |
> |---|---|---|
> | **HLS 处理链** | `src_hls/gesture_preproc.cpp` | ✅ **csim + csynth + cosim 全过**（cosim 6/6 事务），IP 已导出 |
> | **RTL 外设** | `rtl/`：DVP 采集 + SCCB + 异步 FIFO + IOBUF + 寄存器表 | ✅ 3/3 TB PASSED |
> | **BD 视频流水线** | `vivado/bd_video.tcl`（含预处理链 + Clocking Wizard + SCCB） | ✅ validate + 综合 + 实现 |
> | **约束** | `vivado/constraints/video_io.xdc`（摄像头引脚已启用） | ✅ 综合验证生效 |
> | **PS 侧驱动** | `sw/preproc_driver.c` | ✅ 主机自检 24/24 |
> | **时序 / 比特流 / XSA** | 实现后实测 | ✅ **WNS +0.265 ns**（`All user specified timing constraints are met`），比特流 4.0 MB，XSA 750 KB |
> | **OV5640 寄存器表** | `rtl/ov5640_regs.v` | ⚠️ **已替换为真实配置表**（250 条，正点原子来源，固化 640×480 RGB565），**但未上板实测** |
> | HDMI 输出 | TMDS 编码器 | ⚠️ 未做（端口暂用 DRC 豁免，见 `vivado/README.md`） |
> | 板级实测 | — | ❌ 板子未到 |
> 
> ⚠ **WNS 逐次波动较大**：同一设计三次实现的实测为 +0.873 / +1.177 / **+0.265** ns。
> 布线是随机过程，每次结果不同。
>
> ⚠⚠ **且 `+0.265` 不是本设计的余量** —— 2026-09-18 查证：全设计
> 10 条最差 setup 路径**全部属于 AMD `v_tc` IP 内部**（布线 9.1 ns、
> 逻辑仅 0.64 ns 的扇出 433 网），改我们的 RTL/HLS 对它零影响。
> 本项目自己的 HLS 流水线余量是 **+43%**（csynth 估 143 MHz / 目标 100 MHz）。
> 详见 [`report/design.md` §4.5](report/design.md)。
>
> **一句话**：软件侧全部就绪（含 OV5640 配置表），只差板子到货 + 上板实测。
> ⚠ 上板前必读 `docs/hardware-checklist.md` §3.3（引脚万用表复核）。
>
> ### 一键回归
>
> **在工程根目录**（即本仓库克隆下来的顶层目录）下逐条执行：
>
> ```bash
> bash rtl/run_iverilog.sh                             # RTL（秒级，无需 license）
> bash sw/build_preproc_sim.sh                         # 预处理驱动主机自检
> python host/test_overlay_offline.py                  # PYNQ 驱动离线自检（无需板子）
> vitis-run --mode hls --tcl src_hls/run_gesture.tcl   # HLS csim + csynth
> vivado -mode batch -source vivado/test_bd_video.tcl  # BD 构建 + validate
> vivado -mode batch -source vivado/test_video_io_xdc.tcl  # XDC + 综合
> ```
>
> **前三条不需要板子、不需要 license，已挂进 CI**（见下）。
>
> **板到了之后**，②③ 两步（DDR 自检 + 只跑预处理链，**不需要摄像头**）
> 用这个脚本一次跑完：
>
> ```bash
> python3 host/bringup_check.py          # 在 PYNQ 板上跑
> ```
> **加跑 C/RTL 协同仿真**（验证综合后的 RTL 行为与 C 一致，慢）：
>
> ```bash
> GESTURE_COSIM=1 vitis-run --mode hls --tcl src_hls/run_gesture.tcl
> ```
>
> ### 自动化回归（GitHub Actions）
>
> 上面**前三条**（纯 RTL 回归 / 预处理驱动主机自检 / PYNQ 驱动离线自检）
> 已挂到 CI，每次 push / PR 自动跑；结果见仓库 **Actions** 页。
> 这三个都**不需要 license、不需要板子、秒级完成**，所以适合自动跑。
>
> | job | 覆盖 |
> |---|---|
> | `rtl-sim` | 3 个 RTL 测试台（iverilog） |
> | `sw-sim` | PS 驱动控制流（纯 C） |
> | `overlay-offline` | PYNQ 驱动的参数检查与寄存器编码（纯 Python） |
>
> 第三个 job 是 2026-09-18 加的 —— 因为那天在那里发现了一个
> **静默 bug**（有符号阈值偏置写成 8 位补码，IP 读回来从 -8 变 +248，
> 输出全黑且不报错）。**这类"不需要板子、纯逻辑"的东西必须进 CI**，
> 否则永远不会被发现。
>
> 需要 Vivado/Vitis 的那几条（HLS、BD、综合）**没有**进 CI ——
> 跑一次要几十分钟且需要 license，代价不成比例。
> ⚠ **640×480 下 cosim 要跑很久**（实测仿真时间约 1.3 秒 → 实际数十分钟）。
> 想快速验证，把 `src_hls/gesture_preproc.h` 的
> `GESTURE_IN_WIDTH/HEIGHT` 临时改成 64，TB 会自适应。
> 详见 `src_hls/README.md`。
>
> ⚠ **只有前两条加 `bash`** —— 它们自己就是 .sh 脚本。
> 后三条是**外部可执行程序**，前面**不要**再加 `bash`：

### 从零构建完整工程（综合 → 比特流 → XSA）

上面那组命令只到「BD 构建 + validate」，**不出比特流**。
要拿到可上板的 `.bit` 与 `.xsa`，走下面这条链：

```bash
# ① 【必须先做】跑 HLS，产出 IP 仓库
#    create_project.tcl 需要 gesture_comp/solution1/impl/ip/component.xml，
#    没有它脚本会**直接退出**（不是警告，是 exit 1）。
vitis-run --mode hls --tcl src_hls/run_gesture.tcl

# ② 建工程 → 建 BD → 综合 → 实现 → 比特流 → 导出 XSA
vivado -mode batch -source vivado/create_project.tcl

# ③ 只想先看 BD 是否合法（不跑综合，约 1 分钟）
vivado -mode batch -source vivado/create_project.tcl -tclargs --synth 0
```

**产物**（落在 `vivado/gesture_system/`）：

| 文件 | 说明 |
|---|---|
| `gesture_system.xsa` | 含比特流 + `.hwh`，给 Vitis / PYNQ 用 |
| `gesture_system/utilization.rpt` | 资源报告 |
| `gesture_system/gesture_system.runs/impl_1/*.bit` | 比特流 |

> ⚠ **`gesture_comp/`（HLS 产物）不在本仓库里** —— 它被 `.gitignore` 忽略，
> 因为它完全可由 `run_gesture.tcl` 重建。所以**克隆下来必须先跑第 ① 步**。
>
> ⚠ 第 ② 步约 20–40 分钟。中途若报
> `ERROR: [Common 17-354] Could not open 'C' for writing.` 或
> `ERROR: [Common 17-1257] Failed to create directory 'C'.`，
> 那是 OOC 综合的启动竞态（多个 Vivado 实例并发建临时目录）。
> **它对产物无害，但会让 `wait_on_run` 抛错、脚本中断**，
> 所以脚本里有自动重试（最多 3 次）。
>
> 若看到 `>>> synth_1 在第 N 次尝试后完成`，说明重试路径被触发了 ——
> 那是预期行为，不是故障。
>
> ```bash
> bash vivado -mode batch ...      # ✗ 报 "vivado: Is a directory"
> vivado -mode batch ...           # ✓
> ```
>
> 报错原因是本工程里正好有个 `vivado/` **目录**，`bash vivado`
> 会让 bash 去执行那个目录。
>
> ⚠ 这些命令都依赖 **PATH 里有 vivado / vitis-run**。
> 正常装完 Vitis/Vivado 就有；`which vivado` 能查到即可。
> （前两条脚本自带工具路径查找，不依赖 PATH。）
>
> 判定标准：RTL 与 HLS 必须看到 `TB PASSED`；BD 必须看到 `构建完成`。
>
> | 命令 | 依赖 | 耗时 |
> |---|---|---|
> | `run_iverilog.sh` | **iverilog**（脚本自己找 `C:/iverilog/bin`） | 秒级 |
> | `build_preproc_sim.sh` | **任一 C 编译器**：优先 Vitis clang，找不到就退回 PATH 上的 `cc/gcc/clang` | 秒级 |
> | `vitis-run` | 需在 PATH 里（Vitis 安装时导出的环境） | 1–2 分钟 |
> | `vivado` | 需在 PATH 里 | BD 约 1 分钟；综合约 5–10 分钟 |
>
> ⚠ 前两个脚本**自带工具路径查找**，不依赖环境；后两个需要
> Vivado/Vitis 的环境变量已导出（正常装完就有）。
>
> ⚠ **不要为了"干净"把 PATH 裁剪成 `/usr/bin:/bin`** ——
> 那样连 `vitis-run` / `vivado` / `powershell` 都找不到，
> 而错误信息只会说 "command not found"，看不出是 PATH 的问题。
> （本轮实际踩过：为排查 clang 的 DLL 问题裁窄了 PATH，
> 结果绕了一大圈，真正的原因只是 PATH 里少了 clang 目录。）
>
> ### 硬件方案
>
> **MUSE LAB PMOD-CAMERA v1.0**（标准 Pmod 双口，直插，零焊接）。
> 引脚映射与上电前验证步骤见 `docs/hardware-checklist.md`。
> ⚠ 模块原理图是"镜像编号"，**上电前必须万用表复核**，否则可能烧板。
>
> ## 各目录说明
>
> **每个目录都有自己的 README**，说明该目录的文件与关键设计点：
>
> | 目录 | 内容 | 索引 |
> |---|---|---|
> | `src_hls/` | HLS 处理链（含语义契约与实测数据） | [`src_hls/README.md`](src_hls/README.md) |
> | `rtl/` | 手写 Verilog（DVP/SCCB/CDC/IOBUF/寄存器表） | [`rtl/README.md`](rtl/README.md) |
> | `sw/` | PS 侧驱动（预处理链） | [`sw/README.md`](sw/README.md) |
> | `vivado/` | BD 脚本（含 19 个踩坑记录）+ **综合实现报告** | [`vivado/README.md`](vivado/README.md) · [`build-report.md`](vivado/build-report.md) |
> | `docs/` | 架构契约、采购清单、GUI 复现指南 | [`docs/README.md`](docs/README.md) |
> | `host/` | Python golden 参考实现 | — |
> | `sim/` | 测试向量生成与比对 | — |
> | **`skill/`** | **可复用技能包**（PYNQ 工具 / 踩坑清单 / 纠错方法论） | [`skill/README.md`](skill/README.md) |
> | **`report/`** | **设计报告 + 大模型协作记录** | [`report/README.md`](report/README.md) |
>
> ⚠ **目录结构说明**：本仓库的目录组织与赛题推荐结构不同
> （按实现方式而非按 `src/`+`build/` 划分），
> **对照表见 [`docs/README.md`](docs/README.md)**。
> 项目自身目录与文件名**全部为纯英文**。
>
> **推荐阅读顺序**：本文件 → `docs/architecture-contract.md`（做什么、为什么）
> → `docs/hardware-checklist.md`（买什么、怎么接）→ 各模块 README。
>
> ## 一句话说明分工
>
> - **本项目（PL 侧）**：OV5640 采集 → 灰度 → 高斯 → Sobel → 自适应阈值 →
>   形态学 → ROI 裁剪 → 96×96 灰度写入 DDR → HDMI 显示
> - **他人（PS 侧）**：从 DDR 读 96×96 灰度图，跑轻量 CNN，输出手势类别
> - **边界**：DDR 里一块 96×96 `uint8` buffer，两侧各自当黑盒
>
> CNN 放 PS 侧的决策依据见架构文档 §五（不是"PL 做不到"，
> 而是异构划分应沿"数据量 × 操作次数"这条线切）。
>
> ---

## 原 Sobel 工程在哪

这个项目是从 **本仓库 `legacy/sobel/` 下那个已跑通的 Sobel 加速器工程**
复制改造而来的（它一并放在仓库里，方便对照）。改造过程中，Sobel 相关的
源码、BD 与驱动**已全部从主线目录移除** —— 它们唯一的用途是
"已验证、可回滚的参照"，那个参照现在由 `legacy/sobel/` 承担。

| 想看什么 | 去哪 |
|---|---|
| Sobel 加速器的源码/BD/驱动 | `legacy/sobel/` |
| Sobel 的完整文档（含 §9 踩坑） | `legacy/sobel/README.md` |
| Sobel 的 GUI 复现指南 | `legacy/sobel/docs/GUI复现指南.md` |

> ⚠ **本项目的 `src_hls/gesture_preproc.cpp` 大量复用了 Sobel 那版的
> 行缓存骨架**（3 行 BRAM + 3 级列移位寄存器）。改那部分代码时，
> `legacy/sobel/src_hls/sobel_hls.cpp` 是重要的对照参考 ——
> 那是整个仓库里唯一经硬件流程完整验证过的骨架
> （csynth II=1、时序收敛 WNS +1.100 ns）。

---

## 本项目独有的踩坑记录

各模块 README 里都记了各自踩过的坑，这里只列**最值钱的几条**：

| 坑 | 在哪 | 代价 |
|---|---|---|
| **XDC 不支持 `if`** | `vivado/README.md` | 约束整段静默失效，只给 CRITICAL WARNING |
| **AXI 互连的时钟/复位是每端口一个** | `vivado/README.md` | 漏连则互连永远复位，**综合实现比特流全过、上板才炸** |
| **wrapper 有两份副本** | `vivado/README.md` | 综合用旧的那份，报错指向 wrapper 但根因在别处 |
| **HLS 内部 (−1,−2) 偏移在输出索引上抵消** | `src_hls/README.md` | 曾误判致整幅图错位 |
| **`ap_axiu` 不能做内部流负载** | `src_hls/README.md` | csim 通过、csynth 报 214-208 |
| **OV5640 是 16 位子地址、4 字节事务** | `rtl/README.md` | 按 3 字节写则真机上摄像头完全没反应 |
| **`cam_data` 必须与 `cam_href` 同级寄存** | `rtl/README.md` | 行首错一个字节，现象极隐蔽 |
| **状态位在 `CTRL(0x00)` 不在 `0x04`** | `sw/README.md` | 轮询永远等不到，而仿真自己造假值掩盖了它 |

---

## 上板前的最后检查

**⚠ 最重要的一条**：摄像头模块的原理图是**镜像编号**，
引脚映射按镜像解读推导，但**未经实测**。
插错方向会 **3V3/GND 反接烧板**。

**上电前必须用万用表复核**，步骤见：
- `docs/hardware-checklist.md` §3.3
- `vivado/constraints/video_io.xdc` 末尾的「上电前验证」章节

上电后的排查顺序（能快速区分"FPGA 没工作"和"摄像头没配上"）：

```
① io_xclk 有没有 24 MHz      ← FPGA 侧（Clocking Wizard 输出）
② io_scl 有没有在跑           ← SCCB 在工作
③ io_pclk 有没有波形          ← 有 = 配置成功，无 = 配置失败
④ io_href / io_vsync 有没有脉冲
⑤ 最后才查数据线
```

**摄像头配置表**：✅ 2026-09-17 已由占位表换成**真表**
（250 条，正点原子来源，固化 640×480 RGB565）。
⚠ **未上板实测** —— 能否出图要上板才知道。
