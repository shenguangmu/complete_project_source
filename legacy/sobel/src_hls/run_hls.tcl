# =====================================================================
#  run_hls.tcl —— Sobel HLS 工程脚本
#
#  功能：建工程 -> C 仿真 -> C 综合 -> 导出 IP
#
#  用法（在项目根目录）：
#
#    【Vitis 2025.2 / 2024.x】
#      vitis-run --mode hls --tcl src_hls/run_hls.tcl
#
#    【Vitis HLS 2023.2 及更早】
#      vitis_hls -f src_hls/run_hls.tcl
#
#  只跑某一步：
#      vitis-run --mode hls --tcl src_hls/run_hls.tcl -- --only csynth
#      vitis_hls -f src_hls/run_hls.tcl --only csynth
#
#  可选参数（在脚本后追加，用 -- 分隔）：
#      --part <器件>     默认 xc7z020clg400-1
#      --clock <ns>      默认 10.0（100 MHz）
#      --only <step>     csim / csynth / export / all（默认 all）
#      --thresh <n>      仿真阈值，默认 0
#      --gain <n>        仿真增益，默认 256
# =====================================================================

# ---------------------------------------------------------------------
#  参数解析
# ---------------------------------------------------------------------
set PART       "xc7z020clg400-1"
set CLOCK_NS   "10.0"
set ONLY       "all"
set TB_THRESH  "0"
set TB_GAIN    "256"

# argv 里可能带 "--"，跳过它
set args [list]
foreach a $argv {
    if {$a ne "--"} { lappend args $a }
}

# 环境变量兜底：vitis-run --mode hls --tcl 不接受额外位置参数，
# 用 (--tcl ... 后面的都会当输入文件)，所以只跑单步时用环境变量指定。
#   SOBEL_HLS_ONLY=csim|csynth|export
if {[info exists ::env(SOBEL_HLS_ONLY)]} {
    set ONLY $::env(SOBEL_HLS_ONLY)
}
if {[info exists ::env(SOBEL_HLS_PART)]} {
    set PART $::env(SOBEL_HLS_PART)
}
if {[info exists ::env(SOBEL_HLS_CLOCK)]} {
    set CLOCK_NS $::env(SOBEL_HLS_CLOCK)
}

for {set i 0} {$i < [llength $args]} {incr i} {
    set k [lindex $args $i]
    switch -- $k {
        --part   { incr i; set PART     [lindex $args $i] }
        --clock  { incr i; set CLOCK_NS [lindex $args $i] }
        --only   { incr i; set ONLY     [lindex $args $i] }
        --thresh { incr i; set TB_THRESH [lindex $args $i] }
        --gain   { incr i; set TB_GAIN  [lindex $args $i] }
        default  { puts "警告: 未知参数 $k，已忽略" }
    }
}

# 在 HLS 里，脚本所在目录 = [pwd]，但用 -f 时 pwd 是调用者的目录。
# 统一以"当前目录"为项目根，并做一次存在性检查。
set PROJ_ROOT [pwd]
set SRC_DIR   "$PROJ_ROOT/src_hls"

if {![file exists "$SRC_DIR/sobel_hls.cpp"]} {
    # 可能是从 src_hls 目录里调用的，退一级
    if {[file exists "../src_hls/sobel_hls.cpp"]} {
        set PROJ_ROOT [file normalize ..]
        set SRC_DIR   "$PROJ_ROOT/src_hls"
    } else {
        puts "错误: 找不到 src_hls/sobel_hls.cpp"
        puts "      请在项目根目录执行本脚本"
        exit 1
    }
}

set VEC_DIR [file normalize "$PROJ_ROOT/sim/vectors"]

puts "====================================================================="
puts "  Sobel HLS 构建"
puts "  项目根   : $PROJ_ROOT"
puts "  源码目录 : $SRC_DIR"
puts "  向量目录 : $VEC_DIR"
puts "  器件     : $PART"
puts "  时钟约束 : ${CLOCK_NS} ns"
puts "  执行步骤 : $ONLY"
puts "====================================================================="

# ---------------------------------------------------------------------
#  1. 建工程
# ---------------------------------------------------------------------
open_project -reset sobel_accel

set_top sobel_accel

add_files -cflags "-I$SRC_DIR" "$SRC_DIR/sobel_hls.cpp"

