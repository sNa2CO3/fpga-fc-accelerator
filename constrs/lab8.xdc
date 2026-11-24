## Lab8 pl_fc_top constraints
## 两个时钟由 Block Design 的 FCLK_CLK0 提供, 这里给 100 MHz 作为 OOC 约束
create_clock -name s_axis_aclk -period 10.000 [get_ports s_axis_aclk]
create_clock -name fc_clk      -period 10.000 [get_ports fc_clk]
set_clock_groups -asynchronous -group [get_clocks s_axis_aclk] -group [get_clocks fc_clk]
set_false_path -from [get_ports rst_n]
set_clock_uncertainty 0.200 [get_clocks s_axis_aclk]
set_clock_uncertainty 0.200 [get_clocks fc_clk]
