// ===========================================================================
// fc1.v —— 第一层全连接计算模块 (512 -> 128, ReLU + 截位)
//
// Lab6 相对 Lab5 的改动:
//   1. 输出经过**截位**: ReLU 结果 >>> SH1 后取 CUT_W 位, 符号扩展进 8bit 车道;
//   2. 乘法器阵列和加法树**不在本层例化** —— 三层共用一套 64 路 8x8 阵列
//      (Lab6 的 PPT 提示: 8bit 截位后三层都是 8x8 乘法, 且各层使用时机不同,
//       所以阵列可以共用; 本模块只给出操作数、接收加法树的结果);
//   3. 输入 RAM 从 4 行扩到 168 行 (42 个样本 x 4 行), 地址带上样本号;
//   4. 加法树从 Lab5 的 64 输入没变, 但 fc2/fc3 现在也用 64 输入的树,
//      所以三层的延迟下标完全一致。
//
// 流水线延迟链 (与 Lab5 相同的推导):
//     L_RAM=3, L_MULT=3 (8x8), D_TREE=6 ($clog2(64))
//     T_PRE=12, DLY_ACC=12, DLY_BIAS=13, DLY_OUT=15, BIAS_DLY=9
//
// 截位参数 SH1 的推导见 _work/analyze.py:
//     SH = bit_length(该层最大绝对值) - (截位宽度-1)
//     8bit: SH1=10 (PPT 举例一致);  4bit: SH1=14
// ===========================================================================
`timescale 1ns / 1ps

module fc1 #(
    parameter CUT_W = 8,         // 截位宽度: 8 或 4
    parameter SH1   = 10        // 第一层右移位数
) (
    input  wire          clk_i,
    input  wire          rst_n_i,
    input  wire          start_i,
    output wire          done_o,

    // ---- 样本号 (输入 RAM 里 42 个样本的分基地址) ----
    input  wire [5:0]    sample_i,

    // ---- 输入数据 RAM: 168 行 x 1024bit ----
    (* max_fanout = 8 *) output reg [7:0] input_data_addr_o,
    input  wire [1023:0] input_data_i,

    // ---- 权重 RAM: 512 行 x 1024bit ----
    (* max_fanout = 8 *) output reg [8:0] weight_addr_o,
    input  wire [1023:0] weight_i,

    // ---- 偏置 RAM: 128 x 8bit ----
    (* max_fanout = 8 *) output reg [6:0] bias_addr_o,
    input  wire [7:0]    bias_i,

    // ---- 逐通道输出 (截位后的 8bit 车道值) ----
    output reg           fc_output_wren_o,
    output reg  [7:0]    fc_output_data_o,
    output reg  [6:0]    fc_output_addr_o,

    // ---- 共用乘法器阵列的接口 ----
    output wire [511:0]  mul_data1_o,
    output wire [511:0]  mul_data2_o,
    input  wire signed [31:0] sum_i,       // 共用加法树的输出

    // ---- 打包后写进 fc1_out_ram (512bit x 2 行, 每行 64 车道) ----
    output wire          out_ram_we,
    output wire [511:0]  out_ram_dina,
    output wire [0:0]    out_ram_addra
);

    // ======================= 本层参数 ==================================
    localparam OUTPUT_DIM = 128;
    localparam GROUPS     = 8;      // 512 / 64
    localparam LANES      = 64;

    localparam L_RAM  = 3;
    localparam L_MULT = 3;
    localparam D_TREE = 6;

    localparam T_PRE    = L_RAM + L_MULT + D_TREE;   // 12
    localparam DLY_ACC  = T_PRE;                     // 12
    localparam DLY_BIAS = T_PRE + 1;                 // 13
    localparam DLY_OUT  = T_PRE + 3;                 // 15
    localparam BIAS_DLY = L_MULT + D_TREE;           // 9
    localparam RAM_LATENCY = L_RAM;

    // ======================= 输出打包参数 ==============================
    localparam ROW_W     = 512;                      // 64 x 8bit
    localparam RESULT_W  = 8;
    localparam PACK      = ROW_W / RESULT_W;         // 64
    localparam PACK_BITS = $clog2(PACK);             // 6

    // ======================= 循环变量 ==================================
    reg [6:0] out_channel;              // 0 ~ 127
    reg [2:0] group_idx;                // 0 ~ 7

    reg [6:0] out_channel_dly [0:DLY_OUT];
    reg [2:0] group_idx_dly   [0:DLY_OUT];
    reg [7:0] bias_reg        [0:BIAS_DLY];

    reg signed [31:0] accum_reg;
    reg signed [31:0] accumulator;
    wire signed [31:0] final_sum = sum_i;

    reg        running;
    reg        finish_r;
    reg        done_r;
    integer    i;

    reg                    half_addr_r;
    reg [RAM_LATENCY-1:0]  half_dly;
    wire half_sel = half_dly[RAM_LATENCY-1];

    reg signed [31:0] relu_result;

    reg [ROW_W-1:0]     pack_reg;
    reg [PACK_BITS-1:0] pack_cnt;
    reg [0:0]           pack_row;

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
    // 循环计数: group_idx 内层每拍 +1; out_channel 只在 group 回绕时 +1。
    // 结束那一拍计数器回绕到 0, 让延迟链自然排空。
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            group_idx <= 3'd0;
        end else begin
            if (start_i && !running) begin
                group_idx <= 3'd0;
            end else if (running) begin
                group_idx <= (group_idx == GROUPS-1) ? 3'd0 : (group_idx + 1'b1);
            end
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            out_channel <= 7'd0;
        end else begin
            if (start_i && !running) begin
                out_channel <= 7'd0;
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
    // 阶段1: 地址生成 —— 168 行输入 RAM 的地址 = {样本号, 组行号}
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            input_data_addr_o <= 8'd0;
            weight_addr_o     <= 9'd0;
            bias_addr_o       <= 7'd0;
        end else if (running) begin
            input_data_addr_o <= {sample_i, group_idx[2:1]};
            weight_addr_o     <= {out_channel, group_idx[2:1]};
            bias_addr_o       <= out_channel;
        end
    end

    // ===================================================================
    // 半字选择 (与 Lab5 相同): 选择位与地址同源, 再延迟 RAM_LATENCY 拍
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            half_addr_r <= 1'b0;
            half_dly    <= {RAM_LATENCY{1'b0}};
        end else begin
            half_addr_r <= group_idx[0];
            half_dly    <= {half_dly[RAM_LATENCY-2:0], half_addr_r};
        end
    end

    assign mul_data1_o = half_sel ? input_data_i[1023:512] : input_data_i[511:0];
    assign mul_data2_o = half_sel ? weight_i[1023:512]     : weight_i[511:0];

    // ===================================================================
    // 阶段11: 通道累加 (共用加法树的输出直接进来)
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            accum_reg <= 32'd0;
        end else begin
            if (group_idx_dly[DLY_ACC] == 3'd0) begin
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
    //   截位 = 算术右移 SH1 位再取低 CUT_W 位, 符号扩展进 8bit 车道。
    //   ReLU 之后值非负, 算术/逻辑右移等价; 写成 $signed >>> 是为了
    //   和 fc3 (有符号) 保持同一表达式。
    //   截位是**组合逻辑**(纯位选择), 不加流水级, DLY_OUT 不变。
    // ===================================================================
    wire signed [31:0] shifted1 = $signed(relu_result) >>> SH1;

    // trunc1 必须在模块作用域声明 —— generate 块里的 wire 出不了块
    wire [7:0] trunc1;
    generate
        if (CUT_W == 8) begin : TC8
            assign trunc1 = shifted1[7:0];
        end else begin : TCL
            assign trunc1 = {{(8-CUT_W){shifted1[CUT_W-1]}}, shifted1[CUT_W-1:0]};
        end
    endgenerate

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            fc_output_wren_o <= 1'b0;
            fc_output_addr_o <= 7'd0;
            fc_output_data_o <= 8'd0;
        end else begin
            fc_output_wren_o <= (group_idx_dly[DLY_OUT] == GROUPS-1);
            fc_output_addr_o <= out_channel_dly[DLY_OUT];
            fc_output_data_o <= trunc1;
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
    // 输出打包: 128 个 8bit 结果 -> 2 行 x 512bit (每行 64 车道)
    //   通道 c 放进第 c/64 行的第 c%64 个车道; 行满那一拍组合写出去,
    //   done_o 拉高时最后一行已落地。
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

    wire pack_tail  = (pack_cnt == PACK-1);                       // 行满
    wire pack_last  = (fc_output_addr_o == OUTPUT_DIM-1);         // 最后一个通道
    wire pack_write = fc_output_wren_o & (pack_tail | pack_last);

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            pack_reg <= {ROW_W{1'b0}};
            pack_cnt <= {PACK_BITS{1'b0}};
            pack_row <= 1'b0;
        end else if (fc_output_wren_o) begin
            pack_reg <= pack_dina;
            pack_cnt <= (pack_tail | pack_last) ? {PACK_BITS{1'b0}}
                                                : (pack_cnt + 1'b1);
            pack_row <= (pack_tail | pack_last) ? (pack_row + 1'b1) : pack_row;
        end
    end

    assign out_ram_we    = pack_write;
    assign out_ram_dina  = pack_dina;
    assign out_ram_addra = pack_row;

endmodule
