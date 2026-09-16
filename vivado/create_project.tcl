# =====================================================================
#  create_project.tcl —— 一键建立手势识别项目的 Vivado 工程
#
#  用法（在 vivado 的 Tcl Console 或命令行）：
#
#     cd <工程根>/vivado
#     vivado -mode batch -source create_project.tcl
#
#  只建工程 + BD，不跑综合（快很多，用于检查 BD 是否合法）：
#     vivado -mode batch -source create_project.tcl -tclargs --synth 0
#
#  可选参数：
#     --part   <器件>    默认 xc7z020clg400-1（Zynq-7020 / PYNQ-Z2）
#     --ip     <IP目录>  默认自动在 HLS 输出里找（含 GUI 流程产出的）
#     --synth  <0|1>     默认 1，是否跑综合与实现
#     --keep             工程目录已存在时不删除，就地复用
#                        （用 GUI 打开过工程后，防止重跑本脚本抹掉改动）
#
#  ─────────────────────────────────────────────────────────────────
#  与 E:\project 的关系
#  ─────────────────────────────────────────────────────────────────
#  本脚本原先是 Sobel 工程的建工程脚本，已改造成手势识别项目的。
#  原 Sobel 工程完整保留在 **`E:\project`**，需要时去那里参考。
#
#  本工程的 BD 是 **bd_video**（视频流水线 + 预处理链）。
#  ⚠ Sobel 的 `bd_sobel` / `sobel_hls` / `sobel_driver` 已从本项目
#    移除 —— 它们的唯一用途是"已验证可回滚的参照"，那个角色现在由
#    `E:\project` 承担。
# =====================================================================

set PROJ_NAME   "gesture_system"
set PART_NAME   "xc7z020clg400-1"
set IP_DIR      ""
set RUN_SYNTH   1
set KEEP_EXIST  0
set BD_NAME     "bd_video"

# ---------------------------------------------------------------------
#  参数解析
# ---------------------------------------------------------------------
set args [list]
foreach a $argv { if {$a ne "--"} { lappend args $a } }
for {set i 0} {$i < [llength $args]} {incr i} {
    switch -- [lindex $args $i] {
        --part  { incr i; set PART_NAME [lindex $args $i] }
        --ip    { incr i; set IP_DIR    [lindex $args $i] }
        --synth { incr i; set RUN_SYNTH [lindex $args $i] }
        --keep  { set KEEP_EXIST 1 }
    }
}

set HERE      [file normalize [file dirname [info script]]]
set PROJ_ROOT [file normalize [file join $HERE ..]]
set PROJ_DIR  [file join $HERE $PROJ_NAME]

puts "====================================================================="
puts " 建立手势识别工程"
puts "   工程名: $PROJ_NAME"
puts "   器件  : $PART_NAME"
puts "   目录  : $PROJ_DIR"
puts "   BD    : $BD_NAME"
puts "====================================================================="

# ---------------------------------------------------------------------
#  0. 清理与创建
# ---------------------------------------------------------------------
if {[file exists $PROJ_DIR]} {
    if {$KEEP_EXIST} {
        puts ">>> 工程目录已存在且指定了 --keep，就地复用"
    } else {
        puts ">>> 删除已存在的工程目录: $PROJ_DIR"
        file delete -force $PROJ_DIR
    }
}

if {![file exists $PROJ_DIR]} {
    file mkdir $PROJ_DIR
}

create_project $PROJ_NAME $PROJ_DIR -part $PART_NAME -force
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------------
#  1. 加入 RTL 源（本项目手写的 Verilog）
#
#  ⚠ 五个都要加：
#      dvp_capture   采集
#      async_fifo    被 dvp_capture 例化（漏了会找不到依赖）
#      sccb_master   SCCB 配置
#      iobuf_wrap    SDA 双向缓冲（BD 不能直接例化 IOBUF 原语）
#      ov5640_regs   寄存器配置表 ROM
# ---------------------------------------------------------------------
set rtl_files [list \
    dvp_capture.v \
    async_fifo.v \
    sccb_master.v \
    iobuf_wrap.v \
    ov5640_regs.v \
]
set n_rtl 0
foreach f $rtl_files {
    set p "$PROJ_ROOT/rtl/$f"
    if {[file exists $p]} {
        add_files -norecurse $p
        incr n_rtl
    } else {
        puts "WARN: 找不到 rtl/$f"
    }
}
puts ">>> 已加入 $n_rtl 个 RTL 源"

