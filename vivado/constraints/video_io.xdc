# =====================================================================
#  video_io.xdc —— 视频接口约束（bd_video 用）
#
#  与 sobel_io.xdc 的关系：那个是原 Sobel 工程的约束，保持不动。
#  本文件是新的视频流水线的补充约束。
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠⚠ 这个文件里**不能写 Tcl 的 if 语句**
#  ─────────────────────────────────────────────────────────────────
#  XDC 是 Tcl 的**受限子集** —— 只支持约束命令，不支持控制流。
#  写了 if 会被解析器直接拒绝：
#
#      CRITICAL WARNING: [Designutils 20-1307]
#        Command 'if' is not supported in the xdc constraint file.
#
#  而且它是 **CRITICAL WARNING 不是 ERROR**，流程照样往下跑，
#  约束却整段静默失效 —— 最难查的一类问题。
#  （早期版本用 if 做"端口不存在就跳过"的保护，结果所有约束都没生效，
#    综合日志里只有一行 CRITICAL WARNING，不看日志根本发现不了。）
#
#  XDC 支持的条件写法是 **`current_instance` + `get_* -quiet`**：
#     - `get_* -quiet` 找不到对象时返回空列表而**不报错**
#     - 把约束命令直接串在空列表上，Vivado 会安全地跳过
#  所以本文件统一用这种写法，不用 if。
#
#  ⚠ 另一个坑：XDC 的执行**早于** `link_design`。
#    此时端口/单元还没建立，`get_ports` 返回空，约束会被跳过。
#    所以引脚类约束（set_property PACKAGE_PIN）必须放在
#    `## 综合后生效` 标记之后，或者靠 Vivado 在实现阶段重新读。
#    详见本文件末尾的说明。
# =====================================================================


# =====================================================================
#  第一层：PCLK 时钟（已启用）
# =====================================================================

# ---------------------------------------------------------------------
#  摄像头 PCLK
#
#  OV5640 在 VGA(640x480) RGB565@30 下的 PCLK 标称 24 MHz，
#  周期 = 1000 / 24 = 41.667 ns。
#
#  ⚠ 这个频率必须与 BD 里 cam_pclk 端口的 CONFIG.FREQ_HZ 一致。
#    两处不一致时 Vivado 只给 WARNING，但时序分析结果就是错的。
#    BD 侧已设 24000000 Hz，见 vivado/bd_video.tcl §10。
#
#  ⚠ XDC 执行早于 link_design，此时 get_ports 可能返回空。
#    与 set_clock_groups 同理，这类"依赖设计对象"的命令在综合
#    阶段可能求值失败 —— Vivado 会在实现阶段重读
#    （该文件是 used_in implementation）。
#    最终是否生效以 get_clocks 的结果为准（见文件末尾验证方法）。
# ---------------------------------------------------------------------
create_clock -period 41.667 -name cam_pclk [get_ports io_pclk]

# 时钟不确定性：OV5640 的 PCLK 由内部 PLL 产生，抖动比板载晶振大。
# 0.5 ns 是保守估计 —— 24 MHz 周期 41.7 ns，这点余量微不足道，
# 但能避免把 PLL 抖动当成路径延迟问题来查。
set_clock_uncertainty -setup 0.5 [get_clocks cam_pclk]


# =====================================================================
#  第二层：跨时钟域声明（已启用 —— 本设计最关键的一条）
# =====================================================================

