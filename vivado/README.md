# vivado 索引

## 本目录只有一个 BD：`bd_video`

视频流水线 + 预处理链，**已跑通到生成比特流**。

| 脚本 | 作用 |
|---|---|
| `bd_video.tcl` | 建 Block Design（VDMA + 预处理链 + SCCB + Clocking Wizard） |
| `create_project.tcl` | **一键建工程**：从零到比特流 + XSA |
| `test_bd_video.tcl` | 只建 BD 并 validate（不综合，约 1 分钟） |
| `test_video_io_xdc.tcl` | 加约束 + 综合（验证 XDC 真的生效） |
| `constraints/video_io.xdc` | 主约束文件 |
| `constraints/video_io_hdmi_tmp.xdc` | ⚠ HDMI 临时豁免（见「HDMI 通路」节） |
| `constraints/hdmi_drc_hook.tcl` | ⚠ write_bitstream 的 pre-hook |

> **原 Sobel 的 `bd_sobel.tcl` 已移到 `legacy/sobel/vivado/`** ——
> 它作为"已验证的参照"与本项目并存，但不再参与本工程的构建。
> 原因见 `docs/架构与接口契约.md` §4.1。

## 构建与验证

从零建工程 → 综合 → 实现 → 比特流 → XSA（**约 20–40 分钟**）：

```bash
vivado -mode batch -source vivado/create_project.tcl
```

只想快速检查 BD 是否合法（约 1 分钟，不综合）：

```bash
vivado -mode batch -source vivado/create_project.tcl -tclargs --synth 0
```

分步验证：

```bash
vivado -mode batch -source vivado/test_bd_video.tcl      # BD + validate
vivado -mode batch -source vivado/test_video_io_xdc.tcl  # 约束 + 综合
```

> ⚠ **不要在 `vivado` 前面加 `bash`** —— 本目录里就有个 `vivado/` 目录，
> `bash vivado` 会让 bash 去执行那个目录，报 `Is a directory`。

所有脚本失败时会立刻 `exit 1` 并打印错误，适合接进 CI。

---

## 约束文件

| 文件 | 内容 | 状态 |
|---|---|---|
| `constraints/video_io.xdc` | **主约束**：PCLK 时钟 + 跨时钟域 + 摄像头引脚 | ✅ 生效（综合后实测确认） |
| `constraints/video_io_hdmi_tmp.xdc` | ⚠ **临时**：HDMI 端口的 DRC 豁免 | ⚠ 方案 B 做完后删 |
| `constraints/hdmi_drc_hook.tcl` | ⚠ write_bitstream 的 pre-hook | ⚠ 同上 |

> 原 Sobel 的 `sobel_io.xdc` 已随它一起移到 `legacy/sobel/vivado/constraints/`。

### video_io.xdc 的分层

| 层 | 内容 | 状态 |
|---|---|---|
| 一 | PCLK 时钟定义（24 MHz） | ✅ 已启用，验证生效 |
| 二 | 跨时钟域声明（PCLK ↔ sysclk 异步） | ✅ 已启用，验证生效 |
| 三 | **摄像头引脚（PMOD-CAMERA v1.0）** | ✅ **已启用**（14 个信号） |
| 四 | HDMI TMDS 引脚 | ⏸ 待 BD 补齐端口（已留模板） |
| 五 | 调试信号 false_path | ✅ 已启用 |

第三层的端口名是 `io_*` 而不是 `cam_*` —— 因为这块摄像头模块
**XCLK 要 FPGA 输出、SDA 是双向**，不能沿用全输入的命名。

### 综合结果（bd_video，无引脚约束）

| 资源 | 用量 | 占比 |
|---|---|---|
| Slice LUTs | 12,829 | 24.11% |
| Slice Registers | 15,807 | 14.86% |
| Block RAM Tile | 25.5 | 18.21% |
| DSPs | 61 | 27.73% |

> 含预处理链（gesture_preproc + 两个 DMA）与 SCCB/Clocking Wizard。
> DSP 偏高来自 `thresh_stage` 的整数除法，优化方式见 `src_hls/README.md`。

---

## ⚠ XDC 的两个硬性限制（本项目实际踩到）

这两条**都不是语法笔误，是对 XDC 语言模型的误解**，且都只给
**CRITICAL WARNING 不给 ERROR** —— 流程照跑、约束静默失效。

### 限制 1：XDC 不支持 Tcl 的 `if` / `for` 等控制流