# 向量目录通过一个生成的头文件注入。
# 为什么不用 -D 宏：路径里的 ":" 和 "/" 在 tcl -> Makefile -> clang 的
# 多层转义中会被吃掉引号，最终展开成非法 token。
# 写进头文件则完全没有转义问题。
set VEC_DIR_UNIX [string map {\\ /} $VEC_DIR]
set CFG_HDR "$SRC_DIR/tb_paths.h"
set fh [open $CFG_HDR w]
puts $fh "/* 由 run_hls.tcl 自动生成，请勿手动编辑 */"
puts $fh "#ifndef TB_PATHS_H"
puts $fh "#define TB_PATHS_H"
puts $fh "#define TB_VEC_DIR_DEFAULT \"$VEC_DIR_UNIX\""
puts $fh "#endif"
close $fh
puts ">>> 已生成 $CFG_HDR"

add_files -tb -cflags "-I$SRC_DIR" "$SRC_DIR/tb_sobel.cpp"

# ---------------------------------------------------------------------
#  建 solution（csim 和 csynth 都需要它）
# ---------------------------------------------------------------------
open_solution -reset "solution1" -flow_target vivado
set_part $PART
create_clock -period $CLOCK_NS -name default

# ---------------------------------------------------------------------
#  2. C 仿真
# ---------------------------------------------------------------------
if {$ONLY eq "all" || $ONLY eq "csim"} {
    puts "\n>>> C 仿真 (csim)"

    # csim 的工作目录是 解决方案/csim/build，所以向量路径必须绝对化
    # （通过生成的 tb_paths.h 在编译期注入）
    if {[catch {
        csim_design -argv "$TB_THRESH $TB_GAIN"
    } err]} {
        puts "\n!!! C 仿真失败:"
        puts $err
        close_project
        exit 1
    }
    puts ">>> C 仿真通过"
}

# ---------------------------------------------------------------------
#  3. C 综合
# ---------------------------------------------------------------------
if {$ONLY eq "all" || $ONLY eq "csynth"} {
    puts "\n>>> C 综合 (csynth)"

    # 小图综合可以显著缩短时间；MAX_WIDTH 决定了行缓存的规模，
    # 这里是真实规格，不做缩减。
    if {[catch {
        csynth_design
    } err]} {
        puts "\n!!! C 综合失败:"
        puts $err
        close_project
        exit 1
    }
    puts ">>> C 综合完成"

    # 把关键指标打出来，方便直接抄进 README
    set rpt "sobel_accel/solution1/syn/report/sobel_accel_csynth.rpt"
    if {[file exists $rpt]} {
        puts "\n----------- 综合报告摘要 -----------"
        set fh [open $rpt r]
        set in_lat 0
        set in_res 0
        set line_no 0
        while {[gets $fh line] >= 0} {
            incr line_no
            # 打印 Latency 与 Utilization 段落
            if {[string match "*Latency*" $line] || [string match "*Utilization*" $line]} {
                set in_lat 1
            }
            if {$in_lat && $line_no < 400} {
                if {[string trim $line] ne ""} { puts $line }
            }
            # 资源表通常在报告后半段，抓 LUT/FF/DSP/BRAM 行
            if {[regexp {(LUT|FF|DSP|BRAM_18K|BRAM_36K)\s+[0-9]} $line]} {
                puts $line
            }
        }
        close $fh
        puts "------------------------------------"
        puts "完整报告: $rpt"
    }
}

# ---------------------------------------------------------------------
#  4. 导出 IP
# ---------------------------------------------------------------------
if {$ONLY eq "all" || $ONLY eq "export"} {
    puts "\n>>> 导出 IP (export_design)"
    if {![file exists "sobel_accel/solution1"]} {
        puts "!!! 还没有 solution1，请先跑 csynth"
        close_project
        exit 1
    }

    if {[catch {
        export_design -format ip_catalog \
                      -description "Sobel Edge Detection Accelerator (AXI4-Stream + AXI4-Lite)" \
                      -vendor "user" \
                      -library "hls" \
                      -version "1.0"
    } err]} {
        puts "\n!!! 导出 IP 失败:"
        puts $err
        close_project
        exit 1
    }

    puts ">>> IP 导出完成"
    puts "    位置: [pwd]/sobel_accel/solution1/impl/ip/"
    puts "    Vivado 里用 read_ip 加载该目录下的 .xci 文件"
}

close_project
puts "\n====================================================================="
puts "  完成"
puts "====================================================================="
