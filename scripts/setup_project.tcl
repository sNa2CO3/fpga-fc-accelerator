set root D:/VivadoProject/Lab8
set prj  $root/Lab8.xpr
if {[file exists $prj]} { open_project $prj } else { create_project Lab8 $root -part xc7z020clg400-1 }
set_property BOARD_PART tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property target_language Verilog [current_project]
set rtl [list \
    $root/Lab8.srcs/sources_1/new/adder_tree.v \
    $root/Lab8.srcs/sources_1/new/mult_array_8.v \
    $root/Lab8.srcs/sources_1/new/asy_fifo.v \
    $root/Lab8.srcs/sources_1/new/fc1.v \
    $root/Lab8.srcs/sources_1/new/fc2.v \
    $root/Lab8.srcs/sources_1/new/fc3.v \
    $root/Lab8.srcs/sources_1/new/fc_top.v \
    $root/Lab8.srcs/sources_1/new/axis_rd_interface.v \
    $root/Lab8.srcs/sources_1/new/axis_wr_interface.v \
    $root/Lab8.srcs/sources_1/new/fc_out_packer.v \
    $root/Lab8.srcs/sources_1/new/pl_fc_top.v ]
add_files -norecurse -fileset sources_1 $rtl
add_files -norecurse -fileset sim_1     $root/Lab8.srcs/sim_1/new/tb_pl.v
add_files -norecurse -fileset constrs_1 $root/Lab8.srcs/constrs_1/new/lab8.xdc
set_property source_mgmt_mode None [current_project]
set_property top pl_fc_top [get_filesets sources_1]
set_property top tb_pl     [get_filesets sim_1]
# 一次完整仿真约 26.5us, 设成 40us 保证 GUI 里 Run 一次就能跑完
# (Vivado 默认只有 1000ns, 波形会停在 1us, 后面全是 0)
set_property -name {xsim.simulate.runtime} -value {40us} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
close_project
puts "=========== LAB8 PROJECT SETUP DONE ==========="
exit 0
