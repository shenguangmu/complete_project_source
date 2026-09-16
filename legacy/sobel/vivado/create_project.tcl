# =====================================================================
#  create_project.tcl —— 一键建立 Sobel 的 Vivado 工程
#
#  用法（在 vivado 的 Tcl Console 或命令行）：
#
#     cd E:/project/vivado
#     vivado -mode batch -source create_project.tcl
#
#  或者只建工程不跑实现（快很多，用于检查 BD 是否合法）：
#     vivado -mode batch -source create_project.tcl -tclargs --synth 0
#
#  可选参数：
#     --part   <器件>    默认 xc7z020clg400-1（Zynq-7020）
#     --ip     <IP目录>  默认自动在 HLS 输出里找（含 GUI 流程产出的）
#     --synth  <0|1>     默认 1，是否跑综合与实现
#     --keep             工程目录已存在时不删除，就地复用
#                        （用 GUI 打开过工程后，防止重跑本脚本抹掉界面里的改动）
# =====================================================================

set PROJ_NAME   "sobel_system"
set PART_NAME   "xc7z020clg400-1"
set IP_DIR      ""
set RUN_SYNTH   1
set KEEP_EXIST  0

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
set PROJ_ROOT [file normalize "$HERE/.."]
set PROJ_DIR  "$PROJ_ROOT/vivado/$PROJ_NAME"

puts "====================================================================="
puts "  Vivado 工程构建"
puts "  工程根   : $PROJ_ROOT"
puts "  工程目录 : $PROJ_DIR"
puts "  器件     : $PART_NAME"
puts "  跑综合   : $RUN_SYNTH"
puts "  保留已有 : $KEEP_EXIST"
puts "====================================================================="

# ---------------------------------------------------------------------
#  1. 建工程
#
#  已有工程时的两种处理：
#    默认     —— 删掉重建，保证干净（脚本可重复运行）
#    --keep   —— 就地复用。用 GUI 打开过工程、在界面里改过东西之后，
#                重跑本脚本不该把你的改动抹掉，就加这个参数
# ---------------------------------------------------------------------
set proj_xpr "$PROJ_DIR/$PROJ_NAME.xpr"

if {[file exists $proj_xpr] && $KEEP_EXIST} {
    puts ">>> 复用已有工程（--keep）: $proj_xpr"
    open_project $proj_xpr
} else {
    if {[file exists $PROJ_DIR]} {
        puts ">>> 工程目录已存在，先删除: $PROJ_DIR"
        file delete -force $PROJ_DIR
    }
    create_project $PROJ_NAME $PROJ_DIR -part $PART_NAME -force
}

# 常见板卡配件（有就套，没有也不影响）
set board_guess ""
foreach b [list \
        "www.digilentinc.com:pynq-z2:part0:1.0" \
        "www.digilentinc.com:zybo-z7-20:part0:1.0" \
        "em.avnet.com:zed:part0:1.4" \
        "xilinx.com:zc702:part0:1.4"] {
    if {[llength [get_board_parts -quiet $b]] > 0} {
        set board_guess $b
        break
    }
}
if {$board_guess ne ""} {
    set_property BOARD_PART $board_guess [current_project]
    puts ">>> 套用板卡: $board_guess"
} else {
    puts ">>> 未找到匹配的板卡文件，按纯器件配置"
}

# ---------------------------------------------------------------------
#  2. 定位并导入 HLS 导出的 IP
#
#  说明：export_design -format ip_catalog 产出的是一个 **IP 目录**
#  （含 component.xml / hdl / drivers），不是 .xci 文件。
#  在 Vivado 里的正确导入方式是把它注册为 IP 仓库，而不是 read_ip。
# ---------------------------------------------------------------------
if {$IP_DIR eq ""} {
    # 覆盖两条路径的产物：
    #   命令行（run_hls.tcl）   -> ../sobel_accel/solution*/impl/ip
    #   GUI（Vitis 组件）       -> ../<组件目录>/<work_dir>/hls/impl/ip
    #
    # 实测 Vitis 2025.2 GUI 默认布局：
    #   <工程根>/sobel_accel_comp/sobel_accel/hls/impl/ip
    # 组件目录名和工作目录名都能在向导里改，所以用通配而非写死。
    set patterns [list \
        "$PROJ_ROOT/sobel_accel/solution*/impl/ip" \
        "$PROJ_ROOT/src_hls/sobel_accel/solution*/impl/ip" \
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
    puts "      vitis-run --mode hls --tcl src_hls/run_hls.tcl"
    puts "    （或 vitis_hls -f src_hls/run_hls.tcl）"
    puts "    然后用 --ip <目录> 指定 component.xml 所在位置\n"
    close_project
    exit 1
}

puts ">>> 注册 IP 仓库: $IP_DIR"
set_property ip_repo_paths $IP_DIR [current_project]
update_ip_catalog -rebuild

set sobel_defs [get_ipdefs -quiet *sobel_accel*]
if {[llength $sobel_defs] == 0} {
    puts "\n!!! IP 未能被 Vivado 识别，请检查 $IP_DIR"
    close_project
    exit 1
}
puts ">>> 识别到 IP: $sobel_defs"

# ---------------------------------------------------------------------
#  3. 建 Block Design
# ---------------------------------------------------------------------
set BD_NAME "sobel_bd"
source "$HERE/bd_sobel.tcl"

# ---------------------------------------------------------------------
#  4. 顶层 wrapper
# ---------------------------------------------------------------------
set bdfile [get_files "$BD_NAME.bd"]
make_wrapper -files $bdfile -top
set wrapper [glob -nocomplain "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"]
if {[llength $wrapper] > 0} {
    add_files -norecurse $wrapper
    set_property top "${BD_NAME}_wrapper" [current_fileset]
    puts ">>> 顶层设为 ${BD_NAME}_wrapper"
}

# 约束文件
set xdc "$HERE/constraints/sobel_io.xdc"
if {[file exists $xdc]} {
    add_files -fileset constrs_1 -norecurse $xdc
    puts ">>> 已加入约束: $xdc"
}

update_compile_order -fileset sources_1

# ---------------------------------------------------------------------
#  5. 综合与实现（可选）
# ---------------------------------------------------------------------
if {$RUN_SYNTH} {
    puts "\n>>> 开始综合..."
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        puts "\n!!! 综合失败，日志:"
        puts [get_property LOG [get_runs synth_1]]
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

    # 打印时序余量
    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    puts ">>> 时序余量 WNS = $wns ns"

    # 资源占用
    open_run impl_1
    report_utilization -file "$PROJ_DIR/utilization.rpt"
    puts ">>> 资源报告: $PROJ_DIR/utilization.rpt"
}

# ---------------------------------------------------------------------
#  6. 导出 XSA（给 Vitis 建裸机工程用）
# ---------------------------------------------------------------------
set xsa "$PROJ_DIR/sobel_system.xsa"
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
    puts "  下一步：用 Vitis 2025.2 打开 XSA 建裸机工程，加入 sw/ 下的源码"
}
puts "====================================================================="
