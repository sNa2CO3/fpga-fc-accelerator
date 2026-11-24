# ===============================================================
# Lab8  从已建好的 Block Design 走到比特流
#
#   generate_target all  ->  make_wrapper  ->  synth  ->  impl  ->  bit
#
#   !! 关键: 工程里 synth_1 之前为了单独报告资源, 被设成了
#      -mode out_of_context。那个属性会一直留在 run 上, 导致
#      BD 顶层被当成没有 IO 的 IP 综合。这里先把它清掉。
#
#   Usage: vivado.bat -mode batch -source scripts/build_bitstream.tcl
# ===============================================================

set root D:/VivadoProject/Lab8
set out  $root/_work
set odir $root/output
file mkdir $odir

open_project $root/Lab8.xpr

# ---- 1) 清掉 OOC 综合选项 ----
catch {reset_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} [get_runs synth_1]}
puts "MORE_OPTIONS = '[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} [get_runs synth_1]]'"

# ---- 2) 生成 BD 输出产物 ----
set bdf [lindex [get_files -quiet *.bd] 0]
if {$bdf eq ""} { puts "ERROR: no .bd in project"; exit 1 }
puts "BD = $bdf"
generate_target all $bdf

# ---- 3) 生成 HDL wrapper 并设为顶层 ----
set wr [make_wrapper -files $bdf -top]
add_files -norecurse -fileset sources_1 $wr
set_property top design_1_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "TOP = [get_property top [get_filesets sources_1]]"

# ---- 4) 综合 ----
catch {reset_run synth_1}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "=========== SYNTH FAILED ==========="
    puts [get_property STATUS [get_runs synth_1]]
    close_project
    exit 1
}
open_run synth_1
report_utilization -file $out/bd_synth_util.rpt
close_design
puts "SYNTH OK"

# ---- 5) 实现 + 比特流 ----
catch {reset_run impl_1}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "=========== IMPL FAILED ==========="
    puts [get_property STATUS [get_runs impl_1]]
    close_project
    exit 1
}
open_run impl_1
report_utilization    -file $out/bd_impl_util.rpt
report_timing_summary -delay_type max -max_paths 10 -file $out/bd_timing.rpt
report_power          -file $out/bd_power.rpt
close_design

# ---- 6) 收集上板文件 ----
set bit [glob -nocomplain $root/Lab8.runs/impl_1/*.bit]
set hwh [glob -nocomplain $root/Lab8.gen/sources_1/bd/design_1/hw_handoff/*.hwh]
if {[llength $bit]} { file copy -force [lindex $bit 0] $odir/lab8.bit ; puts "BIT -> $odir/lab8.bit" }
if {[llength $hwh]} { file copy -force [lindex $hwh 0] $odir/lab8.hwh ; puts "HWH -> $odir/lab8.hwh" }

close_project
puts "=========== BITSTREAM DONE ==========="
exit 0
