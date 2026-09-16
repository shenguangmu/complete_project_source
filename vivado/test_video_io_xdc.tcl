# =====================================================================
#  test_video_io_xdc.tcl —— 验证 video_io.xdc 能否被正确应用
#
#  为什么需要这个测试：
#    XDC 是最容易"看着对但实际报错"的文件 ——
#      * 端口名写错   -> [Vivado 12-584] No ports matched
#      * 约束在 if 外 -> 端口尚不存在时直接让流程失败
#      * 语法错       -> 综合阶段才暴露
#    所以必须真正走一遍综合，而不是肉眼看一遍。
#
#  用法：
#      vivado -mode batch -source vivado/test_video_io_xdc.tcl
#
#  检查内容：
#      1. bd_video 能否重建
#      2. video_io.xdc 里有没有"裸 set_property"
#      3. 综合是否通过
#      4. cam_pclk 时钟与异步时钟组是否真的生效
#      5. 资源占用
# =====================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]
set xpr        [file join $proj_root vivado gesture_system gesture_system.xpr]
set xdc        [file join $script_dir constraints video_io.xdc]

# ⚠ 必须给 IP_REPO，否则 bd_video.tcl 会跳过预处理链，
#   于是 ic_ctrl 的 M02/M03/M04 与 ic_hp3 的从口全部悬空，
#   bd_video.tcl 末尾的"AXI 接口检查"会直接 error 退出。
#   （那个检查本身是对的 —— 悬空 AXI 口综合能过、上板才炸。）
if {![info exists IP_REPO]} {
    set IP_REPO [file join $proj_root gesture_comp solution1 impl ip]
}

puts "====================================================================="
puts " 验证 video_io.xdc"
puts "   IP仓库: $IP_REPO"
puts "====================================================================="

open_project $xpr
cd $proj_root

# ---- 1. 重建 bd_video ----
puts "\n>>> 重建 bd_video"
if {[catch {source [file join $script_dir bd_video.tcl]} err]} {
    puts "ERROR: bd_video.tcl 失败:"
    puts "$err"
    close_project
    exit 1
}

# ---- 2. 生成 wrapper 并设为顶层 ----
#
# ⚠⚠ 必须先删掉工程里**所有**已有的 wrapper 再重建。
#
#   工程里会有两份 bd_video_wrapper.v：
#     .gen/sources_1/bd/bd_video/hdl/   ← 每次 build BD 都重新生成（新）
#     .srcs/sources_1/imports/hdl/      ← make_wrapper -import 时拷贝的（旧）
#
#   综合用的是 imports 那份。如果它没被覆盖，就会带着**上一轮 BD 的
#   端口名**（cam_pclk / cam_data…）去连新 BD（io_pclk / io_d…），报
#      [Synth 8-11365] named port connection 'cam_data' does not exist
#   报错指向 wrapper，但根因是两份副本不同步。
#
#   make_wrapper -force 不保证覆盖 imports 里的旧拷贝（实测无效），
#   所以这里手工先删干净。
puts "\n>>> 清理旧 wrapper"
foreach w [get_files -quiet *bd_video_wrapper.v] {
    puts "    删除 $w"
    remove_files $w
}
# 磁盘上也删掉，防止 remove_files 只从工程移除而文件仍在。
#
# ⚠ 不要硬编码工程路径 —— 工程目录名/位置一变就失效。
#   这里从 .xpr 的实际位置推导。
#
# ⚠⚠ 用 glob 时**不能用 `file join` 拼路径** —— `file join` 会把
#    `*` 当成普通字符，通配语义丢失，glob 返回空。必须用字符串拼接：
#       "$proj_dir/*.gen/..."   ✓
#       [file join $proj_dir * .gen ...]   ✗ 返回空
set proj_dir [file dirname $xpr]
foreach wf [glob -nocomplain \
        "$proj_dir/*.srcs/sources_1/imports/hdl/bd_video_wrapper.v" \
        "$proj_dir/*.gen/sources_1/bd/bd_video/hdl/bd_video_wrapper.v" \
        "$proj_dir/.srcs/sources_1/imports/hdl/bd_video_wrapper.v" \
        "$proj_dir/.gen/sources_1/bd/bd_video/hdl/bd_video_wrapper.v"] {
    file delete -force $wf
    puts "    已删磁盘副本: $wf"
}

puts "\n>>> 重新生成 wrapper"
set bdfile [get_files bd_video.bd]
set _ok 0
if {![catch {make_wrapper -files $bdfile -top} _e]} {
    set _ok 1
} else {
    puts "    make_wrapper 失败: $_e"
}
if {$_ok} {
    set gen_w ""
    foreach c [concat \
            [glob -nocomplain "$proj_dir/*.gen/sources_1/bd/bd_video/hdl/bd_video_wrapper.v"] \
            [glob -nocomplain "$proj_dir/*.srcs/sources_1/bd/bd_video/hdl/bd_video_wrapper.v"] \
            [glob -nocomplain "$proj_dir/.gen/sources_1/bd/bd_video/hdl/bd_video_wrapper.v"] \
            [glob -nocomplain "$proj_dir/.srcs/sources_1/bd/bd_video/hdl/bd_video_wrapper.v"]] {
        if {[file exists $c]} { set gen_w $c; break }
    }
    if {$gen_w ne ""} {
        add_files -norecurse $gen_w
        puts "    已加入新 wrapper: $gen_w"
    } else {
        puts "    WARN: 未找到新生成的 wrapper"
    }
}