XDC 是 Tcl 的**受限子集**，只认约束命令。写了控制流会被解析器拒绝：

```
CRITICAL WARNING: [Designutils 20-1307]
  Command 'if' is not supported in the xdc constraint file.
```

**症状**：写了 `if {[llength [get_ports cam_pclk]] > 0} { create_clock ... }`
这种"保护式"写法，结果**整段约束一条都没生效** —— 因为 `if` 被拒后，
块内的命令也不会执行。

**正确做法**：用 `get_* -quiet`。它找不到对象时返回空列表而**不报错**，
约束命令作用在空列表上是安全的 no-op：

```tcl
create_clock -period 41.667 -name cam_pclk [get_ports -quiet cam_pclk]
```

### 限制 2：XDC 的执行早于 `link_design`

此时设计对象还没建立，`get_ports` / `get_clocks` 可能返回空，
依赖设计对象的约束会求值失败：

```
CRITICAL WARNING: [Vivado 12-4739] set_clock_groups:
  No valid object(s) found for '-group [get_clocks ...]'
```

**症状**：约束在综合日志里报 WARNING，看起来"没生效"。

**处理**：
1. Vivado 会对 `used_in implementation` 的文件在**实现阶段重读**一次，
   届时设计已 link，约束正确生效
2. 想减少综合阶段的噪音，用 `-of_objects [get_ports ...]` 形式，
   Vivado 会把它记为"待解析"，link 后自动补齐

**关键：不要只看综合日志的 WARNING 就下结论。**
用 `test_video_io_xdc.tcl` 实际检查——它跑完综合后执行
`get_clocks -quiet cam_pclk` 并读时钟交互报告，确认约束真的生效了。

### 验证用语

| 说法 | 含义 |
|---|---|
| "写完了 XDC" | 文件存在 —— **不代表生效** |
| "综合没报错" | 不代表约束应用了（很多是 CRITICAL WARNING） |
| "`get_clocks` 能查到 cam_pclk" | ✅ 这个才算生效 |

---

## bd_video 的数据通路

### 显示通路：摄像头原图直通，与预处理完全解耦

```
OV5640 ─DVP─► dvp_capture ─AXIS(16bit)─► VDMA S2MM ─► HP1 ─► DDR
                                                                │
                                                      (3 帧缓存)
                                                                │
   HDMI ◄─ TMDS ◄─ v_axi4s_vid_out ◄─AXIS◄─ VDMA MM2S ◄─ HP2 ──┘
                          ▲                     ▲
                       v_tc                  PS 配置(GP0)
```

### CNN 通路：从 DDR 取同一帧，处理成 96×96 灰度写回

```
DDR(640×480 RGB565)          ← 就是显示通路的那个帧缓存
      │
      │  dma_in (MM2S，读 614400 字节)
      ▼
gesture_preproc (HLS) ──► 96×96 uint8
      │
      │  dma_out (S2MM，写 9216 字节)
      ▼
DDR(96×96) ──► PS 侧 CNN 读这里
```

**地址映射**（validate 后自动分配）：
| 从设备 | 地址 |
|---|---|
| `vdma/S_AXI_LITE` | `0x4300_0000` |
| `v_tc/ctrl` | `0x43C0_0000` |
| `gesture_preproc_0/s_axi_control` | 见 Address Editor |
| `dma_in` / `dma_out` | 见 Address Editor |
| HP1/HP2/HP3 DDR | `0x0000_0000` (512M) |

驱动里用这些地址访问，**不要硬编码** —— 从生成的 `.hwh` 里读：

```bash
# .hwh 就在 BD 的 hw_handoff 目录下
vivado/gesture_system/gesture_system.gen/sources_1/bd/bd_video/hw_handoff/bd_video.hwh
```

⚠ `.hwh` 是几十万字节的 XML，**不要直接读进上下文**（会吃掉整个窗口）。
写个脚本提取，或用 PYNQ：`overlay.ip_dict` 直接给出所有 IP 的名字与地址
（`host/gesture_overlay.py` 就是这么做的）。

### ⚠ 为什么预处理从 DDR 取数，而不是从 dvp_capture 分叉

曾考虑用 `axis_broadcaster` 把 `dvp_capture` 的输出一分为二：
一路给 VDMA（显示），一路给 gesture_preproc（CNN）。

**那条路会反压崩溃**：broadcaster 要求所有输出都 ready 才收输入，
而 `gesture_preproc` 是 HLS 的 `ap_ctrl_hs` 模式 ——
**未 `ap_start` 时 `tready=0`**。CNN 不需要 30fps，它大部分时间空闲，
于是 broadcaster 反压 → VDMA 收不到数 → **HDMI 显示也一起卡死**。

