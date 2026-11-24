// ===========================================================================
// fc2.v —— 第二层全连接计算模块 (128 -> 32, ReLU + 截位)
//
// Lab6 相对 Lab5 的关键变化:
//   1. 输入是**截位后的 8bit** (不再是 32bit 不截位), 所以本层也用 8x8 乘法,
//      与 fc1/fc3 共用同一套 64 路乘法器阵列和加法树;
//   2. 128 维输入分 2 组、每组 64 个 (GROUPS=2), 组号就是 fc1_out_ram 的行号,
//      不需要半字选择;
//   3. 输出截位: ReLU >>> SH2 取 CUT_W 位;
//   4. 打包: 32 个结果放进**一行** 64 车道 (低 32 车道有效, 高 32 车道补 0),
//      给 fc3 当输入 —— fc3 只有 32 维输入, 空车道乘 0 权重, 结果不受影响。
//
// 延迟链: L_RAM=3, L_MULT=3 (8x8), D_TREE=6 -> 与 fc1 完全一致:
//     T_PRE=12, DLY_ACC=12, DLY_BIAS=13, DLY_OUT=15, BIAS_DLY=9
//   (Lab5 里 fc2 用 32x8 乘法器 L_MULT=4; 现在共用 8x8 阵列, 全部统一了)
// ===========================================================================
`timescale 1ns / 1ps

module fc2 #(
    parameter CUT_W = 8,
    parameter SH2   = 9
) (
    input  wire          clk_i,
    input  wire          rst_n_i,
    input  wire          start_i,
    output wire          done_o,

    // ---- 输入数据 RAM (即 fc1_out_ram, 2 行 x 512bit) ----
    (* max_fanout = 8 *) output reg [0:0] input_data_addr_o,
    input  wire [511:0]  input_data_i,

    // ---- 权重 RAM (64 行 x 512bit) ----
    (* max_fanout = 8 *) output reg [5:0] weight_addr_o,
    input  wire [511:0]  weight_i,

    // ---- 偏置 RAM (32 x 8bit) ----
    (* max_fanout = 8 *) output reg [4:0] bias_addr_o,
    input  wire [7:0]    bias_i,

    // ---- 逐通道输出 (截位后的 8bit 车道值) ----
    output reg           fc_output_wren_o,
    output reg  [7:0]    fc_output_data_o,
    output reg  [4:0]    fc_output_addr_o,

    // ---- 共用乘法器阵列的接口 ----
    output wire [511:0]  mul_data1_o,
    output wire [511:0]  mul_data2_o,
    input  wire signed [31:0] sum_i,

    // ---- 打包后写进 fc2_out_ram (单行 512bit, 低 32 车道有效) ----
    output wire          out_ram_we,
    output wire [511:0]  out_ram_dina,
    output wire [0:0]    out_ram_addra
);

    // ======================= 本层参数 ==================================
    localparam INPUT_DIM  = 128;
    localparam OUTPUT_DIM = 32;
    localparam GROUPS     = 2;
    localparam LANES      = 64;

    localparam L_RAM  = 3;
    localparam L_MULT = 3;
    localparam D_TREE = 6;

    localparam T_PRE    = L_RAM + L_MULT + D_TREE;   // 12
    localparam DLY_ACC  = T_PRE;                     // 12
    localparam DLY_BIAS = T_PRE + 1;                 // 13
    localparam DLY_OUT  = T_PRE + 3;                 // 15
    localparam BIAS_DLY = L_MULT + D_TREE;           // 9

    // ======================= 输出打包参数 ==============================
    localparam ROW_W     = 512;
    localparam RESULT_W  = 8;
    localparam PACK      = 64;                       // 一行 64 车道 (只填低 32 个)
    localparam PACK_BITS = $clog2(PACK);

    // ======================= 循环变量 ==================================
    reg [4:0] out_channel;              // 0 ~ 31
    reg [0:0] group_idx;                // 0 ~ 1

    reg [4:0] out_channel_dly [0:DLY_OUT];
    reg [0:0] group_idx_dly   [0:DLY_OUT];
    reg [7:0] bias_reg        [0:BIAS_DLY];

    reg signed [31:0] accum_reg;
    reg signed [31:0] accumulator;
    wire signed [31:0] final_sum = sum_i;

    reg        running;
    reg        finish_r;
    reg        done_r;
    integer    i;

    reg signed [31:0] relu_result;

    reg [ROW_W-1:0]     pack_reg;
    reg [PACK_BITS-1:0] pack_cnt;

    // ===================================================================
    // 运行标志
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            running <= 1'b0;
        end else begin
            if (start_i && !running) begin
                running <= 1'b1;
            end else if ((group_idx == GROUPS-1) && (out_channel == OUTPUT_DIM-1) && running) begin
                running <= 1'b0;
            end
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            finish_r <= 1'b0;
        end else if (start_i && !running) begin
            finish_r <= 1'b0;
        end else if (running &&
                     (group_idx == GROUPS-1) &&
                     (out_channel == OUTPUT_DIM-1)) begin
            finish_r <= 1'b1;
        end
    end

    // ===================================================================
    // 循环计数
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            group_idx <= 1'b0;
        end else begin
            if (start_i && !running) begin
                group_idx <= 1'b0;
            end else if (running) begin
                group_idx <= (group_idx == GROUPS-1) ? 1'b0 : (group_idx + 1'b1);
            end
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            out_channel <= 5'd0;
        end else begin
            if (start_i && !running) begin
                out_channel <= 5'd0;
            end else if (running && (group_idx == GROUPS-1)) begin
                out_channel <= out_channel + 1'b1;
            end
        end
    end

    // ===================================================================
    // 延迟链
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (i = 0; i <= DLY_OUT; i = i + 1) begin
                out_channel_dly[i] <= 0;
                group_idx_dly[i]   <= 0;
            end
        end else begin
            out_channel_dly[0] <= out_channel;
            group_idx_dly[0]   <= group_idx;
            for (i = 1; i <= DLY_OUT; i = i + 1) begin
                out_channel_dly[i] <= out_channel_dly[i-1];
                group_idx_dly[i]   <= group_idx_dly[i-1];
            end
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (i = 0; i <= BIAS_DLY; i = i + 1)
                bias_reg[i] <= 8'd0;
        end else begin
            bias_reg[0] <= bias_i;
            for (i = 1; i <= BIAS_DLY; i = i + 1)
                bias_reg[i] <= bias_reg[i-1];
        end
    end

    // ===================================================================
    // 阶段1: 地址生成 (64 路 x 8bit 正好整行, 组号就是行号)
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            input_data_addr_o <= 1'b0;
            weight_addr_o     <= 6'd0;
            bias_addr_o       <= 5'd0;
        end else if (running) begin
            input_data_addr_o <= group_idx;
            weight_addr_o     <= {out_channel, group_idx};
            bias_addr_o       <= out_channel;
        end
    end

    assign mul_data1_o = input_data_i;      // 512bit = 64 x 8bit
    assign mul_data2_o = weight_i;          // 512bit = 64 x 8bit

    // ===================================================================
    // 阶段11: 通道累加
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            accum_reg <= 32'd0;
        end else begin
            if (group_idx_dly[DLY_ACC] == 1'b0) begin
                accum_reg <= final_sum;
            end else begin
                accum_reg <= accum_reg + final_sum;
            end
        end
    end

    // ===================================================================
    // 阶段12: 加偏置
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            accumulator <= 32'd0;
        end else begin
            accumulator <= accum_reg
                         + {{24{bias_reg[BIAS_DLY][7]}}, bias_reg[BIAS_DLY]};
        end
    end

    // ===================================================================
    // 阶段13: ReLU
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            relu_result <= 32'd0;
        end else begin
            if (accumulator[31]) relu_result <= 32'd0;
            else                 relu_result <= accumulator;
        end
    end

    // ===================================================================
    // 阶段14: 截位 + 输出
    // ===================================================================
    wire signed [31:0] shifted2 = $signed(relu_result) >>> SH2;

    wire [7:0] trunc2;
    generate
        if (CUT_W == 8) begin : TC8
            assign trunc2 = shifted2[7:0];
        end else begin : TCL
            assign trunc2 = {{(8-CUT_W){shifted2[CUT_W-1]}}, shifted2[CUT_W-1:0]};
        end
    endgenerate

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            fc_output_wren_o <= 1'b0;
            fc_output_addr_o <= 5'd0;
            fc_output_data_o <= 8'd0;
        end else begin
            fc_output_wren_o <= (group_idx_dly[DLY_OUT] == GROUPS-1);
            fc_output_addr_o <= out_channel_dly[DLY_OUT];
            fc_output_data_o <= trunc2;
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            done_r <= 1'b0;
        end else begin
            done_r <= finish_r
                    & (group_idx_dly[DLY_OUT] == GROUPS-1)
                    & (out_channel_dly[DLY_OUT] == OUTPUT_DIM-1);
        end
    end
    assign done_o = done_r;

    // ===================================================================
    // 输出打包: 32 个 8bit 结果 -> 单行 512bit
    //   通道 c 放进车道 c; 车道 32..63 恒为 0 (写完后清零 pack_reg,
    //   保证空车道不会带上一个样本的残留值 —— 虽然 fc3 的空车道权重也是 0,
    //   双保险)。
    //   只在最后一个通道 (c==31) 那一拍写出去: pack_tail (cnt==63) 永远
    //   不会到来, 因为只有 32 个结果。
    // ===================================================================
    function [ROW_W-1:0] pack_merge;
        input [ROW_W-1:0]    old;
        input [RESULT_W-1:0] w;
        input integer        idx;
        begin
            pack_merge = old;
            pack_merge[idx*RESULT_W +: RESULT_W] = w;
        end
    endfunction

    wire [ROW_W-1:0] pack_dina = pack_merge(pack_reg, fc_output_data_o, pack_cnt);

    wire pack_last  = (fc_output_addr_o == OUTPUT_DIM-1);
    wire pack_write = fc_output_wren_o & pack_last;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            pack_reg <= {ROW_W{1'b0}};
            pack_cnt <= {PACK_BITS{1'b0}};
        end else if (fc_output_wren_o) begin
            if (pack_last) begin
                pack_reg <= {ROW_W{1'b0}};      // 写完清零, 空车道不留残值
                pack_cnt <= {PACK_BITS{1'b0}};
            end else begin
                pack_reg <= pack_dina;
                pack_cnt <= pack_cnt + 1'b1;
            end
        end
    end

    assign out_ram_we    = pack_write;
    assign out_ram_dina  = pack_dina;
    assign out_ram_addra = 1'b0;

endmodule