# ---------------------------------------------------------------------
#  2. 注册 HLS 导出的 IP 仓库
#
#  说明：export_design -format ip_catalog 产出的是一个 **IP 目录**
#  （含 component.xml / hdl / drivers），不是 .xci 文件。
#  在 Vivado 里的正确导入方式是把它注册为 IP 仓库，而不是 read_ip。
# ---------------------------------------------------------------------
if {$IP_DIR eq ""} {
    # 覆盖两种流程的产物：
    #   命令行（run_gesture.tcl）-> ../gesture_comp/solution*/impl/ip
    #   GUI（Vitis 组件）        -> ../<组件目录>/<work_dir>/hls/impl/ip
    set patterns [list \
        "$PROJ_ROOT/gesture_comp/solution*/impl/ip" \
        "$PROJ_ROOT/gesture_comp/*/impl/ip" \
        "$PROJ_ROOT/src_hls/gesture_comp/solution*/impl/ip" \
        "$PROJ_ROOT/*/*/hls/impl/ip" \
        "$PROJ_ROOT/*/hls/impl/ip" \
        "$PROJ_ROOT/vitis_ws/*/hls/impl/ip" \
        "$PROJ_ROOT/vitis_ws/*/*/hls/impl/ip" \
    ]
    foreach pat $patterns {
        foreach c [lsort -decreasing [glob -nocomplain $pat]] {
            if {[file exists "$c/component.xml"]} {
                set IP_DIR $c
                break
            }
        }
        if {$IP_DIR ne ""} { break }
    }
}

if {$IP_DIR eq "" || ![file exists "$IP_DIR/component.xml"]} {
    puts "\n!!! 找不到 HLS 导出的 IP（component.xml）"
    puts "    请先执行："
    puts "      vitis-run --mode hls --tcl src_hls/run_gesture.tcl"
    puts "    然后用 --ip <目录> 指定 component.xml 所在位置\n"
    close_project
    exit 1
}

puts ">>> 注册 IP 仓库: $IP_DIR"
set_property ip_repo_paths $IP_DIR [current_project]
update_ip_catalog -rebuild

set g_defs [get_ipdefs -quiet *gesture_preproc*]
if {[llength $g_defs] == 0} {
    puts "\n!!! IP 未能被 Vivado 识别，请检查 $IP_DIR"
    close_project
    exit 1
}
puts ">>> 识别到 IP: $g_defs"

# ---------------------------------------------------------------------
#  3. 建 Block Design
#
#  ⚠ bd_video.tcl 需要 IP_REPO 才能例化预处理链。
#    不传的话它会跳过 gesture_preproc + dma_in/dma_out，
#    于是 ic_ctrl 的 M02/M03/M04 与 ic_hp3 悬空，
#    脚本末尾的 AXI 检查会直接报错退出（那个检查是对的）。
# ---------------------------------------------------------------------
set ::IP_REPO $IP_DIR
source "$HERE/$BD_NAME.tcl"

# ---------------------------------------------------------------------
#  4. 顶层 wrapper
#
#  ⚠ 必须删干净已有的 wrapper 再重建 —— 工程里会有两份：
#      .gen/sources_1/bd/<bd>/hdl/    ← 每次 build BD 重新生成（新）
#      .srcs/sources_1/imports/hdl/   ← make_wrapper -import 时拷贝的（旧）
#    综合用的是 imports 那份。不删会导致它带着**上一轮 BD 的端口名**
#    去连新 BD，报 [Synth 8-11365] named port connection ... does not exist。
# ---------------------------------------------------------------------
foreach w [get_files -quiet *${BD_NAME}_wrapper.v] {
    remove_files $w
}
foreach wf [glob -nocomplain \
        "$PROJ_DIR/$PROJ_NAME.srcs/sources_1/imports/hdl/${BD_NAME}_wrapper.v" \
        "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"] {
    file delete -force $wf
}

set bdfile [get_files "${BD_NAME}.bd"]
make_wrapper -files $bdfile -top -import

set wrapper [glob -nocomplain \
    "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"]
if {[llength $wrapper] > 0} {
    add_files -norecurse $wrapper
    set_property top "${BD_NAME}_wrapper" [current_fileset]
    puts ">>> 顶层设为 ${BD_NAME}_wrapper"
} else {
    puts "WARN: 未找到 wrapper"
}