从 DDR 分叉则完全解耦：
- 显示通路一字未动，CNN 通路出任何问题都不影响画面
- `gesture_preproc` 按 PS 的节奏跑（10 fps 都够），不必死磕 30fps 时序
- 同一份 DDR 数据在 PC 上也能拿来对拍 Python golden

代价是多一次 DDR 往返（614 KB/帧读），相对三个 HP 口的总带宽很小。

### 触发方式：帧触发 + 轮询

PS 侧流程：
```
检测新帧 → 先武装 dma_out(S2MM) → 再启动 dma_in(MM2S) → ap_start
        → 轮询 ap_done → 置 frame_ready
```

⚠ **顺序不能反**：S2MM 必须先武装，否则预处理输出的第一拍数据没有接收方。

### 资源占用

见上文「综合结果」表（2026-09-15 实测，含预处理链 + SCCB + Clocking Wizard）。

两个时钟域：`clk_fpga_0`（100 MHz）+ `cam_pclk`（24 MHz，来自摄像头）。

> **DSP 占 27.73% 偏高**，来源是 `thresh_stage` 里每像素一次的整数除法
> （`sum / 9216` 被映射成 DSP 乘法器）。若后续资源紧张，
> 可改成"乘 1/9216 的定点倒数再右移"，能省下大部分 DSP。
> 详见 `src_hls/README.md`。

---

## ⚠ 踩过的 15 个坑（都在脚本注释里）

这些坑的共同特点：**错误信息与真正原因不在同一处**，或者**综合能过、上板才炸**。

### 1. `c_s_axis_s2mm_tdata_width` 是只读参数
报 `[BD 41-737] Cannot set the parameter ... It is read-only`。
它由 `c_m_axi_s2mm_data_width` 派生。

### 2. `c_mm2s_fsync` / `c_s2mm_fsync` 不存在
报 `[BD 41-1276] Parameter does not exist`。
⚠ **这类错误只给 CRITICAL WARNING，不报 ERROR** —— 极易被忽略，
然后你会以为参数已经设上了。

### 3. `v_tc` 的 `VIDEO_MODE` 只接受 720p/480p/1080p/Custom
写 `640x480` 报 `[IP_Flow 19-3461] out of the range`。**640×480 对应 "480p"**。

### 4. 实例名与变量名不一致
`create_bd_cell ... -vlnv ...:v_tc v_tc` 的实例名是 **v_tc**（不是变量名 `vtc`）。
连接时写 `vtc/ctrl` 报 `[BD 5-232] No interface pins matched`，
**错误信息里只提到引脚没匹配，不告诉你实例名写错了**。

### 5. `v_axi4s_vid_out` 没有 AXI 接口
它只有 `vid_io_out` / `video_in` / `vtiming_in` 三个接口，**纯流式，无需配置**。
给它接 AXI-Lite 会失败。用 `list_property_value` 或探测脚本确认接口列表，
不要凭 IP 名字猜。

### 6. 视频输出是**接口**不是散引脚
`vid_io_out` 是接口，没有 `vid_data`/`vid_hsync` 这些散引脚。
导出到外部用 `make_bd_intf_pins_external`，**不要手写 VLNV**
（`xilinx.com:interface:vid_io:1.0` 查不到，报 `[BD 41-52]`）。

### 7. AXI 互连的时钟和复位是**每端口一个**
```
漏连 → [BD 41-758] 时钟引脚未连接
漏连 → [BD 41-759] 输入引脚悬空，被 tie-off 到 0
```
**这是最危险的一类**：`S00_ARESETN` 悬空会让互连永远处于复位状态，
AXI 事务一条都过不去 —— 而**综合、实现、生成比特流全部会通过**。

只连 `ACLK`/`ARESETN` 远远不够，必须逐个连
`S00_ACLK` / `M00_ACLK` / `S00_ARESETN` / `M00_ARESETN`。

脚本里已加**逐个断言**，把这类问题消灭在 validate 之前。

### 8. 位宽不匹配只给 WARNING，但数据是错的
VDMA 出 16bit(RGB565)，`v_axi4s_vid_out` 默认 24bit，报：
```
[BD 41-2384] Width mismatch ... Only lower order bits will be connected
```
"能连上"但**颜色整体错位**。实测对应关系（`DATA_WIDTH=8`）：

