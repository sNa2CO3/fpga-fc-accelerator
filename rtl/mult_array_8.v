// ===========================================================================
// mult_array_8.v —— 第一层乘法器阵列: 8bit x 8bit 有符号, 64 路
//   mult_8 是 mult_gen 生成的 IP (PipeStages = 3)
// ===========================================================================
`timescale 1ns / 1ps

module mult_array_8 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [511:0]  data1,     // 输入数据 64 x 8bit
    input  wire [511:0]  data2,     // 权重     64 x 8bit
    output wire [1023:0] result     // 乘积     64 x 16bit
);
    localparam LANES = 64;
    genvar g;

    generate
        for (g = 0; g < LANES; g = g + 1) begin : GEN_MULT
            mult_8 u_mult_8 (
                .CLK  (clk),
                .A    (data1[8*g +: 8]),
                .B    (data2[8*g +: 8]),
                .SCLR (~rst_n),
                .P    (result[16*g +: 16])
            );
        end
    endgenerate

endmodule
