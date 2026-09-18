# =====================================================================
#  bd_video.tcl —— 手势识别系统的视频流水线 Block Design
#
#  用法（在 Vivado 里 source 本脚本）：
#      vivado -mode batch -source vivado/bd_video.tcl
#   或在已有工程里：
#      source vivado/bd_video.tcl
#
#  ─────────────────────────────────────────────────────────────────
#  这是本工程**唯一**的 Block Design
#  ─────────────────────────────────────────────────────────────────
#  原 Sobel 的 bd_sobel.tcl 已从本项目移除 —— 它的角色是
#  "已验证、可回滚的参照"，那个参照现在由完整的 **legacy/sobel** 承担。
#  本项目只保留手势识别这一条通路，减少维护面。
#
#  ─────────────────────────────────────────────────────────────────
#  数据通路
#  ─────────────────────────────────────────────────────────────────
#
#  【显示通路】摄像头原图直通，与预处理完全解耦
#
#   OV5640 ──DVP──► dvp_capture ──AXIS(16bit)──► VDMA S2MM ──► HP1 ──► DDR
#                                                                        │
#                                                              (帧缓存, 3 帧)
#                                                                        │
#      HDMI ◄── TMDS ◄── v_axi4s_vid_out ◄── AXIS ◄── VDMA MM2S ◄── HP2 ─┘
#                              ▲                        ▲
#                           v_tc/vtg                PS 配置 (GP0)
#
#  【CNN 通路】从 DDR 取同一帧，处理成 96x96 灰度写回 DDR
#
#      DDR(640x480 RGB565) ◄──── 就是上面那个帧缓存
#            │
#            │  dma_in (MM2S，读 614400 字节)
#            ▼
#      gesture_preproc (HLS) ──► 96x96 uint8
#            │
#            │  dma_out (S2MM，写 9216 字节)
#            ▼
#      DDR(96x96) ──► PS 侧 CNN 读这里
#
#  ─────────────────────────────────────────────────────────────────
#  HP 端口分配（这是本 BD 最重要的决定）
#  ─────────────────────────────────────────────────────────────────
#   HP0 —— 未用（原 Sobel 通路占用的，Sobel 已移除，此口空置）
#   HP1 —— VDMA S2MM：摄像头帧写入 DDR
#   HP2 —— VDMA MM2S：从 DDR 读帧送 HDMI
#   HP3 —— 预处理链的两个 DMA（读原图 + 写 96x96）
#
#  ⚠ 为什么 MM2S 和 S2MM 要分开占两个 HP 口：
#     摄像头持续写入约 18 MB/s (640x480@30 RGB565)，HDMI 读出同样量级。
#     挤在同一个 HP 口上会互相争抢，也便于用 ILA 单独观察。
#     HP3 的流量小得多（10 fps 时约 6 MB/s），单独一口足够。
#
#  ─────────────────────────────────────────────────────────────────
#  资源占用（2026-09-15 实测，含预处理链）
#  ─────────────────────────────────────────────────────────────────
#     Slice LUTs      12,735   23.94%
#     Slice Registers 15,736   14.79%
#     Block RAM        25.5    18.21%
#     DSPs               61    27.73%
#   两个时钟：clk_fpga_0 (10 ns) + cam_pclk (41.667 ns)
# =====================================================================

# ---------------------------------------------------------------------
#  参数
# ---------------------------------------------------------------------
if {![info exists BD_NAME]}   { set BD_NAME   "bd_video" }
if {![info exists PART_NAME]} { set PART_NAME "xc7z020clg400-1" }
if {![info exists IP_REPO]}   { set IP_REPO   "" }

# 视频时序：640x480@30（与 dvp_capture 的采集分辨率一致，先做直通）
set H_ACTIVE  640
set H_FRONT   16
set H_SYNC    96
set H_BACK    48
set V_ACTIVE  480
set V_FRONT   10
set V_SYNC    2
set V_BACK    33

# VDMA 帧缓存：3 帧（写/处理/读各一，避免撕裂）
# 16bit RGB565 -> 每像素 2 字节，stride = 640*2
set FRAME_BYTES [expr {640 * 480 * 2}]
set STRIDE      [expr {640 * 2}]

puts "====================================================================="
puts " bd_video.tcl —— 手势识别视频流水线"
puts "   器件: $PART_NAME"
puts "   BD  : $BD_NAME"
puts "   分辨率: ${H_ACTIVE}x${V_ACTIVE}"
puts "====================================================================="

# ---------------------------------------------------------------------
#  0. 导入 HLS 导出的 IP（如果提供了路径）
# ---------------------------------------------------------------------
if {$IP_REPO ne ""} {
    if {![file exists $IP_REPO]} {
        error "IP_REPO 不存在: $IP_REPO"
    }
    set_property ip_repo_paths $IP_REPO [current_project]
    update_ip_catalog -rebuild
    puts ">>> 已导入 HLS IP 仓库: $IP_REPO"
} else {
    puts ">>> 未提供 IP_REPO，跳过 gesture_preproc 的例化"
}