| `C_S_AXIS_VIDEO_FORMAT` | tdata 位宽 |
|---|---|
| **0** | **16** ← RGB565 用这个 |
| 1 / 2 | 24 |
| 5 / 6 | 32 |

---

### 9. wrapper 有两份副本，综合用的是旧的那份

**症状**：改完 BD（比如端口 `cam_pclk` → `io_pclk`），综合报

```
[Synth 8-11365] named port connection 'cam_pclk' does not exist
[E:/.../sources_1/imports/hdl/bd_video_wrapper.v:52]
```

**报错指向 wrapper，根因却在别处** —— 工程里同时存在两份 wrapper：

| 路径 | 谁生成 |
|---|---|
| `.gen/sources_1/bd/bd_video/hdl/` | 每次 build BD 重新生成（**新**） |
| `.srcs/sources_1/imports/hdl/` | `make_wrapper -import` 时拷贝的（**旧**） |

**综合用 imports 那份。**

**处理**：`make_wrapper -force` **不保证覆盖 imports 里的拷贝**（实测无效）。
必须先手工删干净再重建：

```tcl
foreach w [get_files -quiet *bd_video_wrapper.v] { remove_files $w }
# 磁盘上也删（remove_files 只从工程移除）
file delete -force <imports>/bd_video_wrapper.v
make_wrapper -files [get_files bd_video.bd] -top
add_files -norecurse <gen>/bd_video_wrapper.v
set_property top bd_video_wrapper [current_fileset]
```

`test_video_io_xdc.tcl` 已内置这段逻辑。

### 10. `continue` 在 Vivado 的 Tcl 里会报错

```tcl
foreach f $files {
    if {[exists $f]} { continue }    # ✗ wrong # args: should be "continue"
    ...
}
```

Vivado 的 Tcl 解释器在部分上下文里对 `foreach` 内的 `continue` 报
`wrong # args`。**用嵌套 if 表达同样的"跳过"逻辑**：

```tcl
foreach f $files {
    if {![exists $f]} { ... }        # ✓
}
```

### 11. "文件加入列表"的守卫条件不能只看一个文件

```tcl
# ✗ 错误：一旦 dvp_capture.v 已存在，新增的 iobuf_wrap.v 永远加不进来
if {dvp_capture.v 不在工程} { add_files 所有文件 }

# ✓ 正确：逐个文件判断
foreach f $files {
    if {[llength [get_files -quiet "*/$f"]] == 0} { add_files ... }
}
```

症状是 `[BD 41-1690] Unable to resolve module-source: ov5640_regs`
—— 模块源找不到，但文件明明在磁盘上。

### 12. AXI 互连的主口数必须与实际占用一致

`ic_ctrl` 配 `NUM_MI=5`，但如果预处理链因缺 `IP_REPO` 被跳过，
M02/M03/M04 就**悬空**。`bd_video.tcl` 末尾的 AXI 接口检查会
直接 error 退出（**这是对的** —— 悬空 AXI 口综合能过、上板才炸）。

**跑任何 BD 脚本前先确认 `IP_REPO` 指向 HLS 导出目录**，
否则整个预处理链会被静默跳过。

---

### 13. `.gitignore` 的目录级忽略会让 `!` 放行失效

**症状**：想让 BD 的源（`.bd`/`.bda`/`ip/*.xci`）进版本控制，
写了目录级忽略再用 `!` 放行 —— **放行不生效**，BD 源还是被忽略。

**根因**（git 的硬规则）：

> **父目录一旦被忽略，就无法用 `!` 放行其中的任何文件。**

所以这种写法一定失败：

```gitignore
vivado/gesture_system/              # ✗ 忽略整个工程目录
!vivado/gesture_system/**/bd_video/ # ✗ 放行无效
```

**定位方法**（别猜，用这个）：

```bash
git check-ignore -v <路径>
```

它会告诉你**具体是哪一行规则**匹配的。本项目的实例：

```
.gitignore:15:vivado/gesture_system/    ← 指回目录级那条
```

**正确做法**：不忽略根目录，**逐条忽略可再生的子项**：

```gitignore
vivado/**/*.gen/
vivado/**/*.runs/
vivado/**/*.cache/
# ... 而不是 vivado/gesture_system/
```

> ⚠ 另一条相关陷阱：`vivado/*.gen/` 这种**单层** `*` 匹配不到
> `vivado/gesture_system/gesture_system.gen/`（两层）。必须用 `**`。
> 两者都会**静默失效** —— 写完规则以为忽略了，实际一个都没匹配上。
> **验规则要用 `git check-ignore` 实测，不要靠看。**

