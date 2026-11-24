// ===========================================================================
// pl_fc_top.v —— Lab8 系统整合里的 PL 顶层（封成自定义 IP 后放进 Block Design）
//
//   s_axis ─► axis_rd_interface ─► fc_top ─► fc_out_packer ─► axis_wr_interface ─► m_axis
//            (异步FIFO, axi→fc)   (Lab7)    (8b→64b)        (异步FIFO, fc→axi)
//
// 两个时钟域:
//   s_axis_aclk —— AXI-Stream / DMA 时钟域 (BD 里接 FCLK_CLK0)
//   fc_clk      —— NPU 计算时钟域   (BD 里也接 FCLK_CLK0, 但结构上独立,
//                                   改频率只要改这一个脚, 不用动 FC 内部)
//
// 与 Lab7 的差别只有三处:
//   1. FIFO 从 syn_fifo 换成 asy_fifo（跨时钟域）；
//   2. fc_top 多一个 output_data_last，用来标 AXI-Stream 的 tlast；
//   3. 输出多一级 8bit→64bit 打包。
//   三层计算、状态机、特征图回读逻辑一律不动。
// ===========================================================================
`timescale 1ns / 1ps

module pl_fc_top #(
    parameter SH1 = 10,
    parameter SH2 = 9,
    parameter SH3 = 8
) (
    input  wire        rst_n,

    // ---- AXI-Stream 从机（指令 + 样本）----
    input  wire        s_axis_aclk,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,

    // ---- AXI-Stream 主机（结果 / 特征图）----
    input  wire        m_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,

    // ---- NPU 计算时钟 ----
    input  wire        fc_clk,

    output wire        done_o
);

    // ======================= 输入侧 ====================================
    wire [63:0] fc_din;
    wire        fc_din_valid;
    wire        fc_din_ready;
    wire        fc_fifo_empty;
    wire        in_almost_full;

    axis_rd_interface #(
        .DATA_WIDTH(64),
        .ADDR_WIDTH(9)
    ) u_axis_rd (
        .rst_n         (rst_n),
        .s_axis_aclk   (s_axis_aclk),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tkeep  (s_axis_tkeep),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .fc_clk        (fc_clk),
        .din_ready     (fc_din_ready),
        .dout          (fc_din),
        .dout_valid    (fc_din_valid),
        .fifo_empty    (fc_fifo_empty),
        .almost_full   (in_almost_full)
    );

    // ======================= NPU =======================================
    wire [7:0] fc_dout;
    wire       fc_dout_vld;
    wire       fc_dout_last;
    wire       fc_out_full;

    fc_top #(
        .SH1(SH1), .SH2(SH2), .SH3(SH3)
    ) u_fc_top (
        .clk_i            (fc_clk),
        .rst_n            (rst_n),
        .din              (fc_din),
        .din_valid        (fc_din_valid),
        .din_ready        (fc_din_ready),
        .fifo_empty       (fc_fifo_empty),
        .output_data      (fc_dout),
        .output_data_vld  (fc_dout_vld),
        .output_data_last (fc_dout_last),
        .fifo_wren        (),
        .outfifo_full     (fc_out_full),
        .done_o           (done_o)
    );

    // ======================= 输出侧 ====================================
    wire [63:0] pk_dout;
    wire        pk_vld;
    wire        pk_last;
    wire        pk_ready;        // packer 能接收新字节
    wire        out_almost_full;

    fc_out_packer u_packer (
        .clk_i      (fc_clk),
        .rst_n      (rst_n),
        .din        (fc_dout),
        .din_vld    (fc_dout_vld),
        .din_last   (fc_dout_last),
        .din_ready  (pk_ready),
        .dout       (pk_dout),
        .dout_vld   (pk_vld),
        .dout_last  (pk_last),
        .dout_ready (~out_almost_full)
    );

    assign fc_out_full = ~pk_ready;

    axis_wr_interface #(
        .DATA_WIDTH(64),
        .ADDR_WIDTH(9)
    ) u_axis_wr (
        .rst_n         (rst_n),
        .fc_clk        (fc_clk),
        .din           (pk_dout),
        .din_vld       (pk_vld),
        .din_last      (pk_last),
        .almost_full   (out_almost_full),
        .s_axis_aclk   (s_axis_aclk),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tkeep  (m_axis_tkeep),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tvalid (m_axis_tvalid)
    );

endmodule
