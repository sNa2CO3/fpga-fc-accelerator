# ===============================================================
# Lab8  Build the Block Design: PS7 + AXI DMA + pl_fc_top
#
#   PS7 M_AXI_GP0 -> ps7_0_axi_periph -> axi_dma_0/S_AXI_LITE
#   PS7 M_AXI_GP0 -> ps7_0_axi_periph -> (DMA M_AXI via HP) ...
#   axi_dma_0/M_AXI_MM2S -> axi_mem_intercon/S00 -> PS7/S_AXI_HP0
#   axi_dma_0/M_AXI_S2MM -> axi_mem_intercon/S01 -> PS7/S_AXI_HP0
#   axi_dma_0/M_AXIS_MM2S -> pl_fc_top_0 s_axis_*
#   pl_fc_top_0 m_axis_*  -> axi_dma_0/S_AXIS_S2MM
#
#   FCLK_CLK0 = 100 MHz, 同时给 axi 域和 fc 域
#
# Usage: vivado.bat -mode batch -source scripts/build_bd.tcl
# 运行后请在 GUI 里打开 design_1 检查连线, 再 Generate Output Products
# 与 Create HDL Wrapper。
# ===============================================================

set root D:/VivadoProject/Lab8
open_project $root/Lab8.xpr

# ---- 关键: 把工作目录切到 ipintegrator 脚本目录 ----
# Vivado 的 scripts/ipintegrator/init.tcl 用**相对路径** source
# (source -notrace replace_bd_cell.tcl), 如果当前目录不是那个目录,
# create_bd_design 就会报 "couldn't read file replace_bd_cell.tcl"。
# 实测: 从 D:/VivadoProject/Lab8 直接跑必失败, cd 过去就正常。

# Block Design 里用 create_bd_cell -type module 引用 RTL 模块时，
# 工程必须处于**自动编译顺序**模式；手动模式会报
# "Module references are not supported in manual compile order mode"。
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

# 工程里如果已经有 .bd, 直接报错要求先清理。
# (不要在脚本里 close_bd_design / remove_files —— 那会提前把 BD
#  子系统拉进半初始化状态, 后面 create_bd_design 就会报
#  "invalid command name bd::utils::is_empty"。)
if {[llength [get_files -quiet *.bd]] > 0} {
    puts "ERROR: project already contains a .bd file, clean it first"
    exit 1
}
create_bd_design "design_1"

# ---------------- PS7 ----------------
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 processing_system7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
             Master "Disable" Slave "Disable"} [get_bd_cells processing_system7_0]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
] [get_bd_cells processing_system7_0]

# ---------------- DMA ----------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {8} \
    CONFIG.c_s2mm_burst_size {8} \
] [get_bd_cells axi_dma_0]

# ---------------- interconnects ----------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ps7_0_axi_periph
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells ps7_0_axi_periph]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_mem_intercon
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_intercon]

# ---------------- our IP ----------------
create_bd_cell -type module -reference pl_fc_top pl_fc_top_0

# ---------------- reset ----------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps7_0_100M
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_100M/ext_reset_in]

# ---------------- clocks / resets ----------------
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
    [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
    [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins ps7_0_axi_periph/aclk] \
    [get_bd_pins axi_mem_intercon/aclk] \
    [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
    [get_bd_pins pl_fc_top_0/s_axis_aclk] \
    [get_bd_pins pl_fc_top_0/fc_clk]

# reset bus (rst type) -- must NOT share a net with clocks,
# otherwise: "Cannot connect pins of incompatible types: clk and rst"
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins ps7_0_axi_periph/aresetn] \
    [get_bd_pins axi_mem_intercon/aresetn] \
    [get_bd_pins pl_fc_top_0/rst_n]

# ---------------- AXI-Lite control path ----------------
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins ps7_0_axi_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# ---------------- memory path ----------------
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
                    [get_bd_intf_pins axi_mem_intercon/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                    [get_bd_intf_pins axi_mem_intercon/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mem_intercon/M00_AXI] \
                    [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

# ---------------- AXI-Stream: DMA -> NPU ----------------
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_tdata]  [get_bd_pins pl_fc_top_0/s_axis_tdata]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_tkeep]  [get_bd_pins pl_fc_top_0/s_axis_tkeep]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_tlast]  [get_bd_pins pl_fc_top_0/s_axis_tlast]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_tvalid] [get_bd_pins pl_fc_top_0/s_axis_tvalid]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_tready] [get_bd_pins pl_fc_top_0/s_axis_tready]

# ---------------- AXI-Stream: NPU -> DMA ----------------
connect_bd_net [get_bd_pins pl_fc_top_0/m_axis_tdata]  [get_bd_pins axi_dma_0/S_AXIS_S2MM_tdata]
connect_bd_net [get_bd_pins pl_fc_top_0/m_axis_tkeep]  [get_bd_pins axi_dma_0/S_AXIS_S2MM_tkeep]
connect_bd_net [get_bd_pins pl_fc_top_0/m_axis_tlast]  [get_bd_pins axi_dma_0/S_AXIS_S2MM_tlast]
connect_bd_net [get_bd_pins pl_fc_top_0/m_axis_tvalid] [get_bd_pins axi_dma_0/S_AXIS_S2MM_tvalid]
connect_bd_net [get_bd_pins pl_fc_top_0/m_axis_tready] [get_bd_pins axi_dma_0/S_AXIS_S2MM_tready]

# ---------------- 地址分配 ----------------
assign_bd_address

validate_bd_design
save_bd_design
puts "=========== BD BUILD DONE ==========="
close_project
exit 0