### 14. 约束里的对象名**不要靠猜** —— 报错在告诉你"找不到"

`video_io.xdc` 里曾有两处因为**对象名写错**而报错，都是抄来的：

| 约束 | 写的名字 | 实际是 | 报错 |
|---|---|---|---|
| `set_clock_groups` | `*processing_system7_0*FCLK_CLK0` | PS7 实例名 **`ps7`**，时钟 **`clk_fpga_0`** | `[12-5201]` + `[12-4739]` |
| `set_false_path` | `get_ports DDR_*` | 本 BD 的 PS7 **没把 DDR 引到顶层** | `[12-4739]` |

**这两条报错都是"报得对"的**：

```
[Vivado 12-5201] cannot set the clock group when only one non-empty
                 group remains
[Vivado 12-4739] No valid object(s) found for '-from [get_ports DDR_*]'
```

它们在说"你的约束里有个对象是空的"。**遇到别去改约束的写法，
要去查那个对象到底叫什么 / 存不存在。**

**查实方法**（综合后执行，别猜）：

```tcl
open_run synth_1
get_clocks      # 所有时钟名
get_ports       # 所有顶层端口名
get_cells -hier -filter {NAME =~ "*关键字*"}   # 层次单元名
```

本项目实测的时钟名：`clk_fpga_0` / `cam_pclk` /
`clk_out1_bd_video_clk_wiz_xclk_0` / `clkfbout_...`。

> ⚠ `DDR_*` 那条尤其值得注意：**它在原 Sobel 工程里同样是无效的**。
> 抄约束时不会连带抄来"这条在当前设计里成不成立"，
> 所以抄来的约束**必须逐条验证**。

### 15. `[Netlist 29-160]` 来自 Vivado 自动生成的 PS7 约束，可忽略

综合日志里会刷 **101 条**：

```
CRITICAL WARNING: [Netlist 29-160] Cannot set property 'iostandard',
  because the property does not exist for objects of type 'pin'.
  [.../bd_video_ps7_0_5/bd_video_ps7_0.xdc:29]
```

**来源**：`bd_video_ps7_0.xdc` —— **Vivado 为 PS7 自动生成的**约束，
在约束 DDR_VRP / DDR_VRN 等 PS 引脚。

**为什么报**：这些引脚在**综合阶段还不存在**（PS 的 IO 由硬核管理，
不出现在 PL 的 netlist 里）。实现阶段会正常应用。

**结论**：不是本项目的问题，**忽略**。
判据是看 `[文件路径]` —— 指向 `gesture_system.gen/.../ip/` 下的
都是 Vivado 自动生成的，指向 `vivado/constraints/` 才是我们的。

---

## HDMI 通路（方案 B，未做）

### 现状：卡在哪

```
vdma/M_AXIS_MM2S → v_axi4s_vid_out → vid_io_out（并行视频）→ ✗ 断了
                         ▲
                    v_tc/vtiming_out
```

BD 导出的 22 个 `hdmi_vid_out_*` 是**并行视频**，而 HDMI 物理接口要
**TMDS 差分对**，两者数量对不上。缺两样：

| 缺什么 | 为什么必须 |
|---|---|
| **像素时钟** | `vid_io_out` 是**接口，不携带时钟**。TMDS 需要独立的时钟对 `hdmi_tx_clk_p/n` |
| **TMDS 编码器** | 并行 RGB + 同步信号 → 3 对差分串行（**8b/10b 编码**） |

### 临时措施（方案 A，已实施）

为了让比特流能生成：

| 文件 | 作用 |
|---|---|
| `constraints/video_io_hdmi_tmp.xdc` | 把 `NSTD-1` / `UCIO-1` 两条 DRC 降级 |
| `constraints/hdmi_drc_hook.tcl` | write_bitstream 的 **pre-hook**（关键） |

⚠ **为什么必须用 pre-hook**：在工程里直接 `set_property SEVERITY`
**无效** —— run 是独立进程。Vivado 的报错信息里明确说了要用 pre-hook。

⚠ **代价**：22 个 HDMI 端口在比特流里**悬空**，**上板时不要接 HDMI 线**。
CNN 通路与 HDMI 完全解耦，不受影响。

### 方案 B 的完整计划

