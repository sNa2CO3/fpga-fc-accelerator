# ===============================================================
# Lab8  一键把需要展示的信号加进波形窗口
#
#   用法: 在 Vivado 里跑完仿真之后, 在底部的 Tcl Console 里输入:
#             source D:/VivadoProject/Lab8/scripts/add_waves.tcl
#
#   脚本会:
#     1. 先清空当前波形窗口 (add_wave 是追加, 不清空会越加越多);
#     2. 逐个检查信号是否存在于当前仿真快照里, 找不到就明确报出来;
#     3. 给出最终统计和截图指引。
#
#   !! 如果提示 "找不到 /tb_pl/npu_state", 说明当前跑的是**旧快照**:
#      改过 tb_pl.v 之后必须点工具栏的 Relaunch Simulation (圆形箭头图标),
#      只点 Run All 是不会重新编译 testbench 的。
# ===============================================================

# ---------------- 0) 清空当前波形窗口 ----------------
if {[catch {
    set _waves [get_waves -quiet *]
    if {[llength $_waves] > 0} { remove_wave $_waves }
} _err]} {
    puts "清除旧波形失败: $_err"
}

# ---------------- 1) 检查快照是不是新的 ----------------
set _probe [get_objects -quiet /tb_pl/npu_state]
if {[llength $_probe] == 0} {
    puts "=============================================================="
    puts "!! 找不到 /tb_pl/npu_state"
    puts "!! 当前仿真跑的是**旧快照** —— tb_pl.v 改过之后没有重新编译。"
    puts "!! 请点工具栏的 Relaunch Simulation (圆形箭头图标) 重新仿真,"
    puts "!! 然后再运行本脚本。"
    puts "=============================================================="
    return
}

# ---------------- 2) 信号清单 ----------------
#    按"时钟 -> AXI 输入 -> NPU 内部 -> 打包 -> AXI 输出"的顺序
set sigs {
    /tb_pl/s_axis_aclk
    /tb_pl/fc_clk_use
    /tb_pl/rst_n

    /tb_pl/s_tdata
    /tb_pl/s_tvalid
    /tb_pl/s_tready
    /tb_pl/s_tlast

    /tb_pl/fc_fifo_empty
    /tb_pl/fc_din_ready
    /tb_pl/fc_din_valid

    /tb_pl/npu_state
    /tb_pl/cmd_reg

    /tb_pl/fc_dout
    /tb_pl/fc_dout_vld
    /tb_pl/fc_dout_last
    /tb_pl/fc3_y1
    /tb_pl/fc3_y2

    /tb_pl/pk_vld
    /tb_pl/pk_last
    /tb_pl/pk_dout

    /tb_pl/m_tdata
    /tb_pl/m_tvalid
    /tb_pl/m_tready
    /tb_pl/m_tlast

    /tb_pl/done_o
}

set n_ok 0
set n_miss 0
foreach s $sigs {
    if {[llength [get_objects -quiet $s]] == 0} {
        puts "  MISSING  $s"
        incr n_miss
    } else {
        add_wave $s
        incr n_ok
    }
}

# ---------------- 3) 汇总 ----------------
puts "=============================================================="
puts "Lab8 波形: 已添加 $n_ok 个信号, 缺失 $n_miss 个"
if {$n_miss > 0} {
    puts "有缺失 -> 大概率是旧快照, 请 Relaunch Simulation 后重跑本脚本"
} else {
    puts "报告需要三张图 (详见 docs/04_验证与测试.md 第 6 节):"
    puts "  图1 推理  : 0-16us, s_tvalid 65 拍 -> npu_state 0..8 -> m_tvalid 1 拍 (13.9us)"
    puts "  图2 特征图: 14.2-15.8us, npu_state 1->6->7->8, m_tvalid 21 拍"
    puts "  图3 跨时钟: 19us 之后, fc_clk_use 变 150MHz 仍正确"
}
puts "=============================================================="