# 约束文件
set xdc "$HERE/constraints/video_io.xdc"
if {[file exists $xdc]} {
    add_files -fileset constrs_1 -norecurse $xdc
    puts ">>> 已加入约束: $xdc"
}

# HDMI 端口的临时豁免（方案 A）
#
# ⚠ 这个文件**不是**引脚约束，它只是把 bitgen 的两条 DRC 降级，
#   让比特流能生成。真正的 HDMI 引脚约束（TMDS）留到方案 B。
#   ⚠ **方案 B 做完后要把它和 hdmi_drc_hook.tcl 一起删掉。**
set xdc_hdmi "$HERE/constraints/video_io_hdmi_tmp.xdc"
if {[file exists $xdc_hdmi]} {
    add_files -fileset constrs_1 -norecurse $xdc_hdmi
    puts ">>> 已加入 HDMI 临时约束: $xdc_hdmi"
    puts "    ⚠ 22 个 hdmi_vid_out_* 端口在比特流里悬空 —— 上板时勿接 HDMI"
}

update_compile_order -fileset sources_1

# ---------------------------------------------------------------------
#  5. 综合与实现（可选）
# ---------------------------------------------------------------------
if {$RUN_SYNTH} {

    # ⚠⚠ 必须在 launch impl 之前设好 pre-hook
    #
    #  HDL 里导出的 22 个 `hdmi_vid_out_*` 端口目前**没有引脚约束**
    #  （TMDS 编码器还没做），bitgen 的 DRC 会拒绝：
    #      [DRC NSTD-1] Unspecified I/O Standard
    #      [DRC UCIO-1] Unconstrained Logical Port
    #      ERROR: [Vivado 12-1345] Error(s) found during DRC. Bitgen not run.
    #
    #  ⚠ Vivado 拦得**对** —— 不能把没指定的端口随便绑到 IO 上。
    #
    #  ⚠ 关键：用 `set_property SEVERITY {Warning}` 在工程里直接设**无效**，
    #    因为 run 是独立进程。报错信息里明确说了要用 **pre-hook**：
    #      "add this command to a .tcl file and add that file as a
    #       pre-hook for write_bitstream step"
    #
    #  pre-hook 的副作用（必须知道）：那 22 个端口在比特流里**悬空**，
    #  **上板时不要接 HDMI 线**。详见 constraints/video_io_hdmi_tmp.xdc。
    #
    #  ⚠⚠ 方案 B（TMDS 编码器）做完后，删掉这个 pre-hook 和
    #     video_io_hdmi_tmp.xdc，启用 video_io.xdc 第四层的真实引脚约束。
    set hook "$HERE/constraints/hdmi_drc_hook.tcl"
    if {[file exists $hook]} {
        set_property STEPS.WRITE_BITSTREAM.TCL.PRE $hook [get_runs impl_1]
        puts ">>> 已设置 write_bitstream pre-hook（HDMI 端口临时豁免）"
    } else {
        puts "WARN: 找不到 $hook —— bitgen 会因 HDMI 端口未约束而失败"
    }

    puts "\n>>> 开始综合..."
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        puts "\n!!! 综合失败"
        close_project
        exit 1
    }
    puts ">>> 综合完成"

    puts "\n>>> 开始实现..."
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        puts "\n!!! 实现失败"
        close_project
        exit 1
    }
    puts ">>> 实现完成"

    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    puts ">>> 时序余量 WNS = $wns ns"

    open_run impl_1
    report_utilization -file "$PROJ_DIR/utilization.rpt"
    puts ">>> 资源报告: $PROJ_DIR/utilization.rpt"
}

# ---------------------------------------------------------------------
#  6. 导出 XSA（给 Vitis / PYNQ 用）
# ---------------------------------------------------------------------
set xsa "$PROJ_DIR/gesture_system.xsa"
if {$RUN_SYNTH} {
    write_hw_platform -fixed -include_bit -force $xsa
    puts ">>> XSA 已导出: $xsa"
} else {
    puts ">>> 跳过了综合，未导出 XSA（加 --synth 1 可导出）"
}

close_project

puts "\n====================================================================="
puts "  完成"
if {$RUN_SYNTH} {
    puts "  下一步："
    puts "    * 上板前必读 docs/硬件采购清单.md §3.3（引脚万用表复核）"
    puts "    * 驱动源码在 sw/，主机自检：bash sw/build_preproc_sim.sh"
}
puts "  Sobel 参照工程在 E:\\project（本项目已不再包含它）"
puts "====================================================================="