# ---------------------------------------------------------------------
#  1. 创建 BD（幂等：同名先删）
# ---------------------------------------------------------------------
if {[llength [get_files -quiet *$BD_NAME.bd]] > 0} {
    remove_files [get_files *$BD_NAME.bd]
}
if {[llength [get_bd_designs -quiet $BD_NAME]] > 0} {
    delete_bd_objs [get_bd_designs $BD_NAME]
}
create_bd_design $BD_NAME

# =====================================================================
#  2. PS 配置
#
#  ⚠ 不要用 apply_bd_automation ... apply_board_preset 1
#    它会把 PS7 整个重置成板卡预设，**覆盖掉这里设的 HP1/HP2**，
#    之后 connect 报 "Arguments ... cannot be empty"，
#    而报错行号离真正原因几十行，极难往回查。
# =====================================================================
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]

# ⚠⚠ DDR 参数必须显式写，不能吃默认值。
#
#   2026-09-17 查实：本脚本原先**一条 DDR 参数都没有**，Vivado 于是套用了
#   PS7 的出厂默认 —— `MT41J128M8 JP-125`。而 **PYNQ-Z2 板载是
#   MT41K256M16RE-125（32-bit 总线）**，对不上。
#
#   后果的特征很隐蔽：**建工程、综合、实现、出比特流全部通过**，
#   时序报告 WNS 还是正的。只有上板跑起来才暴露。
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0          {1} \
    CONFIG.PCW_USE_M_AXI_GP1          {0} \
    CONFIG.PCW_USE_S_AXI_HP0          {1} \
    CONFIG.PCW_USE_S_AXI_HP1          {1} \
    CONFIG.PCW_USE_S_AXI_HP2          {1} \
    CONFIG.PCW_USE_S_AXI_HP3          {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT   {0} \
    CONFIG.PCW_EN_CLK0_PORT           {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO     {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH  {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ   {533.333} \
] $ps7

# ---- 存在性断言：早失败早定位 ----
foreach need {M_AXI_GP0 S_AXI_HP0 S_AXI_HP1 S_AXI_HP2 S_AXI_HP3 FCLK_CLK0} {
    if {[llength [get_bd_intf_pins -quiet ps7/$need]] == 0 &&
        [llength [get_bd_pins -quiet ps7/$need]] == 0} {
        error "ps7/$need 未生成 —— 检查 PCW_USE_* 是否被覆盖"
    }
}
puts ">>> PS 接口断言通过 (GP0 / HP0 / HP1 / HP2 / HP3)"

# ---- DDR 断言：这类参数写错**不报错**，只会静默取默认值 ----
set ddr_part [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ps7]
if {[string first "MT41K256M16" $ddr_part] < 0} {
    error "DDR PARTNO 未生效，当前值 = '$ddr_part'（期望 MT41K256M16 RE-125）"
}
puts ">>> DDR 断言通过 ($ddr_part)"

# =====================================================================
#  3. 复位
# =====================================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_100m]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0]       [get_bd_pins rst_100m/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]   [get_bd_pins rst_100m/ext_reset_in]

# =====================================================================
#  4. VDMA
# =====================================================================
set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma vdma]

set_property -dict [list \
    CONFIG.c_include_mm2s            {1} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_m_axi_mm2s_data_width   {64} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {16} \
    CONFIG.c_num_fstores             {3} \
    CONFIG.c_mm2s_linebuffer_depth   {2048} \
    CONFIG.c_s2mm_linebuffer_depth   {2048} \
    CONFIG.c_include_sg              {0} \
] $vdma

# ⚠ 只显式设"派生参数"里确实存在的那几个。实测（Vivado 2025.2）：
#   c_mm2s_fsync / c_s2mm_fsync   -> 不存在，报 [BD 41-1276]
#   c_s_axis_s2mm_tdata_width     -> 只读，报 [BD 41-737]
# 盲设不存在的参数只给 CRITICAL WARNING 不报错，极易被忽略。
set_property -dict [list \
    CONFIG.c_mm2s_genlock_mode       {0} \
    CONFIG.c_s2mm_genlock_mode       {0} \
] $vdma

# =====================================================================
#  5. 视频时序控制器 + 生成器（给 HDMI 输出）
# =====================================================================
set vtc [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc]

set_property -dict [list \
    CONFIG.enable_detection {0} \
    CONFIG.VIDEO_MODE       {480p} \
] $vtc

# =====================================================================
#  6. AXI4-Stream → 视频时序（驱动 HDMI）
# =====================================================================
set vout [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out v_axi4s_vid_out]
# ⚠ 这里的格式参数决定 s_axis_video_tdata 的位宽，必须与 VDMA 出来的
#   16bit RGB565 对齐。实测（Vivado 2025.2，DATA_WIDTH=8）：
#       FORMAT=0 -> 16bit   <- 用它（RGB565）
#       FORMAT=1 -> 24bit
#       FORMAT=2 -> 24bit
#   默认值是 2（24bit），与 16bit 的 VDMA 直连会报
#     [BD 41-2384] Width mismatch ... Only lower order bits will be connected
#   颜色会整体错位 —— 这类"能连上但数据错"的警告不能忽略。
set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK           {0} \
    CONFIG.C_ADDR_WIDTH              {11} \
    CONFIG.C_S_AXIS_VIDEO_FORMAT     {0} \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH {8} \
] $vout
# =====================================================================
#  7. 摄像头采集（本项目写的 RTL）
# =====================================================================
#  ⚠ dvp_capture 是手写 Verilog，不属于任何 IP 仓库。
#    在 Vivado 工程里以 RTL 源的方式加入，然后 create_bd_cell -type module。
#    这里假设源文件已被 add_files 加入工程（见 create_video_project.tcl）。
#  ⚠ 逐个文件检查是否已在工程里，而不是用"dvp_capture 在不在"当开关。
#    早期写法是 `if {dvp_capture.v 不在工程} { 加全部 }` —— 一旦
#    dvp_capture 已存在（上一轮加过），新增的 iobuf_wrap.v /
#    ov5640_regs.v 就**永远加不进来**，报
#      [BD 41-1690] Unable to resolve module-source
set _rtl [file normalize [file join [file dirname [info script]] ../rtl]]
foreach _f {dvp_capture.v async_fifo.v sccb_master.v iobuf_wrap.v ov5640_regs.v} {
    # ⚠ 不用 continue —— Vivado 的 Tcl 解释器在部分上下文里对
    #    foreach 内的 continue 报 "wrong # args: should be continue"。
    #    改用嵌套 if 表达同样的"已存在就跳过"。
    if {[llength [get_files -quiet "*/$_f"]] == 0} {
        if {[file exists [file join $_rtl $_f]]} {
            add_files -norecurse [file join $_rtl $_f]
            puts ">>> 已加入 rtl/$_f"
        } else {
            puts "WARN: 找不到 rtl/$_f"
        }
    }
}

set cap [create_bd_cell -type module -reference dvp_capture dvp_capture_0]

# ---------------------------------------------------------------------
#  7.2 Clocking Wizard：产生 24 MHz XCLK 给摄像头
#
#  ⚠ PMOD-CAMERA v1.0 **没有板载晶振** —— 原理图 J2 pin 1 = XMCLK，
#    是**输入**，必须由 FPGA 提供主时钟。
#
#  100 MHz → 24 MHz **不是整数分频**，必须用 MMCM。参数推导：
#      VCO = 100 MHz * M / D
#      XCLK = VCO / O
#  Zynq-7020 速度等级 -1 的 VCO 范围是 600–1200 MHz。
#  试 M=12, D=1 → VCO = 1200 MHz（正好在上限）
#                 O = 1200/24 = 50（整数）✓
#
#  ⚠ VCO 取到上限是刻意的：24 MHz 的合成分辨率最高。
#    如果实测 MMCM 锁定困难（罕见），可试 M=6/D=1/VCO=600/O=25。
# ---------------------------------------------------------------------
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_xclk]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ          {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {24.000} \
    CONFIG.USE_LOCKED            {true} \
    CONFIG.USE_RESET             {true} \
    CONFIG.RESET_TYPE            {ACTIVE_LOW} \
    CONFIG.PRIMITIVE             {MMCM} \
] $cw