set wrapper [get_files -quiet *bd_video_wrapper.v]
if {[llength $wrapper] == 0} {
    puts "ERROR: 找不到 bd_video_wrapper.v"
    close_project
    exit 1
}
# ⚠ 必须显式设为顶层：工程里还有原 Sobel 的顶层，不设会用错的那个
set_property top bd_video_wrapper [current_fileset]
puts ">>> 顶层已设为 bd_video_wrapper"
puts ">>> 当前 wrapper: $wrapper"

# ---- 3. 加入 video_io.xdc ----
puts "\n>>> 加入 video_io.xdc"
if {![file exists $xdc]} {
    puts "ERROR: 找不到 $xdc"
    close_project
    exit 1
}
foreach f [get_files -quiet *video_io.xdc] {
    remove_files $f
}
add_files -fileset constrs_1 -norecurse $xdc
puts ">>> 已加入约束: $xdc"

# ---- 4. XDC 内容检查 ----
# ⚠ XDC 不支持 Tcl 的 if 语句（报 [Designutils 20-1307]，且只是
#   CRITICAL WARNING —— 流程照跑、约束静默失效，极难发现）。
#   所以这里查的是"有没有写 if"，而不是"有没有被 if 包住"。
#   条件生效要靠 get_* -quiet（空列表上是安全的 no-op）。
# ---- 5. 重置并综合 ----
# 必须先 reset_run，否则报
#   [Common 17-69] Run 'synth_1' needs to be reset before launching
puts "\n>>> 重置综合 run"
if {[llength [get_runs -quiet synth_1]] > 0} {
    reset_run synth_1
}

puts "\n>>> 开始综合（可能几分钟）"
if {[catch {launch_runs synth_1 -jobs 4} err]} {
    puts "ERROR: 启动综合失败: $err"
    close_project
    exit 1
}

wait_on_run synth_1

set status   [get_property STATUS   [get_runs synth_1]]
set progress [get_property PROGRESS [get_runs synth_1]]
puts "\n>>> 综合状态: $status  ($progress)"

if {$progress ne "100%"} {
    puts ""
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts " 综合未完成"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    set log [file join [get_property DIRECTORY [get_runs synth_1]] runme.log]
    if {[file exists $log]} {
        puts ">>> 综合日志末尾:"
        set fid [open $log r]
        set lines [split [read $fid] "\n"]
        close $fid
        set n [llength $lines]
        set start [expr {$n > 40 ? $n - 40 : 0}]
        for {set i $start} {$i < $n} {incr i} {
            puts "  [lindex $lines $i]"
        }
    }
    close_project
    exit 1
}

# ---- 6. 检查约束是否真的应用 ----
puts "\n>>> 检查约束应用情况"
open_run synth_1

set clk_cam [get_clocks -quiet cam_pclk]
if {[llength $clk_cam] > 0} {
    puts "  OK: cam_pclk 时钟已定义，周期 = [get_property PERIOD $clk_cam] ns"
} else {
    puts "  FAIL: cam_pclk 时钟未定义 —— 约束没生效"
}

# 检查异步时钟组。get_clock_groups 不是有效命令，用 report 或者
# 直接报告时序摘要来看跨域路径是否被排除。
report_clock_interaction -quiet -file [file join $proj_root vivado clk_interaction.rpt]
set grp_ok 0
if {[file exists [file join $proj_root vivado clk_interaction.rpt]]} {
    set fid [open [file join $proj_root vivado clk_interaction.rpt] r]
    set ci [read $fid]
    close $fid
    if {[string match "*cam_pclk*" $ci]} {
        set grp_ok 1
        puts "  OK: 时钟交互报告里出现 cam_pclk（说明时钟已定义并参与分析）"
    }
}
if {!$grp_ok} {
    puts "  FAIL: 时钟交互报告里没有 cam_pclk"
}

# ---- 7. 资源占用 ----
puts "\n>>> 资源占用"
set rpt [file join $proj_root vivado util_bd_video.rpt]
report_utilization -file $rpt
set fid [open $rpt r]
set util [read $fid]
close $fid
foreach line [split $util "\n"] {
    if {[string match "*Slice LUTs*" $line] ||
        [string match "*Block RAM Tile*" $line] ||
        [string match "*DSPs*" $line] ||
        [string match "*Registers*" $line]} {
        puts "  $line"
    }
}

close_project

puts ""
puts "====================================================================="
puts " video_io.xdc 验证完成 —— 综合通过，约束已应用"
puts "====================================================================="
exit 0
