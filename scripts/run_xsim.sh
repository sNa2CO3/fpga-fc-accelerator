#!/bin/bash
set -e
RTL=${1:?usage: run_xsim.sh <RTL dir> <run dir>}
RUN=${2:?usage: run_xsim.sh <RTL dir> <run dir>}
ROOT=D:/VivadoProject/Lab8
VBIN=E:/Xilinx/Vivado/2022.1/bin
IP=$ROOT/Lab8.srcs/sources_1/ip
TB=$ROOT/Lab8.srcs/sim_1/new
RTL=$(cd "$RTL" && pwd)
mkdir -p "$RUN"; cd "$RUN"
MIFS="fc1_weight_ram fc1_bias_ram fc2_weight_ram fc2_bias_ram fc3_weight_ram"
for m in $MIFS; do
  if [ -f "$ROOT/Lab8.ip_user_files/mem_init_files/$m.mif" ]; then
    cp -f "$ROOT/Lab8.ip_user_files/mem_init_files/$m.mif" .
  else
    cp -f "$IP/$m/$m.mif" .
  fi
done
rm -rf xsim.dir xvlog.log xvhdl.log xsim.log elaborate.log
BRAM_SRC=""
for m in $MIFS fc_input_ram fc1_out_ram fc2_out_ram; do BRAM_SRC="$BRAM_SRC $IP/$m/sim/$m.v"; done
"$VBIN/xvlog.bat" $BRAM_SRC \
  "$RTL/adder_tree.v" "$RTL/mult_array_8.v" "$RTL/asy_fifo.v" \
  "$RTL/fc1.v" "$RTL/fc2.v" "$RTL/fc3.v" "$RTL/fc_top.v" \
  "$RTL/axis_rd_interface.v" "$RTL/axis_wr_interface.v" \
  "$RTL/fc_out_packer.v" "$RTL/pl_fc_top.v" \
  "$TB/tb_pl.v"
"$VBIN/xvhdl.bat" "$IP/mult_8/sim/mult_8.vhd"
"$VBIN/xelab.bat" --incr --debug typical --relax \
  -L work -L blk_mem_gen_v8_4_5 -L mult_gen_v12_0_18 \
  -L unisims_ver -L unimacro_ver -L secureip -L xpm \
  tb_pl -s tb_pl_sim
"$VBIN/xsim.bat" -log xsim.log -runall tb_pl_sim
echo "== simulation done"