# ⚠ 用 MMCM 而不是 PLL：PLL 在 602–1200 的范围内对 VCO 更敏感，
#    MMCM 对非整数比更宽容。这个比正好整数（O=50），两者都行，
#    但 MMCM 是默认推荐的。

puts ">>> Clocking Wizard 已例化（100 MHz -> 24 MHz XCLK）"

# ---------------------------------------------------------------------
#  7.3 SCCB 主控：配置 OV5640
#
#  ⚠ 为什么用自写的 sccb_master 而不是 Xilinx 的 AXI IIC IP：
#    1. SCCB 落在 Pmod A 的**普通 GPIO** 上（ja[2]/ja[6]），
#       不是 PYNQ 的专用 I2C 引脚（P15/P16 在 Arduino 座上，
#       与 Pmod A 的物理位置无关）
#    2. sccb_master 已写好并通过自检（10/10），直接复用
#    3. 省一个 AXI-Lite 从口和相应地址分配
#
#  连接方式（在 §10 外部端口段）：
#      sccb_master/scl   → io_scl（输出）
#      sccb_master/sda_oe + sda_o → IOBUF → io_sda（双向）
#      sccb_master/sda_i ← IOBUF 读回
#
#  ⚠ 寄存器配置表由 rtl/ov5640_regs.v 提供（按 tbl_addr 索引的常量 ROM）。
#    独立成模块而不是塞进 BD 的原因：那张表上百项，写成 Tcl 常量列表
#    既难维护也难核对。
#  ✅ 2026-09-17：已由"8 条占位值"替换为**真实配置表**。
#     来源：正点原子 i2c_ov5640_rgb565_cfg.v，250 条，固化为 640x480 RGB565。
#     详见 rtl/ov5640_regs.v 文件头。
# ---------------------------------------------------------------------
set sccb [create_bd_cell -type module -reference sccb_master sccb_0]

