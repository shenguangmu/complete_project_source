# =====================================================================
#  sobel_io.xdc —— 时序与引脚约束
#
#  Zynq 设计的大部分引脚（DDR、UART、SD 等）由 PS 硬核管理，
#  Block Design 会自动生成对应的约束，本文件只需处理 PL 侧的补充约束。
#
#  ── 如果移植到纯 FPGA 板（Artix-7 / A7-Lite）──
#  那时没有 PS7，时钟和复位要靠外部引脚进，DMA 也要换成别的方案。
#  把下面「Artix-7 移植参考」段取消注释并按实际板子改引脚即可。
# =====================================================================

# ---------------------------------------------------------------------
#  Zynq（默认）：PL 侧时钟由 FCLK_CLK0 提供，已在 BD 内部约束，
#  这里只做一层保险的异步时钟组声明。
# ---------------------------------------------------------------------

# 如果 PS 的 DDR 时钟与 PL 时钟都会进到设计里，声明为异步组避免误报
# （Zynq 上通常不需要，因为 PL 域只有一个时钟）
# set_clock_groups -asynchronous \
#     -group [get_clocks -of_objects [get_pins ps7/inst/FCLK_CLK0]]

# ---------------------------------------------------------------------
#  伪路径：跨时钟域或纯静态信号
# ---------------------------------------------------------------------
# BD 生成的 wrapper 里有若干常量/配置信号，无需时序分析
set_false_path -from [get_ports -quiet DDR_*]
set_false_path -from [get_ports -quiet FIXED_IO_*]


# =====================================================================
#  Artix-7 移植参考（当前设计不使用，保留供参考）
#
#  若要把 Sobel 加速器从 Zynq 挪到纯 FPGA 板（如 A7-Lite / XC7A35T），
#  需要：
#    1. 去掉 PS7，时钟由板载晶振经 MMCM 产生
#    2. 用 AXI DMA 需要 MicroBlaze 软核做控制，或自己写
#       AXI4 主设备 + BRAM 控制器
#    3. 引脚约束按实际板卡改
#
#  下面以 A7-Lite（50 MHz 晶振）为例，仅供参考，引脚号请以板卡原理图为准：
# =====================================================================
#
# # 系统时钟 50 MHz
# set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports sys_clk_p]
# create_clock -period 20.000 -name sys_clk [get_ports sys_clk_p]
#
# # 复位按键（低有效）
# set_property -dict {PACKAGE_PIN T4 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
#
# # UART 调试输出
# set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS33} [get_ports uart_txd]
#
# # 数码管/ LED 状态指示
# set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS33} [get_ports {led[0]}]
