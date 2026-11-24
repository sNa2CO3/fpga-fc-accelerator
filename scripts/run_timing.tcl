set root D:/VivadoProject/Lab8
set out  $root/_work
file mkdir $out
open_project $root/Lab8.xpr
update_compile_order -fileset sources_1

# pl_fc_top 是要放进 Block Design 的 IP, 它的 143 个端口不该映射到物理引脚。
# 单独综合/实现时用 out_of_context 模式, 否则 place_design 会报
# "Number of unplaced IO Ports (143) is greater than number of available sites (125)"。
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS}              -value "-mode out_of_context" -objects [get_runs synth_1]
catch {reset_run synth_1}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH FAILED"; puts [get_property STATUS [get_runs synth_1]]; exit 1 }
open_run synth_1
report_utilization -file $out/synth_util.rpt
close_design
catch {reset_run impl_1}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL FAILED"; puts [get_property STATUS [get_runs impl_1]]; close_project; exit 1 }
open_run impl_1
report_utilization    -file $out/impl_util.rpt
report_timing_summary -delay_type max -max_paths 10 -file $out/timing_summary.rpt
report_timing -delay_type max -sort_by group -max_paths 1 -path_type full_clock_expanded -file $out/critical_path.rpt
report_power -file $out/power.rpt
close_design
close_project
puts "=========== TIMING DONE ==========="
exit 0