# ⚠⚠ N_REGS 是**最容易漏的一处**：
#    sccb_master.v 的参数默认值是 **64**，而配置表是 **250** 条。
#    两者不一致时 sccb **配到一半就停下**（或越界读垃圾值），
#    而且**没有任何报错** —— 症状是"摄像头毫无反应"。
#    改了配置表的条目数，就必须同步改这里的 N_REGS。
set_property -dict [list CONFIG.N_REGS {250}] $sccb
puts ">>> sccb_0 的 N_REGS 已设为 250（与 ov5640_regs.v 一致）"

set oreg [create_bd_cell -type module -reference ov5640_regs ov5640_regs_0]

# IOBUF：SDA 是开漏双向线，需要三态缓冲。
# ⚠ Vivado 的 BD 里不能直接例化 IOBUF 原语（原语不是 IP，也不是可
#    直接被 module reference 引用的源），所以包一层 rtl/iobuf_wrap.v。
set iobuf [create_bd_cell -type module -reference iobuf_wrap iobuf_sda_0]

puts ">>> SCCB 主控 + 寄存器表 + IOBUF 已例化"

# =====================================================================
#  8. 预处理链（gesture_preproc + 两个 AXI DMA）
#
#  数据流：
#      DDR(640x480 RGB565)
#          │  dma_in (MM2S，读 614400 字节)
#          ▼
#      gesture_preproc ──► 96x96 灰度
#          │  dma_out (S2MM，写 9216 字节)
#          ▼
#      DDR(96x96 uint8)  ← CNN 侧读这里
#
#  ─────────────────────────────────────────────────────────────────
#  为什么要两个独立的 AXI DMA，而不是一个 DMA 的 MM2S+S2MM
#  ─────────────────────────────────────────────────────────────────
#  一个 DMA 的 MM2S 与 S2MM 是**独立通道**，本来可以各走各的。
#  这里仍用两个独立 IP，原因是：
#    * 输入输出长度不同（614400 vs 9216 字节），分开更直观
#    * 两个 DMA 可以并行配置，PS 侧驱动逻辑更简单
#    * 单 DMA 的 S2MM 要等 MM2S 供数，握手时序更难调
#  代价是多占一个 AXI-Lite 从口和一点 LUT，对这个规模可以接受。
#
#  ⚠ 触发方式：帧触发 + 轮询（PS 控制）
#    PS 检测到新帧 → 配置两个 DMA（S2MM 先武装）→ ap_start
#    → 轮询 ap_done → 读结果 / 置 frame_ready
#    见 docs/architecture-contract.md §3.2
# =====================================================================
set has_gesture 0
if {$IP_REPO ne ""} {
    if {[llength [get_ipdefs -quiet -all user:hls:gesture_preproc:1.0]] == 0} {
        puts "WARN: IP 仓库里没有 user:hls:gesture_preproc:1.0，跳过预处理链"
    } else {
        set has_gesture 1
    }
}

if {$has_gesture} {
    # ---- 8.1 HLS 预处理 IP ----
    set gpre [create_bd_cell -type ip \
        -vlnv user:hls:gesture_preproc:1.0 gesture_preproc_0]

    # ---- 8.2 输入 DMA：DDR → 预处理 ----
    # MM2S 读 614400 字节（640*480*2），Stream 位宽 16（RGB565）
    set dma_in [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma_in]
    set_property -dict [list \
        CONFIG.c_include_sg                  {0} \
        CONFIG.c_sg_include_stscntrl_strm    {0} \
        CONFIG.c_include_mm2s                {1} \
        CONFIG.c_include_s2mm                {0} \
        CONFIG.c_m_axi_mm2s_data_width       {32} \
        CONFIG.c_m_axis_mm2s_tdata_width     {16} \
        CONFIG.c_mm2s_burst_size             {64} \
    ] $dma_in

    # ---- 8.3 输出 DMA：预处理 → DDR ----
    # S2MM 写 9216 字节（96*96），Stream 位宽 8（灰度）
    set dma_out [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma_out]
    set_property -dict [list \
        CONFIG.c_include_sg                  {0} \
        CONFIG.c_sg_include_stscntrl_strm    {0} \
        CONFIG.c_include_mm2s                {0} \
        CONFIG.c_include_s2mm                {1} \
        CONFIG.c_m_axi_s2mm_data_width       {32} \
        CONFIG.c_s_axis_s2mm_tdata_width     {8} \
        CONFIG.c_s2mm_burst_size             {64} \
    ] $dma_out

    puts ">>> 预处理链已例化 (gesture_preproc + dma_in + dma_out)"
} else {
    puts ">>> IP_REPO 未提供或 IP 不存在 —— 预处理链跳过"
    puts "    提供方式：set IP_REPO <工程根>/gesture_comp/solution1/impl/ip"
}

