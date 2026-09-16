# =====================================================================
#  bd_sobel.tcl —— 构建 Sobel 系统的 Block Design
#
#  由 create_project.tcl 调用（source 本文件），也可单独执行。
#
#  需要预先存在：
#    - 已打开的工程
#    - 已导入的 sobel_accel HLS IP
#
#  生成的系统：
#
#      ZYNQ7 PS          axi_dma            sobel_accel
#    ┌──────────┐     ┌──────────┐       ┌─────────────┐
#    │ M_AXI_GP0├────►│ S_AXI_LT │       │ s_axi_ctrl  │
#    │          │  ┌─►│          │       │             │
#    │ S_AXI_HP0│◄─┤  │ M_AXI_MM2S├──────►│ s_axis      │
#    │          │  └─►│ M_AXI_S2MM│◄──────┤ m_axis      │
#    │          │     └──────────┘       └─────────────┘
#    │ FCLK_CLK0├──► 时钟
#    │ FCLK_RSTN├──► 复位
#    └──────────┘
# =====================================================================

# 允许被 create_project.tcl source 进来时复用已有的 bd 名
if {![info exists BD_NAME]} {
    set BD_NAME "sobel_bd"
}
if {![info exists PART_NAME]} {
    set PART_NAME "xc7z020clg400-1"
}
# PROJ_DIR / PROJ_NAME 由 create_project.tcl 提供；单独跑本脚本时兜底
if {![info exists PROJ_NAME]} {
    set PROJ_NAME "sobel_system"
}
if {![info exists PROJ_DIR]} {
    set PROJ_DIR [file normalize "[pwd]/$PROJ_NAME"]
}

# ---------------------------------------------------------------------
#  创建 Block Design
#
#  已存在同名 BD 时先清掉。
#  注意不能只写 delete_bd_objs：工程被 create_project.tcl --keep 复用时，
#  BD 文件在磁盘上但**并未在内存中打开**，此时 get_bd_designs 返回空，
#  delete_bd_objs 会报 "A block design must be open to run this command"。
#  所以改成从工程移除文件 + 删磁盘文件，无论 BD 是否打开都成立。
# ---------------------------------------------------------------------
set existing_bd [get_files -quiet *$BD_NAME.bd]
if {[llength $existing_bd] > 0} {
    puts ">>> BD '$BD_NAME' 已存在，先移除"
    catch { remove_files $existing_bd }
    foreach f $existing_bd { catch { file delete -force $f } }
}

# 旧的 wrapper 也要清掉，否则会残留指向已删 BD 的引用
set old_wrapper [glob -nocomplain \
    "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"]
foreach w $old_wrapper {
    catch { remove_files [get_files -quiet $w] }
    catch { file delete -force $w }
}

create_bd_design $BD_NAME
current_bd_design [get_bd_designs $BD_NAME]

puts ">>> 创建 BD: $BD_NAME"

# ---------------------------------------------------------------------
#  1. ZYNQ7 Processing System
# ---------------------------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
puts ">>> 添加 PS7"

# 显式配置 PS7。
#
# ⚠️ 不要用 apply_bd_automation ... apply_board_preset 1 来"套板卡默认值"：
#    那个规则会把 PS7 整个重置成板卡预设，**覆盖掉这里设的 HP0/GP0**，
#    结果是 ps7/S_AXI_HP0 不存在，后面 connect_bd_intf_net 拿到空列表报
#    "Arguments ... cannot be empty"。
#    所以下面所有需要的接口都显式打开。
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0          {1} \
    CONFIG.PCW_USE_M_AXI_GP1          {0} \
    CONFIG.PCW_USE_S_AXI_HP0          {1} \
    CONFIG.PCW_USE_S_AXI_HP1          {0} \
    CONFIG.PCW_USE_S_AXI_HP2          {0} \
    CONFIG.PCW_USE_S_AXI_HP3          {0} \
    CONFIG.PCW_EN_CLK0_PORT           {1} \
    CONFIG.PCW_EN_RST0_PORT           {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT   {0} \
    CONFIG.PCW_EN_CLK1_PORT           {0} \
    CONFIG.PCW_EN_CLK2_PORT           {0} \
    CONFIG.PCW_EN_CLK3_PORT           {0} \
    CONFIG.PCW_USE_S_AXI_ACP          {0} \
    CONFIG.PCW_USE_S_AXI_GP0          {0} \
    CONFIG.PCW_USE_S_AXI_GP1          {0} \
    CONFIG.PCW_USE_DMA0               {0} \
    CONFIG.PCW_USE_DMA1               {0} \
] $ps