# ---------------------------------------------------------------------
#  ⚠⚠ PCLK 域与系统时钟域必须声明为异步
#
#  PCLK 来自 OV5640（24 MHz），clk_fpga_0 来自 PS（100 MHz），
#  两者**完全独立、相位无关**。它们之间的通路只有一条：
#      dvp_capture 内部的 async_fifo（格雷码指针跨域）
#
#  不声明为异步组的话，Vivado 会去分析"PCLK 域 → sysclk 域"的
#  路径 —— 那条路径的建立/保持**物理上不可能满足**，
#  于是报出一堆无法修复的违例，把真正的问题淹没掉。
#
#  声明之后跨域路径不再被分析。
#  ⚠ 前提是跨域逻辑本身正确（异步 FIFO / 两级同步器）——
#    这个约束只是让工具不报假违例，**不会让错误的跨域设计变正确**。
#    跨域实现见 rtl/async_fifo.v 与 rtl/README.md。
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠ 为什么用 -of_objects [get_clocks] 而不是直接写时钟名
#  ─────────────────────────────────────────────────────────────────
#  XDC 的执行**早于 link_design**，此时设计对象还没建立。
#
#  如果写成 `-group [get_clocks -quiet cam_pclk]`：
#    综合阶段 cam_pclk 还没创建（它是本文件前面 create_clock 建的，
#    但设计未 link，get_clocks 可能返回空），
#    于是报 [Vivado 12-4739] No valid object(s) found for '-group ...'
#
#  写成 `-group [get_clocks -of_objects [get_ports cam_pclk]]`：
#    括号内的表达式同样在设计 link 后才求值，
#    但 Vivado 会把它记为"待解析"，link 后自动补齐 ——
#    这才是官方推荐的写法。
#
#  ⚠ 无论哪种写法，综合阶段的 CRITICAL WARNING 都可能出现，
#    因为综合读 XDC 时设计还没 link。**关键看实现阶段**：
#    Vivado 会对 used_in_implementation 的文件重读一次。
#    验证方式见文件末尾。
# ---------------------------------------------------------------------
# ⚠⚠ 时钟名不要靠猜 —— 这里是本项目实际踩过的一个坑
#
#  原来 filter 写的是 `*processing_system7_0*FCLK_CLK0`，但：
#    * **BD 里 PS7 的实例名是 `ps7`**，不是 `processing_system7_0`
#    * 它输出的系统时钟综合后叫 **`clk_fpga_0`**
#  过滤器一个都匹配不到 → 那个 group 为空 → 报：
#      [Vivado 12-5201] cannot set the clock group when only one
#                       non-empty group remains
#      [Vivado 12-4739] No valid object(s) found for '-group ...'
#
#  ⚠ 这两条报错是**报得对**的 —— 它在告诉你"两组约束里有一组是空的"。
#    遇到别去改 set_clock_groups 的写法，要去查真实时钟名。
#
#  查实方法（综合后执行）：
#      open_run synth_1
#      get_clocks        # 列出所有时钟名（本项目实测：clk_fpga_0 / cam_pclk / ...）
#      get_ports         # 列出所有顶层端口名
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_ports io_pclk]] \
    -group [get_clocks -of_objects [get_pins -quiet -hier \
        -filter {NAME =~ "*ps7*FCLK_CLK0"}]]

# 主系统时钟的周期由 BD 自动约束（FCLK_CLK0 = 100 MHz，周期 10 ns），
# 这里不重复 create_clock，避免与 BD 生成的约束冲突。
# 若需要显式确认，跑起来后用 `get_clocks` 查看即可。


# =====================================================================
#  第三层：摄像头引脚（PMOD-CAMERA v1.0）
#
#  硬件：**MUSE LAB PMOD-CAMERA v1.0**（TMALL 购入），公头，
#        与 PYNQ-Z2 的 Pmod 母座**直插**，无需转接板、无需焊接。
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠⚠ 端口命名用 io_* 而不是 cam_*
#  ─────────────────────────────────────────────────────────────────
#  这块模块与"纯输入摄像头"不同：**XCLK 要由 FPGA 输出**，
#  **SDA 是双向**。所以不能沿用 cam_* 那套全输入的命名。
#
#  ⚠ 这意味着 BD 里的 dvp_capture 例化必须相应接线：
#      io_xclk → Clocking Wizard 出来的 24MHz（FPGA 输出）
#      io_sda  → sccb_master 的 sda_o（经 IOBUF，见下）
#      io_scl  → sccb_master 的 scl
#    其余 io_d[*] / io_pclk / io_href / io_vsync → dvp_capture
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠⚠ 引脚编号：原理图是"镜像编号"，不是 Pmod 规范编号
#  ─────────────────────────────────────────────────────────────────
#  原理图 J2/J3 的编号画法是：左列 12→7 自上而下，右列 1→6 自上而下。
#  这**不是**标准 Pmod 的编号方式，两种解读的物理对应完全不同：
#
#      直编号：物理第 5 列 = GND + DVP_HREF   ← HREF 会被短到 GND
#      镜像  ：物理第 5 列 = GND + GND         ← 电源脚对齐 ✓
#
#  **本文件按"镜像"编号**，理由是一致性：只有镜像解读能让
#  两个连接器的 GND/GND、3V3/3V3 都落在**同一物理列**上，
#  与 PYNQ-Z2 Pmod 口的电源脚位置吻合。
#  模块作者既然做了 Pmod 接口，不会把电源脚放错位。
#
#  ⚠ 但这是**一致性论证，不是实测**。
#    上板前**必须用万用表复核**，步骤见本文件末尾「上电前验证」。
#    插错方向的后果：3V3 与 GND 反接（烧板）或 HREF 被短到 GND。
#
#  ─────────────────────────────────────────────────────────────────
#  信号 → 物理位 → PYNQ 端口 对照（含中间推导）
#  ─────────────────────────────────────────────────────────────────
#  原理图 J2（右列自上而下 1..6，左列自上而下 12..7）：
#       pin 1  XMCLK        pin 7  (3V3)    → 物理 列1上 / 列1下
#       pin 2  DVP_VSYNC    pin 8  (GND)
#       pin 3  I2C_SDA      pin 9  I2C_SCL
#       pin 4  NC           pin 10 DVP_HREF
#       pin 5  (GND)        pin 11 DVP_PCLK
#       pin 6  (3V3)        pin 12 NC
#
#  Pmod 规范：奇数脚 = 上行，偶数脚 = 下行，每列一对
#       ja[0]=列1上  ja[1]=列2上  ja[2]=列3上  ja[3]=列4上
#       ja[4]=列1下  ja[5]=列2下  ja[6]=列3下  ja[7]=列4下
#
#  ─────────────────────────────────────────────────────────────────