# =====================================================================
#  9. AXI 互连
#
#  一个控制互连（GP0 → 各 IP 的 AXI-Lite）
#  三个数据互连：
#      HP1 ← VDMA S2MM        摄像头帧写入 DDR
#      HP2 → VDMA MM2S        从 DDR 读帧送 HDMI
#      HP3 ← 预处理链的两次 DMA（读原图 + 写 96x96）
#
#  ─────────────────────────────────────────────────────────────────
#  ⚠ 为什么预处理从 DDR 取数据，而不是从 dvp_capture 分叉
#  ─────────────────────────────────────────────────────────────────
#  曾考虑用 axis_broadcaster 把 dvp_capture 的输出一分为二：
#  一路给 VDMA（显示），一路给 gesture_preproc（CNN）。
#
#  但那会**反压崩溃**：broadcaster 要求所有输出都 ready 才收输入，
#  而 gesture_preproc 是 HLS 的 ap_ctrl_hs 模式 —— **未 ap_start 时
#  tready=0**。于是 gesture_preproc 空闲时（CNN 不需要 30fps，
#  它大部分时间空闲），broadcaster 反压 → VDMA 收不到数 →
#  **HDMI 显示也一起卡死**。
#
#  从 DDR 分叉则完全解耦：
#    * 显示通路一字未动，CNN 通路出任何问题都不影响画面
#    * gesture_preproc 按 PS 的节奏跑，不必死磕 30fps 时序
#    * 同一份 DDR 数据在 PC 上也能拿来对拍 Python golden
#  代价是多一次 DDR 往返（614 KB/帧读），相对三个 HP 口的总带宽很小。
# =====================================================================
set ic_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_ctrl]
# M00=vdma, M01=v_tc, M02=gesture_preproc, M03=dma_in, M04=dma_out
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {5}] $ic_ctrl

set ic_hp1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp1]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic_hp1

set ic_hp2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp2]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic_hp2

# 预处理链的两个 DMA 主口都接到 HP3（一个从口，两个主口）
set ic_hp3 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_hp3]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $ic_hp3

# =====================================================================
#  9. 连接
# =====================================================================

# ---- 控制通路 ----
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0]   [get_bd_intf_pins ic_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M00_AXI] [get_bd_intf_pins vdma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M01_AXI] [get_bd_intf_pins v_tc/ctrl]

# ---- 预处理链的控制与数据（仅当 IP 存在时）----
if {$has_gesture} {
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M02_AXI] \
                        [get_bd_intf_pins gesture_preproc_0/s_axi_control]
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M03_AXI] \
                        [get_bd_intf_pins dma_in/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M04_AXI] \
                        [get_bd_intf_pins dma_out/S_AXI_LITE]

    # 输入 DMA 读 DDR → 预处理
    connect_bd_intf_net [get_bd_intf_pins dma_in/M_AXI_MM2S] \
                        [get_bd_intf_pins ic_hp3/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_in/M_AXIS_MM2S] \
                        [get_bd_intf_pins gesture_preproc_0/src]

    # 预处理 → 输出 DMA 写 DDR
    connect_bd_intf_net [get_bd_intf_pins gesture_preproc_0/dst] \
                        [get_bd_intf_pins dma_out/S_AXIS_S2MM]
    connect_bd_intf_net [get_bd_intf_pins dma_out/M_AXI_S2MM] \
                        [get_bd_intf_pins ic_hp3/S01_AXI]
}

connect_bd_intf_net [get_bd_intf_pins ic_hp3/M00_AXI]  [get_bd_intf_pins ps7/S_AXI_HP3]

# ⚠ ic_ctrl 只开 2 个主口（vdma / v_tc），全部接满。
#
#   实测 v_axi4s_vid_out **没有 AXI 接口** —— 它的接口只有
#   vid_io_out / video_in / vtiming_in 三个，纯流式，无需配置。
#   所以不要给它接 AXI-Lite。
#   悬空的 AXI 主口不会报错、综合实现比特流全过，只有上板才炸
#   —— 所以宁可少开一个口也不要留悬空。

# ---- 数据通路：摄像头 → S2MM → HP1 ----
connect_bd_intf_net [get_bd_intf_pins dvp_capture_0/m_axis]   [get_bd_intf_pins vdma/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_S2MM]        [get_bd_intf_pins ic_hp1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_hp1/M00_AXI]         [get_bd_intf_pins ps7/S_AXI_HP1]

# ---- 数据通路：MM2S → HDMI ----
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXIS_MM2S]       [get_bd_intf_pins v_axi4s_vid_out/video_in]
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_MM2S]        [get_bd_intf_pins ic_hp2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_hp2/M00_AXI]         [get_bd_intf_pins ps7/S_AXI_HP2]

# ---- VTC → v_axi4s_vid_out ----
connect_bd_intf_net [get_bd_intf_pins v_tc/vtiming_out] [get_bd_intf_pins v_axi4s_vid_out/vtiming_in]

# ---- 时钟 ----
#
#  ⚠ AXI 互连的时钟是**每端口一个**：ACLK 是全局的，但 S00_ACLK /
#    M00_ACLK / M01_ACLK 必须**逐个连接**，只连 ACLK 会报
#      [BD 41-758] The following clock pins are not connected to a valid clock source
#    这是一个很容易漏的点：ACLK 看起来已经连了，validate 仍然报错。
#
#  ⚠ v_tc 有两个时钟域：clk（视频时序）与 s_axi_aclk（AXI-Lite）。
#    只连 clk 会让 AXI 侧无时钟。两者都连到同一个 100 MHz 即可。
#
#  ⚠ PS 侧的 M_AXI_GP0_ACLK / S_AXI_HP*_ACLK 也必须显式连 ——
#    PS 的这些引脚不会自动跟随 FCLK_CLK0。
set CLK [get_bd_pins ps7/FCLK_CLK0]

