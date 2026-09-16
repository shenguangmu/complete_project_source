# write_bitstream 的 pre-hook —— 在 bitgen 前把 HDMI 那两条 DRC 降级
#
# ⚠ 为什么必须用 pre-hook 而不是普通 XDC：
#   Vivado 的 run 是**独立进程**，在工程里 set_property SEVERITY
#   对已在跑的 run 无效。报错信息里明确说了要用 pre-hook。
#
# ⚠ 降级的代价（务必知道）：
#   22 个 hdmi_vid_out_* 端口没有引脚绑定，比特流里它们悬空。
#   **上板时不要接 HDMI 线**。详见 video_io_hdmi_tmp.xdc 的说明。
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
