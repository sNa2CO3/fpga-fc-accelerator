# ===============================================================
# Lab8  Create all IP cores
#
#   8 x blk_mem_gen + 1 x mult_gen (8x8)  -- same geometry as Lab6,
#   except fc_input_ram: depth 4 (one sample, written at run time by
#   the data-receive state instead of being preloaded from a .coe).
#
# Usage: vivado.bat -mode batch -source scripts/create_ip.tcl
#
# Keep this file pure ASCII.
# ===============================================================

set root    D:/VivadoProject/Lab8
set ipdir   $root/Lab8.srcs/sources_1/ip
set datadir $root/data

open_project $root/Lab8.xpr
file mkdir $ipdir
set_property target_language Verilog [current_project]

proc make_bram {ipdir name width depth coe} {
    if {[llength [get_ips -quiet $name]] != 0} {
        puts "  $name already exists, skip"
        return
    }
    create_ip -name blk_mem_gen -vendor xilinx.com -library ip \
              -module_name $name -dir $ipdir
    set cfg [list \
        CONFIG.Memory_Type {Single_Port_RAM} \
        CONFIG.Write_Width_A $width \
        CONFIG.Write_Depth_A $depth \
        CONFIG.Read_Width_A  $width \
        CONFIG.Operating_Mode_A {READ_FIRST} \
        CONFIG.Enable_A {Always_Enabled} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {true} \
        CONFIG.Register_PortA_Output_of_Memory_Core {true} \
        CONFIG.Use_RSTA_Pin {true} \
        CONFIG.Output_Reset_Value_A {0} \
    ]
    if {$coe eq ""} {
        lappend cfg CONFIG.Load_Init_File {false}
    } else {
        lappend cfg CONFIG.Load_Init_File {true}
        lappend cfg CONFIG.Coe_File $coe
    }
    set_property -dict $cfg [get_ips $name]
    puts "  created $name  ($width x $depth)"
}

proc make_mult {ipdir name aw bw stages} {
    if {[llength [get_ips -quiet $name]] != 0} {
        puts "  $name already exists, skip"
        return
    }
    create_ip -name mult_gen -vendor xilinx.com -library ip \
              -module_name $name -dir $ipdir
    set_property -dict [list \
        CONFIG.Component_Name $name \
        CONFIG.Multiplier_Construction {Use_Mults} \
        CONFIG.OptGoal {Speed} \
        CONFIG.PortAType {Signed} \
        CONFIG.PortBType {Signed} \
        CONFIG.PortAWidth $aw \
        CONFIG.PortBWidth $bw \
        CONFIG.Use_Custom_Output_Width {false} \
        CONFIG.OutputWidthHigh [expr {$aw + $bw - 1}] \
        CONFIG.OutputWidthLow  {0} \
        CONFIG.PipeStages $stages \
        CONFIG.ClockEnable {false} \
        CONFIG.SyncClear {true} \
    ] [get_ips $name]
    puts "  created $name  (A=$aw B=$bw P=[expr {$aw+$bw}] PipeStages=$stages)"
}

puts "== layer 1 =="
# 注意: 输入 RAM 不再用 coe 预置, 由 S_DATA_RCV 状态从 FIFO 写进去
make_bram $ipdir fc_input_ram     1024    4 ""
make_bram $ipdir fc1_weight_ram   1024  512 "$datadir/fc1.0.weight_128.coe"
make_bram $ipdir fc1_bias_ram        8  128 "$datadir/fc1.0.bias.coe"
make_bram $ipdir fc1_out_ram       512    2 ""

puts "== layer 2 =="
make_bram $ipdir fc2_weight_ram    512   64 "$datadir/fc2.0.weight_64.coe"
make_bram $ipdir fc2_bias_ram        8   32 "$datadir/fc2.0.bias.coe"
make_bram $ipdir fc2_out_ram       512    2 ""

puts "== layer 3 =="
make_bram $ipdir fc3_weight_ram    512    2 "$datadir/fc3.weight_64.coe"

puts "== multipliers =="
make_mult $ipdir mult_8    8  8 3

puts "\n== mult_gen latency =="
foreach m {mult_8} {
    puts [format "  %-9s PipeStages=%s" $m [get_property CONFIG.PipeStages [get_ips $m]]]
}

foreach ip [get_ips] {
    generate_target {Instantiation_Template Simulation} [get_ips $ip]
}
puts "\n== generated targets for [llength [get_ips]] IPs =="

close_project
puts "=========== CREATE IP DONE ==========="
exit 0