set clk_pins {
    ps7/M_AXI_GP0_ACLK
    ps7/S_AXI_HP0_ACLK
    ps7/S_AXI_HP1_ACLK
    ps7/S_AXI_HP2_ACLK

    ic_ctrl/ACLK ic_ctrl/S00_ACLK
    ic_ctrl/M00_ACLK ic_ctrl/M01_ACLK ic_ctrl/M02_ACLK
    ic_ctrl/M03_ACLK ic_ctrl/M04_ACLK
    ic_hp1/ACLK  ic_hp1/S00_ACLK  ic_hp1/M00_ACLK
    ic_hp2/ACLK  ic_hp2/S00_ACLK  ic_hp2/M00_ACLK
    ic_hp3/ACLK  ic_hp3/S00_ACLK  ic_hp3/S01_ACLK  ic_hp3/M00_ACLK
    ps7/S_AXI_HP3_ACLK

    vdma/s_axi_lite_aclk
    vdma/m_axi_mm2s_aclk
    vdma/m_axi_s2mm_aclk
    vdma/s_axis_s2mm_aclk
    vdma/m_axis_mm2s_aclk

    v_tc/clk
    v_tc/s_axi_aclk
    v_axi4s_vid_out/aclk
    dvp_capture_0/aclk

    clk_wiz_xclk/clk_in1
    sccb_0/clk
}

# 预处理链的时钟引脚（只在 IP 存在时才连着，但引脚列表可以无条件拼）
if {$has_gesture} {
    foreach p {
        gesture_preproc_0/ap_clk
        dma_in/s_axi_lite_aclk
        dma_in/m_axi_mm2s_aclk
        dma_out/s_axi_lite_aclk
        dma_out/m_axi_s2mm_aclk
    } {
        if {[llength [get_bd_pins -quiet $p]] > 0} {
            lappend clk_pins $p
        }
    }
}

set n_clk 0
foreach pin $clk_pins {
    if {[llength [get_bd_pins -quiet $pin]] == 0} {
        puts "WARN: 时钟引脚 $pin 不存在，跳过"
        continue
    }
    connect_bd_net $CLK [get_bd_pins $pin]
    incr n_clk
}
puts ">>> 已连接 $n_clk 个时钟引脚到 FCLK_CLK0"

# 逐个断言：validate 前先自己查一遍，错在发生的那一行
set unconnected {}
foreach pin $clk_pins {
    set p [get_bd_pins -quiet $pin]
    if {[llength $p] == 0} { continue }
    if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
        lappend unconnected $pin
    }
}
if {[llength $unconnected] > 0} {
    error "以下时钟引脚仍未连接: $unconnected"
}

# ---- 复位 ----
#
# ⚠⚠ AXI 互连的复位是**每端口一个**，只连 ARESETN 不够。
#     漏连的 S00_ARESETN / M00_ARESETN 会被自动 tie-off 到 0
#     （validate 报 [BD 41-759] CRITICAL WARNING），
#     后果是**互连永远处于复位状态，AXI 事务一条都过不去**。
#
#     这个错误综合、实现、生成比特流**全部会通过**，只有上板才暴露 ——
#     与本项目原工程踩过的 PS7 配置被覆盖（README §9.7）是同一类问题。
#     所以这里逐个连、并逐个断言。
set ARSTN [get_bd_pins rst_100m/peripheral_aresetn]

set rst_pins {
    ic_ctrl/ARESETN ic_ctrl/S00_ARESETN
    ic_ctrl/M00_ARESETN ic_ctrl/M01_ARESETN ic_ctrl/M02_ARESETN
    ic_ctrl/M03_ARESETN ic_ctrl/M04_ARESETN
    ic_hp1/ARESETN  ic_hp1/S00_ARESETN  ic_hp1/M00_ARESETN
    ic_hp2/ARESETN  ic_hp2/S00_ARESETN  ic_hp2/M00_ARESETN
    ic_hp3/ARESETN  ic_hp3/S00_ARESETN  ic_hp3/S01_ARESETN  ic_hp3/M00_ARESETN
    ps7/S_AXI_HP0_ARESETN_N
    ps7/S_AXI_HP1_ARESETN_N
    ps7/S_AXI_HP2_ARESETN_N
}

# 预处理链的复位引脚（同理，无条件拼入，不存在时会被上面的 get_bd_pins 检查过滤）
if {$has_gesture} {
    foreach p {
        gesture_preproc_0/ap_rst_n
        dma_in/axi_resetn
        dma_out/axi_resetn
    } {
        if {[llength [get_bd_pins -quiet $p]] > 0} {
            lappend rst_pins $p
        }
    }
}

set n_rst 0
foreach pin $rst_pins {
    if {[llength [get_bd_pins -quiet $pin]] == 0} {
        puts "WARN: 复位引脚 $pin 不存在，跳过"
        continue
    }
    connect_bd_net $ARSTN [get_bd_pins $pin]
    incr n_rst
}
puts ">>> 已连接 $n_rst 个复位引脚"

