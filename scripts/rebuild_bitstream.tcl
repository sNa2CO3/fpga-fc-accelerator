# ===============================================================
# Lab8  重新生成比特流 (修正 HP0 端口频率)
#
#   !! 结论: PCW_S_AXI_HP0_FREQMHZ 是**只读的派生参数**, set_property
#      改不动它 (改前改后都打印 10), 重出的比特流时序/资源也与原来完全相同
#      (WNS +0.224, 63274 端点)。所以它不是 DMA 慢的原因, 这条路是死胡同。
#
#   本脚本保留下来只作为"重出比特流"的模板 (例如以后改了 RTL 要重新出流)。
#   产物会覆盖 output/lab8.bit —— 已知可用的版本备份在 output/lab8_125_good.*
#
#   用法 (必须在 GUI 模式, batch 模式建/开 BD 会报 xgui 初始化失败):
#       vivado.bat -mode gui -source scripts/rebuild_bitstream.tcl
#
#   产物: output/lab8.bit / output/lab8.hwh
#         (已知可用的 125MHz 版本已备份为 output/lab8_125_good.*)
# ===============================================================

set root D:/VivadoProject/Lab8
set out  $root/_work
set odir $root/output
file mkdir $odir

open_project $root/Lab8.xpr

# ---- 1) 修正 PS7 的 HP0 端口频率 ----
open_bd_design [get_files design_1.bd]
puts "BEFORE: FCLK0 = [get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ [get_bd_cells processing_system7_0]] / HP0 = [get_property CONFIG.PCW_S_AXI_HP0_FREQMHZ [get_bd_cells processing_system7_0]]"
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {125} \
    CONFIG.PCW_S_AXI_HP0_FREQMHZ {125} \
] [get_bd_cells processing_system7_0]
puts "AFTER : FCLK0 = [get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ [get_bd_cells processing_system7_0]] / HP0 = [get_property CONFIG.PCW_S_AXI_HP0_FREQMHZ [get_bd_cells processing_system7_0]]"
validate_bd_design
save_bd_design
close_bd_design [current_bd_design]
generate_target all [get_files design_1.bd]

# ---- 2) 清掉 OOC 选项 (否则 write_bitstream 报 DRC HDOOC-3) ----
catch {reset_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} [get_runs synth_1]}
puts "MORE_OPTIONS = '[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} [get_runs synth_1]]'"

# ---- 3) 重新综合 / 实现 / 出比特流 ----
catch {reset_run synth_1}
catch {reset_run impl_1}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "SYNTH FAILED"; puts [get_property STATUS [get_runs synth_1]]; close_project; exit 1
}
puts "SYNTH OK"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "IMPL FAILED"; puts [get_property STATUS [get_runs impl_1]]; close_project; exit 1
}
open_run impl_1
report_utilization    -file $out/hp125_impl_util.rpt
report_timing_summary -delay_type max -max_paths 10 -file $out/hp125_timing.rpt
report_power          -file $out/hp125_power.rpt
close_design

set bit [glob -nocomplain $root/Lab8.runs/impl_1/*.bit]
set hwh [glob -nocomplain $root/Lab8.gen/sources_1/bd/design_1/hw_handoff/*.hwh]
if {[llength $bit]} { file copy -force [lindex $bit 0] $odir/lab8.bit ; puts "BIT -> $odir/lab8.bit" }
if {[llength $hwh]} { file copy -force [lindex $hwh 0] $odir/lab8.hwh ; puts "HWH -> $odir/lab8.hwh" }

close_project
puts "=========== HP125 BUILD DONE ==========="
exit 0