# 确认关键接口真的生成了 —— 早失败早定位，比在 connect 那一步报
# 一句没头没尾的 "cannot be empty" 好得多
foreach need {M_AXI_GP0 S_AXI_HP0} {
    if {[llength [get_bd_intf_pins -quiet ps7/$need]] == 0} {
        error "PS7 未生成 $need 接口，请检查上面的 PCW_USE_* 配置是否生效"
    }
}
puts ">>> PS7 接口已就绪 (M_AXI_GP0 + S_AXI_HP0)"

# 尝试从板卡带出 DDR 型号与时钟预设。
# 用 propagate_bd_preset 而不是 apply_bd_automation：后者会重置接口配置。
catch { apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "0"} $ps }

# 若上面的规则又把接口关掉了，重新打开一次（幂等）
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
] $ps

if {[llength [get_bd_intf_pins -quiet ps7/S_AXI_HP0]] == 0} {
    error "PS7 的 S_AXI_HP0 最终未生成，BD 无法连接数据通路"
}

# ---------------------------------------------------------------------
#  2. AXI DMA
# ---------------------------------------------------------------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma0]
puts ">>> 添加 AXI DMA"

set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {8} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {8} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_addr_width {32} \
] $dma

# ---------------------------------------------------------------------
#  3. Sobel IP
# ---------------------------------------------------------------------
set sobel_vlnv "user.com:hls:sobel_accel:1.0"

# 若 VLNV 与预期不符，从 IP catalog 里模糊查找，避免版本号/厂商名差异导致失败
if {[llength [get_ipdefs -quiet $sobel_vlnv]] == 0} {
    set found [get_ipdefs -quiet *sobel_accel*]
    if {[llength $found] == 0} {
        error "找不到 sobel_accel IP。请先跑 src_hls/run_hls.tcl 导出 IP，\
               并在 create_project.tcl 里用 read_ip 导入 .xci。"
    }
    set sobel_vlnv [lindex $found 0]
    puts ">>> 自动匹配到 IP: $sobel_vlnv"
}

set sobel [create_bd_cell -type ip -vlnv $sobel_vlnv sobel_0]
puts ">>> 添加 Sobel IP: $sobel_vlnv"

# ---------------------------------------------------------------------
#  4. 复位
# ---------------------------------------------------------------------
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst0]
puts ">>> 添加 proc_sys_reset"

# ---------------------------------------------------------------------
#  5. 时钟与复位连接
# ---------------------------------------------------------------------
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
               [get_bd_pins ps7/M_AXI_GP0_ACLK] \
               [get_bd_pins ps7/S_AXI_HP0_ACLK] \
               [get_bd_pins dma0/s_axi_lite_aclk] \
               [get_bd_pins dma0/m_axi_mm2s_aclk] \
               [get_bd_pins dma0/m_axi_s2mm_aclk] \
               [get_bd_pins sobel_0/ap_clk] \
               [get_bd_pins rst0/slowest_sync_clk]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst0/ext_reset_in]

# DMA 与 IP 共用同一复位域
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
               [get_bd_pins dma0/axi_resetn] \
               [get_bd_pins sobel_0/ap_rst_n]

puts ">>> 时钟/复位已连接"

# ---------------------------------------------------------------------
#  6. AXI 互联：GP0 -> (DMA s_axi_lite, Sobel s_axi_control)
# ---------------------------------------------------------------------
set ic_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_ctrl]
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {2} \
] $ic_ctrl

if {[llength [get_bd_intf_pins -quiet ic_ctrl/M01_AXI]] == 0} {
    error "ic_ctrl 未生成 M01_AXI 引脚，NUM_MI 配置未生效"
}

connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins ic_ctrl/S00_AXI]

connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M00_AXI] \
                    [get_bd_intf_pins dma0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M01_AXI] \
                    [get_bd_intf_pins sobel_0/s_axi_control]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
               [get_bd_pins ic_ctrl/ACLK] \
               [get_bd_pins ic_ctrl/S00_ACLK] \
               [get_bd_pins ic_ctrl/M00_ACLK] \
               [get_bd_pins ic_ctrl/M01_ACLK]
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
               [get_bd_pins ic_ctrl/ARESETN] \
               [get_bd_pins ic_ctrl/S00_ARESETN] \
               [get_bd_pins ic_ctrl/M00_ARESETN] \
               [get_bd_pins ic_ctrl/M01_ARESETN]

puts ">>> 控制通路已连接 (GP0 -> DMA + Sobel)"

# ---------------------------------------------------------------------
#  7. AXI 互联：DMA 两个 M_AXI -> HP0
#
#  注意：axi_interconnect 的 NUM_SI/NUM_MI 必须在创建后**一次性**用 -dict
#  设好，否则引脚按默认值生成；后续单独 set_property 不会补出新引脚，
#  于是 get_bd_intf_pins 拿到空列表，connect_bd_intf_net 报
#  "Arguments ... cannot be empty"。
# ---------------------------------------------------------------------
set ic_mem [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_mem]
set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {1} \
] $ic_mem

# 显式确认引脚已按预期生成，早失败早定位
if {[llength [get_bd_intf_pins -quiet ic_mem/S01_AXI]] == 0} {
    error "ic_mem 未生成 S01_AXI 引脚，NUM_SI 配置未生效"
}
if {[llength [get_bd_intf_pins -quiet ic_mem/M00_AXI]] == 0} {
    error "ic_mem 未生成 M00_AXI 引脚，NUM_MI 配置未生效"
}

connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_MM2S] \
                    [get_bd_intf_pins ic_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_S2MM] \
                    [get_bd_intf_pins ic_mem/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_mem/M00_AXI] \
                    [get_bd_intf_pins ps7/S_AXI_HP0]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
               [get_bd_pins ic_mem/ACLK] \
               [get_bd_pins ic_mem/S00_ACLK] \
               [get_bd_pins ic_mem/S01_ACLK] \
               [get_bd_pins ic_mem/M00_ACLK]
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
               [get_bd_pins ic_mem/ARESETN] \
               [get_bd_pins ic_mem/S00_ARESETN] \
               [get_bd_pins ic_mem/S01_ARESETN] \
               [get_bd_pins ic_mem/M00_ARESETN]

puts ">>> 数据通路已连接 (DMA <-> HP0)"

# ---------------------------------------------------------------------
#  8. AXI-Stream 直连
#
#  端口名说明：HLS 2025.2 的 axis 接口名直接用 C 函数里的参数名，
#  即 "src" 和 "dst"（不是常见的 s_axis_video / m_axis_video）。
#  以 sobel_accel/solution1/impl/ip/component.xml 里的 busInterface 为准。
# ---------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins dma0/M_AXIS_MM2S] \
                    [get_bd_intf_pins sobel_0/src]
connect_bd_intf_net [get_bd_intf_pins sobel_0/dst] \
                    [get_bd_intf_pins dma0/S_AXIS_S2MM]

puts ">>> AXI-Stream 已直连 (DMA MM2S -> src / dst -> DMA S2MM)"

# ---------------------------------------------------------------------
#  9. 外部端口：DDR 与 FIXED_IO
# ---------------------------------------------------------------------
make_bd_intf_pins_external [get_bd_intf_pins ps7/DDR]
set_property name DDR [get_bd_intf_ports DDR]

make_bd_intf_pins_external [get_bd_intf_pins ps7/FIXED_IO]
set_property name FIXED_IO [get_bd_intf_ports FIXED_IO]

puts ">>> 外部端口已导出"

# ---------------------------------------------------------------------
#  10. 地址分配
# ---------------------------------------------------------------------
assign_bd_address

# ---------------------------------------------------------------------
#  11. 校验
# ---------------------------------------------------------------------
puts ">>> 校验 BD..."
set vresult [validate_bd_design]
puts $vresult

regenerate_bd_layout
save_bd_design

puts ">>> BD '$BD_NAME' 构建完成"
