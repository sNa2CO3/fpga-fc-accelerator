// ===========================================================================
// fc_out_packer.v —— 把 FC_top 的 8bit 字节流光打包成 64bit 的 AXI-Stream 字
//
//   FC_top 一个字节一个字节地吐 (output_data / vld / last),
//   而 AXI-Stream 是 64bit 的, 所以每 8 个字节拼成一个字。
//
//   字节序: 第 1 个字节放在 word[7:0], 第 8 个放在 word[63:56]
//          —— 与 PS 端按字节读的顺序一致。
//
//   最后一拍: 靠 FC_top 的 output_data_last 标记, 不足 8 字节的高位补 0,
//            同时把 last 一起送给下游 (由 axis_wr_interface 存进 FIFO)。
//
//   背压: 输出寄存器没被取走时 (ready=0) 不再接收新字节, 保证不丢数。
// ===========================================================================
`timescale 1ns / 1ps

module fc_out_packer (
    input  wire        clk_i,
    input  wire        rst_n,

    // ---- 来自 FC_top 的字节流 ----
    input  wire [7:0]  din,
    input  wire        din_vld,
    input  wire        din_last,
    output wire        din_ready,     // 可以接收新字节 (接到 FC_top 的 outfifo_full 的反)

    // ---- 送往 axis_wr_interface ----
    output reg  [63:0] dout,
    output reg         dout_vld,
    output reg         dout_last,
    input  wire        dout_ready     // ~almost_full
);

    reg [63:0] sh;        // 已经攒下的字节
    reg [2:0]  cnt;       // 当前是第几个字节 (0~7)

    wire [63:0] byte_ext  = {56'd0, din};
    wire [63:0] byte_sh   = byte_ext << {cnt, 3'b000};
    wire [63:0] word_next = sh | byte_sh;

    wire out_free = ~dout_vld | dout_ready;
    wire accept   = din_vld & out_free;
    wire flush    = accept & ((cnt == 3'd7) | din_last);

    assign din_ready = out_free;

    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            sh        <= 64'd0;
            cnt       <= 3'd0;
            dout      <= 64'd0;
            dout_vld  <= 1'b0;
            dout_last <= 1'b0;
        end else begin
            if (dout_vld && dout_ready) dout_vld <= 1'b0;

            if (accept) begin
                if (flush) begin
                    dout      <= word_next;
                    dout_vld  <= 1'b1;
                    dout_last <= din_last;
                    sh        <= 64'd0;
                    cnt       <= 3'd0;
                end else begin
                    sh  <= word_next;
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