# XCLK：⚠ 这是 **output**（FPGA 产生 24MHz 给摄像头）
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports io_xclk]

# VSYNC / SDA / HREF / SCL 都是双向或输入
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports io_vsync]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports io_sda]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports io_href]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports io_scl]

# PCLK：⚠ 在 Pmod A 上（不是 Pmod B）
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports io_pclk]

# ---- J3 → Pmod B（数据线，注意是交错的）----
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports { io_d[6] }]
set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports { io_d[4] }]
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { io_d[2] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { io_d[0] }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { io_d[7] }]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports { io_d[5] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { io_d[3] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { io_d[1] }]

# ---- 输入延时：DVP 是源同步接口 ----
# 数据由摄像头在 PCLK 边沿输出，用 set_input_delay 而不是普通建立/保持。
# 1.5 ns 保守（24 MHz 周期 41.7 ns，余量充足）。
set_input_delay -clock cam_pclk -max 1.5 \
    [get_ports { io_d[*] io_href io_vsync }]
set_input_delay -clock cam_pclk -min 0.5 \
    [get_ports { io_d[*] io_href io_vsync }]

# ---- XCLK 输出（FPGA → 摄像头）----
#
# ⚠ XCLK 不需要 set_output_delay。
#
#  原因是它**不是数据线**，而是摄像头的**主时钟输入**。
#  set_output_delay 描述的是"数据相对时钟的相位关系"，
#  而 XCLK 本身就是那个"时钟"。给时钟输出加输出延时是概念错误。
#
#  XCLK 的时序由 **Clocking Wizard 的输出相移**决定：
#  摄像头在 XCLK 驱动下产生 PCLK，两者有内部延迟。
#  通常把 XCLK 做 0° 相移即可；若实测 PCLK 采样窗口不佳，
#  再调 Clocking Wizard 的 output phase（见 bd_video.tcl 里 CW 的配置）。
#
#  ⚠ 约束层面这里只需要确认 XCLK 是 output 且已连到 CW 的输出。

# ---- SCCB 双向总线 ----
# SDA 是开漏双向线：FPGA 通过 IOBUF 驱动/释放，外部上拉决定空闲电平。
# ⚠ 必须加 PULLUP —— 模块上通常已有 4.7k，但多一个内部上拉无害；
#   若模块缺上拉，这里能兜底（内部上拉较弱，长走线可能不够）。
set_property PULLUP true [get_ports io_sda]
set_property PULLUP true [get_ports io_scl]

# SCL 由 FPGA 驱动（推挽足够，模块端也是开漏但 FPGA 主动驱动没问题）
# 说明：sccb_master 的 scl 是推挽输出，不像标准 I2C 那样开漏。
# 对 OV5640 这类只做从机的器件，推挽 SCL 是可行的（很多 FPGA 方案都这样）。



# =====================================================================
#  第四层：HDMI 输出引脚
#
#  ⚠ 待 BD 补齐端口 —— 当前引脚数量对不上，光写 XDC 解决不了。
#
#  ─────────────────────────────────────────────────────────────────
#  为什么现在不能启用
#  ─────────────────────────────────────────────────────────────────
#  当前 bd_video 导出的 HDMI 端口是**并行视频信号**：
#
#      hdmi_vid_out_data          (O, 16bit)  ← 并行像素数据
#      hdmi_vid_out_hsync         (O)
#      hdmi_vid_out_vsync         (O)
#      hdmi_vid_out_active_video  (O)         ← 即 DE
#      hdmi_vid_out_field / hblank / vblank
#
#  但 HDMI 物理接口要的是 **TMDS 差分对**，含一个**独立的时钟对**：
#
#      hdmi_tx_clk_p / hdmi_tx_clk_n     ← 像素时钟的 TMDS 对
#      hdmi_tx_d_p[0..2] / _n[0..2]      ← 三个数据通道
#
#  问题：**BD 里没有像素时钟输出**（v_axi4s_vid_out 的
#  C_HAS_ASYNC_CLK=0，vid_io_out 不携带时钟）。
#  所以引脚数量对不上，必须先改 BD。
#
#  ─────────────────────────────────────────────────────────────────
#  补齐需要做的两件事（BD 改动，不在本次范围）
#  ─────────────────────────────────────────────────────────────────
#  1. 产生像素时钟：从 clk_fpga_0 经 MMCM 分频得 25.175 MHz
#     （480p@60 的像素时钟）或 27 MHz（720p@60），引出为外部端口
#  2. 加 TMDS 编码器：把并行 RGB + 同步信号编码成 3 对 TMDS
#     （8b/10b + OSERDESE2 串行化）
#
#  PYNQ-Z2 的 HDMI **直连 PL 的 TMDS 引脚**，板上无 ADV7511 之类
#  的编码芯片 —— 这正是它支持 HDMI 输入的原因，也意味着 TMDS
#  编码必须自己在 PL 里做。
#
#  ─────────────────────────────────────────────────────────────────
#  引脚表（取自 TUL 原厂 PYNQ-Z2_v1.0_master.xdc，非推测）
#  ─────────────────────────────────────────────────────────────────
#
#  信号              引脚   IOSTANDARD
#  hdmi_tx_clk_p     L16    TMDS_33
#  hdmi_tx_clk_n     L17    TMDS_33
#  hdmi_tx_d_p[0]    K17    TMDS_33
#  hdmi_tx_d_n[0]    K18    TMDS_33
#  hdmi_tx_d_p[1]    K19    TMDS_33
#  hdmi_tx_d_n[1]    J19    TMDS_33
#  hdmi_tx_d_p[2]    J18    TMDS_33
#  hdmi_tx_d_n[2]    H18    TMDS_33
#  hdmi_tx_hpdn      R19    LVCMOS33
#  hdmi_tx_cec       G15    LVCMOS33
#
#  ⚠ D 通道的 p/n 引脚号**不是连续配对的**
#    （d_p[1]=K19 而 d_n[1]=J19，跨了引脚号）。
#    这是原厂 XDC 的原始数据，抄写时别"顺手排序"。
#
#  ─────────────────────────────────────────────────────────────────
#  模板（端口补齐后取消注释）
#  ─────────────────────────────────────────────────────────────────
#
# set_property -dict { PACKAGE_PIN L16 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_clk_p]
# set_property -dict { PACKAGE_PIN L17 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_clk_n]
# set_property -dict { PACKAGE_PIN K17 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[0] }]
# set_property -dict { PACKAGE_PIN K18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[0] }]
# set_property -dict { PACKAGE_PIN K19 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[1] }]
# set_property -dict { PACKAGE_PIN J19 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[1] }]
# set_property -dict { PACKAGE_PIN J18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[2] }]
# set_property -dict { PACKAGE_PIN H18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[2] }]
# set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports hdmi_tx_hpdn]


# =====================================================================
#  第五层：调试信号与通用约束（已启用）
# =====================================================================

# ---------------------------------------------------------------------
#  摄像头统计寄存器
#
#  dvp_capture 的 frame_cnt / line_cnt 是**状态指示**（给人看的），
#  不是数据通路 —— 读到的值晚几拍不影响功能。
#
#  ⚠ 层次路径严格 = 顶层实例名/BD 实例名/模块实例名
#      bd_video_i / dvp_capture_0 / inst
#    这三个名字任何一个变了（改 BD 实例名、改 wrapper 名）这条约束都会
#    静默失效。改 BD 后请确认路径仍然正确。
# ---------------------------------------------------------------------
set_false_path -from [get_cells -quiet -hier \
    -filter {NAME =~ "*dvp_capture_0/inst/frame_cnt_reg*"}]
set_false_path -from [get_cells -quiet -hier \
    -filter {NAME =~ "*dvp_capture_0/inst/line_cnt_reg*"}]

# ---------------------------------------------------------------------
#  PS 侧固定信号
#
#  ⚠ 这里**不要**写 `set_false_path -from [get_ports DDR_*]`。
#
#  那是从原 Sobel 工程的约束抄来的，但在这版 BD 里**无效** ——
#  本 BD 的 PS7 **没有把 DDR / FIXED_IO 引到顶层**（BD 里没勾
#  "Make External"），所以：
#      get_ports DDR_*         → 空列表
#      set_false_path -from 空 → 报 [Vivado 12-4739] No valid object(s)
#
#  ⚠ 而且**原工程里同样是无效的** —— 抄过来只是把问题一起搬过来。
#
#  这些端口本来就不需要 false_path：PS 的 DDR/FIXED_IO 由 PS7 硬核
#  自己管理，不参与 PL 的时序分析。不写这条约束是对的。
#
#  如果以后确实把 DDR 引到顶层（比如自己接 DDR 芯片），再按实际
#  端口名补约束。**先跑 get_ports 确认端口存在，再写约束。**
# ---------------------------------------------------------------------
# （此处原本有两条 set_false_path，已删除 —— 见上面的说明）


# =====================================================================
#  附录：XDC 写法的三条硬性限制（都是本项目实际踩到的）
#
#  1. **不能用 if / for 等控制流**
#     报 [Designutils 20-1307]，且只是 CRITICAL WARNING —— 流程照跑、
#     约束静默失效。想要"条件生效"就用 `get_* -quiet`：
#     空列表上的约束命令是安全的 no-op。
#
#  2. **不能用 puts 之类的一般 Tcl 命令**
#     同样限制在约束命令子集内。
#
#  3. **XDC 的执行时机早于 link_design**
#     `get_ports` 在此时可能返回空，依赖端口的约束会被跳过。
#     Vivado 会在实现阶段对 `used_in implementation` 的文件重新读取，
#     所以最终能生效 —— 但**不要依赖这一点**，
#     涉及端口的约束要确认它真的出现了（看综合/实现日志的
#     "Parsing XDC File" 段落，以及最终 get_clocks / get_property 结果）。
#
#  本次验证方式：
#      vivado -mode batch -source vivado/test_video_io_xdc.tcl
#    它会综合一遍并检查 cam_pclk 与异步时钟组是否真的生效。
# =====================================================================


# =====================================================================
#  上电前验证（⚠ 必做 —— 插错方向会烧板）
#
#  本文件按"镜像编号"推导引脚（见第三层说明），但那是**一致性论证，
#  不是实测**。插上去之前必须用万用表确认。
#
#  ─────────────────────────────────────────────────────────────────
#  步骤（三分钟，通断档）
#  ─────────────────────────────────────────────────────────────────
#
#  ① 量模块：找出 J2 上哪两个物理针是 3V3 与 GND
#     - 3V3：点模块上某个电解电容的正极或 LDO 输出脚，扫 J2 的针
#     - GND：点任意螺丝孔或 GND 铺铜，扫 J2 的针
#
#  ② 量 PYNQ-Z2：找出 Pmod A 上哪两个物理针是 3V3 与 GND
#     - GND 可点 Micro-USB 外壳
#     - 3V3 可点板上其他 3V3 点（如 Arduino 座的 3V3）
#
#  ③ 对比：两边的 3V3 与 GND 必须落在**相同的物理列**
#     ✓ 对上 → 可以插
#     ✗ 对不上 → **不要插**，本文件的镜像假设不成立，需要重做映射
#
#  ④ 最后：量模块 3V3 与 GND 之间**不短路**
#     （应为几 kΩ 以上，不是 0 Ω —— 0 Ω 说明模块本身有问题）
#
#  ─────────────────────────────────────────────────────────────────
#  验证通过后的接线自检（上电后，用 ILA 或 LED）
#  ─────────────────────────────────────────────────────────────────
#
#  1. io_xclk 应有 24 MHz 输出 —— 示波器或 ILA 探一下
#  2. io_scl 在 sccb_master 跑起来后应有 100 kHz 方波
#  3. io_pclk 在摄像头配置成功后应有 24 MHz（**配置前不会有**）
#  4. io_href / io_vsync 应有周期性脉冲
#
#  ⚠ 第 3 条是最重要的判据：
#    如果 io_scl 有波形但 io_pclk 一直没有，说明 **SCCB 没配上** ——
#    去查 sccb_master 的 cfg_error，以及 OV5640 的寄存器表内容。
# =====================================================================
