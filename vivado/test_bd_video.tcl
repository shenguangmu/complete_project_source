# =====================================================================
#  test_bd_video.tcl —— 在现有工程里构建并验证 bd_video
#
#  用途：不生成比特流，只验证 BD 能否**成功构建 + 通过 validate**。
#        这是无板阶段 BD 能给出的最强证据。
#
#  用法：
#      vivado -mode batch -source vivado/test_bd_video.tcl
# =====================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]
set xpr        [file join $proj_root vivado gesture_system gesture_system.xpr]

# HLS 导出的 IP 仓库：不加它，gesture_preproc 不会被例化，
# BD 就只有显示通路（带宽/资源数据会偏小，看不出真实占用）。
if {![info exists IP_REPO]} {
    set IP_REPO [file join $proj_root gesture_comp solution1 impl ip]
}

puts "====================================================================="
puts " 测试 bd_video 构建"
puts "   工程: $xpr"
puts "   IP仓库: $IP_REPO"
puts "====================================================================="

open_project $xpr

# 让 bd_video.tcl 里的相对路径能找到 rtl/
cd $proj_root

if {[catch {source [file join $script_dir bd_video.tcl]} err]} {
    puts "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts " bd_video.tcl 执行失败："
    puts " $err"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    close_project
    exit 1
}

puts "\n>>> 生成 wrapper"
if {[catch {
    set bdfile [get_files bd_video.bd]
    make_wrapper -files $bdfile -top -import
} err]} {
    puts "WARN: make_wrapper 失败: $err"
}

puts "\n>>> 综合前的最后检查"
set bd [get_files -quiet bd_video.bd]
if {[llength $bd] == 0} {
    puts "ERROR: 找不到 bd_video.bd"
    close_project
    exit 1
}

puts "  bd_video.bd 已生成: $bd"

# 列出 BD 里的 cell，确认关键 IP 都在
set bd_obj [get_bd_designs bd_video]
puts "\n  BD 内的 cell:"
foreach c [get_bd_cells -quiet -of_objects $bd_obj] {
    puts "    [get_property NAME $c]"
}

puts "\n  BD 的地址映射:"
if {[catch {
    foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_cells -quiet ps7]] {
        puts "    [get_property NAME $seg]   "
    }
} err]} {
    puts "    (读取地址段时出错: $err)"
}

puts "\n====================================================================="
puts " 测试完成 —— BD 构建成功"
puts "====================================================================="

close_project
exit 0