# 逐个断言：把"悬空被 tie-off"消灭在 validate 之前
set rst_bad {}
foreach pin $rst_pins {
    set p [get_bd_pins -quiet $pin]
    if {[llength $p] == 0} { continue }
    if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
        lappend rst_bad $pin
    }
}
if {[llength $rst_bad] > 0} {
    error "以下复位引脚仍未连接: $rst_bad"
}
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins v_tc/resetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins v_axi4s_vid_out/aresetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins vdma/axi_resetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins dvp_capture_0/rst_n]

# ---- Clocking Wizard 与 SCCB 的复位 ----
# ⚠ Clocking Wizard 的 reset 是**低有效**（CONFIG.RESET_TYPE=ACTIVE_LOW，
#   见 §7.2），所以接 peripheral_aresetn 而不是它的反相版本。
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins clk_wiz_xclk/resetn]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins sccb_0/rst_n]

# =====================================================================
#  10. 外部端口（接 OV5640 / HDMI）
# =====================================================================

# ---- 摄像头侧（PMOD-CAMERA v1.0）----
#
#  ⚠⚠ 端口名用 io_* 而不是 cam_*，因为**方向和类型都变了**：
#
#      XCLK  → 从"输入"变成 **FPGA 输出**（模块没晶振，要 PL 给）
#      SDA   → 从"无"变成 **双向**（SCCB 开漏总线）
#      SCL   → 从"无"变成 **FPGA 输出**
#      其余  → 仍是输入
#
#  这也是"硬件换方案后 BD 必须跟着改"的典型：不是改个名，
#  是接口方向变了。
#
#  引脚映射（来自 PR 的模块原理图，镜像编号解读，见 video_io.xdc）：
#      J2 → Pmod A：XCLK/VSYNC/SDA/HREF/SCL/PCLK = ja[0,1,2,4,5,6]
#      J3 → Pmod B：D0-D7（交错）
#
#  ⚠ io_pclk 是输入时钟，必须给 -freq_hz（否则报 [BD 5-670]）
create_bd_port -dir I -type clk -freq_hz 24000000 io_pclk
create_bd_port -dir I       io_vsync
create_bd_port -dir I       io_href
create_bd_port -dir I -from 7 -to 0 io_d

# XCLK 与 SCL 是输出
create_bd_port -dir O       io_xclk
create_bd_port -dir O       io_scl

# SDA 是双向
create_bd_port -dir IO      io_sda

# ⚠ dvp_capture 只有**一个** rst_n 端口，已由 rst_100m/peripheral_aresetn
#   驱动（见上面复位段）。这里**不能**再连一次 —— 会报
#     [BD 5-676] The sink is already connected to another source
#   摄像头侧不需要独立复位。
connect_bd_net [get_bd_ports io_pclk]  [get_bd_pins dvp_capture_0/pclk]
connect_bd_net [get_bd_ports io_vsync] [get_bd_pins dvp_capture_0/cam_vsync]
connect_bd_net [get_bd_ports io_href]  [get_bd_pins dvp_capture_0/cam_href]
connect_bd_net [get_bd_ports io_d]     [get_bd_pins dvp_capture_0/cam_data]

# ---- XCLK：Clocking Wizard 输出 → 外部端口 ----
connect_bd_net [get_bd_pins clk_wiz_xclk/clk_out1] [get_bd_ports io_xclk]

# ---- SCCB：sccb_master ↔ 寄存器表 ↔ IOBUF ↔ 外部 ----
# 寄存器表给出 {寄存器地址, 数据}
connect_bd_net [get_bd_pins sccb_0/tbl_addr]  [get_bd_pins ov5640_regs_0/tbl_addr]
connect_bd_net [get_bd_pins ov5640_regs_0/tbl_data] [get_bd_pins sccb_0/tbl_data]

# SCL 直连（推挽输出足够驱动 OV5640 的从机）
connect_bd_net [get_bd_pins sccb_0/scl] [get_bd_ports io_scl]

# SDA 经 IOBUF：sccb_master 的 oe/o 出去，i 读回
connect_bd_net [get_bd_pins sccb_0/sda_oe]  [get_bd_pins iobuf_sda_0/io_drv]
connect_bd_net [get_bd_pins sccb_0/sda_o]   [get_bd_pins iobuf_sda_0/io_out]
connect_bd_net [get_bd_pins iobuf_sda_0/io_in] [get_bd_pins sccb_0/sda_i]
connect_bd_net [get_bd_pins iobuf_sda_0/io_pad] [get_bd_ports io_sda]

# ⚠ ov5640_regs 与 sccb_master 的 tbl_addr **位宽必须一致**（都是 8 位）。
#   曾经 ov5640_regs 用 12 位而 sccb 用 8 位，BD 报
#     [BD 41-2383] Width mismatch ... other input bits will be left unconnected
#   高 4 位悬空意味着表一旦超过 256 项就会**静默读错** ——
#   这类"能连上但数据错"的警告不能忽略。

