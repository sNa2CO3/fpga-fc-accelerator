// ===========================================================================
// axis_rd_interface.v —— AXI-Stream 从机 -> 异步 FIFO -> FC 时钟域
//
//   s_axis_* (axi 时钟域)  ──►  asy_fifo  ──►  dout / dout_valid / fifo_empty
//                                               (fc_clk 时钟域)
//
// 与 Lab1 参考实现的关系:
//   Lab1 在 fc 侧用了一个 IDLE/FETCH 状态机主动预取。这里更简单也更直接:
//   直接把 FC_top 的 din_ready 当作异步 FIFO 的读使能 —— FC_top 只在需要
//   数据时拉高 din_ready, 读出的数据下一拍以 dout_valid 返回, 与 Lab7 里
//   syn_fifo 的时序完全一致, 所以 FC_top 一行都不用改。
//
// 写侧握手: s_axis_tready = ~full,  wr_en = tvalid & ~full
//
// ---------------------------------------------------------------------------
// 为什么 s_axis_tkeep / s_axis_tlast 只声明不使用:
//   输入协议是定长的 —— 1 个指令字 + 64 个样本字 = 65 拍, 每拍 8 字节全有效。
//     * tkeep 恒为 8'hFF, 不存在"部分字节有效"的拍;
//     * tlast 只在第 65 拍拉高, 而 NPU 自己数满 64 个字就知道包结束了。
//   所以这两个信号在这里没有负载, 综合后会在顶层变成两个"悬空端口"
//   —— 这是预期行为, 不是漏接。课件第 14 页指定的参考实现
//   (Lab1 的 axis_rd_interface.v) 也完全相同: 同样只声明、不使用。
//   详见 docs/01_系统架构.md 第 4.4 节 和 docs/07_答辩问答.md 的 A8。
//
//   注意: 输出侧不能这么做 —— tlast 必须真正产生 (见 axis_wr_interface.v),
//   因为课件第 9/13 页要求写通道在数据结束时置位 tlast。
// ---------------------------------------------------------------------------
// ===========================================================================
`timescale 1ns / 1ps

module axis_rd_interface #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 9          // 深度 512
) (
    input  wire                  rst_n,

    // ---- AXI-Stream 从机 (s_axis_aclk 时钟域) ----
    input  wire                  s_axis_aclk,
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  wire                  s_axis_tlast,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,

    // ---- FC 侧 (fc_clk 时钟域) ----
    input  wire                  fc_clk,
    input  wire                  din_ready,      // 来自 FC_top
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  dout_valid,
    output wire                  fifo_empty,
    output wire                  almost_full
);

    wire full;
    wire empty;
    wire wr_en;

    assign s_axis_tready = ~full;
    assign wr_en         = s_axis_tvalid & ~full;
    assign almost_full   = full;
    assign fifo_empty    = empty;

    asy_fifo #(
        .data_width (DATA_WIDTH),
        .addr_width (ADDR_WIDTH)
    ) u_infifo (
        .rst_n   (rst_n),
        .wr_clk  (s_axis_aclk),
        .wr_en   (wr_en),
        .din     (s_axis_tdata),
        .rd_clk  (fc_clk),
        .rd_en   (din_ready),
        .valid   (dout_valid),
        .dout    (dout),
        .empty   (empty),
        .full    (full)
    );

endmodule