| 步 | 产出 | 能否离线验证 |
|---|---|---|
| 1 | `rtl/tmds_encoder.v`（**纯 8b/10b 算法，不含原语**） | ✅ **iverilog 可测** |
| 2 | `rtl/hdmi_tx.v`（例化 OSERDESE2 + OBUFDS） | ❌ 只能 Vivado 综合验证 |
| 3 | MMCM 产生 **25.175 MHz** 像素时钟 | ✅ 综合后看频率 |
| 4 | BD 集成 + 引脚约束（模板已在 `video_io.xdc` 第四层） | ✅ validate + 实现 |
| 5 | 出比特流 | ✅ DRC 通过 |

**关键设计**：第 1 步把 8b/10b 算法**单独抽出来**，它不依赖任何
Xilinx 原语，**可以用 iverilog 喂已知像素、比对标准编码表**。
这样核心逻辑可信，剩下的只是原语接线。

**工作量**：① 30分 ② **2–4 小时（主要风险）** ③ 15分 ④ 15分 ⑤ 30分

⚠ **最大问题**：第 2 步用的 `OSERDESE2` / `OBUFDS` **全是 Xilinx 原语**，
iverilog 不认（与 `iobuf_wrap.v` 同样的问题）。**真正的验证只能等板子**，
而 HDMI 出问题的症状（花屏/黑屏/不识别）在"编码错/时序错/接线错"
之间很难区分。

> **建议**：板子到货、主线（摄像头→预处理→DDR）验证通之后再动 B。
> 那时可以边调边看，而不是盲写。

### 顺带要修的已有缺陷

`bd_video.tcl` 里 `H_ACTIVE` / `H_FRONT` / `V_ACTIVE` 等常量
**只在一个 `puts` 里用过，没写进任何 IP**。`v_tc` 只设了
`CONFIG.VIDEO_MODE {480p}`。做 B 时要一并补上显式时序参数：

```tcl
set_property -dict [list \
    CONFIG.H_ACTIVE {640} CONFIG.H_FRONT {16} \
    CONFIG.H_SYNC {96}    CONFIG.H_BACK  {48} \
    CONFIG.V_ACTIVE {480} CONFIG.V_FRONT {10} \
    CONFIG.V_SYNC {2}     CONFIG.V_BACK  {33} \
] $vtc
```

---

## 未做的部分（故意分步）

| 项 | 为什么不现在做 |
|---|---|
| **HDMI 的 TMDS 编码** | 见上节「HDMI 通路（方案 B）」。已用临时措施让比特流能生成 |
| **dvp_capture 的 AXI-Lite 控制口** | 当前 RTL 无寄存器接口，PS 读不到 `frame_cnt`/`stalled`。调试时用 ILA 看即可，需要时再加 |
| **`rtl/ov5640_regs.v` 的真实寄存器表** | 目前是**占位表**，不足以让摄像头出图。**这是上板前唯一的软件阻塞项** |

## 已完成的验证

| 项 | 状态 |
|---|---|
| BD 构建 + `validate_bd_design` | ✅ 无 CRITICAL WARNING |
| 时钟/复位/AXI 接口断言 | ✅ 全部通过 |
| **综合** | ✅ 通过 |
| **实现（place & route）** | ✅ **完成** |
| **时序收敛** | ✅ **WNS +0.873 ns**，TNS 0，0 个失败端点 |
| **DRC** | ✅ 仅 Advisory（VDMA 内部 FIFO），无实质违规 |
| **比特流** | ✅ **已生成**（4.0 MB，用 HDMI 临时豁免） |
| **XSA** | ✅ 已导出（755 KB） |
| 功耗 | ✅ 2.009 W，结温 48.2°C |
| `video_io.xdc` 生效 | ✅ `cam_pclk` 与异步时钟组已确认 |
| 板级实测 | ❌ 未做（板子未到） |

### 最终资源占用（实现后实测）

| 资源 | 用量 | 占比 |
|---|---|---|
| Slice LUTs | 11,177 | 21.01% |
| Slice Registers | 14,810 | 13.92% |
| Block RAM Tile | 25.5 | 18.21% |
| DSPs | 61 | 27.73% |
| Bonded IOB | 35 | 28.00% |

### 时序余量

```
cam_pclk    WNS +35.020 ns   ← 24 MHz，余量巨大
clk_fpga_0  WNS  +0.873 ns   ← 100 MHz，这是关键路径
```

### 产物位置

```
vivado/gesture_system/gesture_system.xsa                          ← 755 KB
vivado/gesture_system/gesture_system.runs/impl_1/bd_video_wrapper.bit  ← 4.0 MB
```

