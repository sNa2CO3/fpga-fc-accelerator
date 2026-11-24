// ===========================================================================
// axis_wr_interface.v —— FC 时钟域 -> 异步 FIFO -> AXI-Stream 主机
//
//   din / din_vld / din_last (fc_clk) ──► asy_fifo ──► m_axis_*
//                                          (axi 时钟域)
//
// FIFO 存的是 {last, data} 共 65 bit —— 把 tlast 和数一起跨时钟域，
// 这样 AXI 侧不需要再猜"哪一拍是最后一拍"。
//
// 读出用"预取寄存器"把标准 FIFO（读延迟 1 拍）变成 first-word-fall-through:
//   rd_en = ~empty & (~ov | m_axis_tready)
//   下一拍把 dout 锁进 od, ov=1; 被 tready 取走时 ov=0。
// 这样稳态是 1 beat/cycle。
// ===========================================================================
`timescale 1ns / 1ps

module axis_wr_interface #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 9
) (
    input  wire                  rst_n,

    // ---- FC 侧 (fc_clk 时钟域) ----
    input  wire                  fc_clk,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  din_vld,
    input  wire                  din_last,
    output wire                  almost_full,

    // ---- AXI-Stream 主机 (s_axis_aclk 时钟域) ----
    input  wire                  s_axis_aclk,
    input  wire                  m_axis_tready,
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire                  m_axis_tlast,
    output wire                  m_axis_tvalid
);

    localparam FW = DATA_WIDTH + 1;

    wire          full;
    wire          empty;
    wire          wr_en;
    wire          rd_en;
    wire          fvalid;
    wire [FW-1:0] fdout;

    reg  [FW-1:0] od;
    reg           ov;

    assign almost_full = full;

    assign wr_en = din_vld & ~full;

    asy_fifo #(
        .data_width (FW),
        .addr_width (ADDR_WIDTH)
    ) u_outfifo (
        .rst_n   (rst_n),
        .wr_clk  (fc_clk),
        .wr_en   (wr_en),
        .din     ({din_last, din}),
        .rd_clk  (s_axis_aclk),
        .rd_en   (rd_en),
        .valid   (fvalid),
        .dout    (fdout),
        .empty   (empty),
        .full    (full)
    );

    // 预取: 当前拍的数被取走的同时就去读下一个
    assign rd_en = ~empty & (~ov | m_axis_tready);

    always @(posedge s_axis_aclk or negedge rst_n) begin
        if (!rst_n) begin
            od <= {FW{1'b0}};
            ov <= 1'b0;
        end else begin
            if (ov && m_axis_tready) ov <= 1'b0;
            if (fvalid) begin
                od <= fdout;
                ov <= 1'b1;
            end
        end
    end

    assign m_axis_tvalid = ov;
    assign m_axis_tdata  = od[DATA_WIDTH-1:0];
    assign m_axis_tlast  = od[FW-1];
    assign m_axis_tkeep  = {DATA_WIDTH/8{ov}};

endmodule
