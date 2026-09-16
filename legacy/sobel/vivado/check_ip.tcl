# =====================================================================
#  check_ip.tcl —— 快速冒烟测试：确认 HLS IP 能被 Vivado 正确加载
#
#  比 create_project.tcl 快得多（不开综合），用来在跑完整流程前
#  确认 IP 的端口名、VLNV、接口类型都符合预期。
#
#  用法:
#     vivado -mode batch -source vivado/check_ip.tcl
# =====================================================================

set HERE      [file normalize [file dirname [info script]]]
set PROJ_ROOT [file normalize "$HERE/.."]

# HLS 导出的 IP 目录（含 component.xml）。
#
# 两条流程的产物位置都覆盖：
#   命令行 run_hls.tcl   -> ../sobel_accel/solution*/impl/ip
#   GUI（Vitis 组件）    -> ../<组件目录>/<work_dir>/hls/impl/ip  及若干变体
#
# 实测 Vitis 2025.2 GUI 的默认布局是
#   <工程根>/sobel_accel_comp/sobel_accel/hls/impl/ip
# （组件目录名 = 向导里填的 Component name；work_dir 见 vitis-comp.json）
# 但向导里这个值可以改，所以下面用通配而不是写死。
set ip_dir ""
foreach pat [list \
        "$PROJ_ROOT/sobel_accel/solution*/impl/ip" \
        "$PROJ_ROOT/src_hls/sobel_accel/solution*/impl/ip" \
        "$PROJ_ROOT/*/*/hls/impl/ip" \
        "$PROJ_ROOT/*/hls/impl/ip" \
        "$PROJ_ROOT/vitis_ws/*/hls/impl/ip" \
        "$PROJ_ROOT/vitis_ws/*/*/hls/impl/ip" ] {
    foreach c [lsort -decreasing [glob -nocomplain $pat]] {
        if {[file exists "$c/component.xml"]} {
            set ip_dir $c
            break
        }
    }
    if {$ip_dir ne ""} { break }
}

if {$ip_dir eq ""} {
    puts "!!! 找不到 HLS IP（component.xml），请先跑 src_hls/run_hls.tcl"
    exit 1
}

puts "====================================================================="
puts "  IP 冒烟测试"
puts "  IP 目录: $ip_dir"
puts "====================================================================="

# ---- 1. 直接读 component.xml 判读接口（不依赖 Vivado 加载）----
set cxml "$ip_dir/component.xml"
set fh [open $cxml r]
set content [read $fh]
close $fh

# 说明：Tcl 的 regexp 默认 . 不匹配换行，所以不能写
#   {busInterface.*?name="src"}
# 这种跨行模式。busInterface 块里 <spirit:name> 和 <spirit:busType> 分行，
# 于是改成分两步：先切出每个 busInterface 块，再在块内看名字和类型。
set ifaces {}
foreach blk [regexp -all -inline {<spirit:busInterface>.*?</spirit:busInterface>} $content] {
    set nm ""
    set tp ""
    if {[regexp {<spirit:name>([^<]+)</spirit:name>} $blk -> nm2]} { set nm $nm2 }
    if {[regexp {<spirit:busType[^>]*\mname="([^"]+)"} $blk -> tp2]} { set tp $tp2 }
    if {$nm ne ""} { lappend ifaces [list $nm $tp] }
}

set names {}
foreach p $ifaces { lappend names [lindex $p 0] }

set has_src  [expr {[lsearch -exact $names "src"]           >= 0}]
set has_dst  [expr {[lsearch -exact $names "dst"]           >= 0}]
set has_ctrl [expr {[lsearch -exact $names "s_axi_control"] >= 0}]

set vlnv "?"
regexp {<spirit:vendor>([^<]+)</spirit:vendor>}       $content -> vendor
regexp {<spirit:library>([^<]+)</spirit:library>}     $content -> library
regexp {<spirit:name>([^<]+)</spirit:name>}           $content -> name
regexp {<spirit:version>([^<]+)</spirit:version>}     $content -> version
if {[info exists vendor] && [info exists name]} {
    set vlnv "$vendor:$library:$name:$version"
}

puts "\n>>> 接口（来自 component.xml）:"
foreach p $ifaces {
    puts [format "      %-16s (%-6s)" [lindex $p 0] [lindex $p 1]]
}
puts ">>> VLNV                     : $vlnv"

if {!($has_src && $has_dst && $has_ctrl)} {
    puts "\n!!! 接口不完整，BD 连接会失败"
    exit 1
}

# ---- 2. 实际用 Vivado 加载一次，确保 IP 可被识别 ----
puts "\n>>> 用 Vivado 加载 IP ..."
create_project -in_memory -part xc7z020clg400-1

# 把 IP 目录注册成 IP 仓库
set_property ip_repo_paths $ip_dir [current_project]
update_ip_catalog -rebuild

set found [get_ipdefs -quiet *sobel_accel*]
if {[llength $found] == 0} {
    puts "!!! IP 未能被 Vivado 识别"
    exit 1
}
puts ">>> Vivado 识别到: $found"

# ---- 3. 核对寄存器偏移 ----
puts "\n>>> 寄存器偏移:"
set hwdrv [glob -nocomplain "$ip_dir/drivers/*/src/*_hw.h"]
if {[llength $hwdrv] > 0} {
    set fh [open [lindex $hwdrv 0] r]
    while {[gets $fh line] >= 0} {
        if {[regexp {#define\s+(\S*CONTROL_ADDR_(WIDTH|HEIGHT|THRESH|GAIN|AP_CTRL)_DATA)\s+(0x[0-9a-fA-F]+)} $line -> k a v]} {
            puts [format "      %-12s %s" $a $v]
        }
    }
    close $fh
}

puts "\n>>> IP 加载正常，端口名与 bd_sobel.tcl 中的引用一致"
puts "====================================================================="