# ---- HDMI 输出 ----
#
#  ⚠ v_axi4s_vid_out 的视频输出是一个**接口**（vid_io_out），不是散引脚。
#    实测接口列表：vid_io_out(Master) / video_in(Slave) / vtiming_in(Slave)
#    早期版本按 vid_data/vid_hsync 那种散引脚名连接，会报
#      [BD 5-232] No interface pins matched
#    因为它确实是接口而不是引脚。
#
#  ⚠ TMDS 编码（vid_io_out → HDMI 物理引脚）**本 BD 不做**，故意分步：
#    TMDS 是独立的编码问题（8b/10b + 差分对），把它塞进这个 BD 会让
#    "数据通路是否通"和"HDMI 能不能显示"两个问题纠缠在一起。
#    先把 vid_io_out 引成外部接口，下一步单独接 TMDS 编码器模块。
# ⚠ 用 make_bd_intf_pins_external 而不是 create_bd_intf_port -vlnv。
#   手写 VLNV 'xilinx.com:interface:vid_io:1.0' 会报
#     [BD 41-52] Could not find the abstraction definition
#   因为该 VLNV 在当前 IP 目录里查不到（不同版本命名有差异）。
#   make_bd_intf_pins_external 直接从一个已有接口引脚导出，
#   VLNV 由工具自己取，不会写错。
make_bd_intf_pins_external [get_bd_intf_pins v_axi4s_vid_out/vid_io_out]

# 重命名成有意义的端口名。
# ⚠ 不要硬猜 make_bd_intf_pins_external 生成的端口名 —— 它可能是
#   vid_io_out，也可能被加后缀。用"排除已有端口"的方式取到它。
set _newport {}
foreach _p [get_bd_intf_ports -quiet] {
    if {[get_property NAME $_p] ne "cam_pclk"} {
        set _newport $_p
    }
}
if {[llength $_newport] > 0} {
    set_property name hdmi_vid_out $_newport
    puts ">>> HDMI 视频接口已导出为外部端口 hdmi_vid_out"
} else {
    puts "WARN: 未找到 make_bd_intf_pins_external 生成的端口"
}

# =====================================================================
#  11. 地址分配
# =====================================================================
assign_bd_address

# =====================================================================
#  12. 验证（必做）
#
#  ⚠ 悬空的 AXI 主端口不构成错误 —— 综合/实现/比特流全过，只有上板才炸。
#    必须逐条读 CRITICAL WARNING。
# =====================================================================
puts "\n>>> validate_bd_design"
validate_bd_design

# 检查是否存在悬空的 AXI 接口
#
# ⚠ 只检查 AXI 类接口。外部视频接口（hdmi_vid_out）**本来就只有 1 个端点**
#   —— 它是从内部引脚导出的对外端口，另一端在 BD 外面。
#   早期版本没做这个区分，把合法的外部端口误报成"悬空接口"。
set dangling 0
foreach intf [get_bd_intf_nets -quiet] {
    set pins [get_bd_intf_pins -quiet -of_objects $intf]
    if {[llength $pins] < 2} {
        # 取该网上的接口引脚所属的 VLNV，跳过非 AXI 的
        set skip 0
        foreach p $pins {
            set vlnv ""
            catch {set vlnv [get_property VLNV [get_property TYPE $p]]}
            if {[string match "*vid_io*" $vlnv]} { set skip 1 }
        }
        if {$skip} { continue }
        puts "WARN: 悬空接口网 $intf 只连了 [llength $pins] 个端点 (非 AXI，忽略)"
    }
}
# 真正要防的是 AXI 主口悬空：综合实现比特流都过，只有上板才炸。
# 逐个检查每个 AXI 互连的从口/主口是否都有连接。
set axio_bad {}
foreach c [get_bd_cells -quiet] {
    set nm [get_property NAME $c]
    if {![string match "ic_*" $nm]} { continue }
    foreach ip [get_bd_intf_pins -quiet -of_objects $c] {
        set inm [get_property NAME $ip]
        if {[string match "*_AXI" $inm]} {
            if {[llength [get_bd_intf_nets -quiet -of_objects $ip]] == 0} {
                lappend axio_bad "$nm/$inm"
            }
        }
    }
}
if {[llength $axio_bad] > 0} {
    error "以下 AXI 接口悬空（综合会过但上板必炸）: $axio_bad"
}
puts ">>> AXI 接口检查通过：无悬空主口/从口" 

# =====================================================================
#  13. 生成产物
# =====================================================================
save_bd_design

puts "\n====================================================================="
puts " bd_video 构建完成"
puts "   BD 文件: [get_files $BD_NAME.bd]"
puts ""
puts " 下一步（在 Vivado 里）："
puts "   1. 生成 wrapper:  make_wrapper -files \[get_files $BD_NAME.bd\] -top"
puts "   2. 加 XDC 约束:   vivado/constraints/video_io.xdc"
puts "   3. 综合实现，读 CRITICAL WARNING"
puts ""
puts " ⚠ 未验证项："
puts "   - HDMI 的 TMDS 编码未接（见第 10 节注释，故意分步）"
puts "   - dvp_capture 的 AXI-Lite 控制口未实现（当前用常量占位）"
puts "   - 未经板级实测（板子未到）"
puts "====================================================================="
