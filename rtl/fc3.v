// ===========================================================================
// fc3.v —— 第三层全连接计算模块 (32 -> 2, 线性有符号 + 截位)
//
// Lab6 相对 Lab5 的关键变化:
//   1. 输入是截位后的 8bit, 与 fc1/fc2 共用 64 路阵列 —— 但本层只有 32 维
//      输入, 所以只占一行的低 32 个车道, 高 32 个车道的**权重在 coe 里补 0**,
//      乘积恒为 0, 加法树求和不受影响 (GROUPS=1, 一次读完);
//   2. 输出也截位 (>>> SH3, 有符号、无激活), 取 CUT_W 位符号扩展进 8bit;
//   3. GROUPS=1 带来一个 Lab5 没有的坑: 写使能条件
//         (group_idx_dly[DLY_OUT] == GROUPS-1) == (dly == 0)
//      在**空闲时也成立** (延迟链排空后就是 0), wren 会常高、每拍输出垃圾。
//      解决: 另跟一条 running 的延迟链, wren 用它门控 —— 只有本层
//      真正 running 的那 16 拍在飞的输出才算数。
//
// 延迟链 (与 fc1/fc2 完全一致): T_PRE=12, DLY_ACC=12, DLY_BIAS=13, DLY_OUT=15
// ===========================================================================
`timescale 1ns / 1ps

module fc3 #(
    parameter CUT_W = 8,
    parameter SH3   = 8
) (
    input  wire          clk_i,
    input  wire          rst_n_i,
    input  wire          start_i,
    output wire          done_o,

    // ---- 输入数据 RAM (即 fc2_out_ram, 单行 512bit, 低 32 车道有效) ----
    (* max_fanout = 8 *) output reg [0:0] input_data_addr_o,
    input  wire [511:0]  input_data_i,

    // ---- 权重 RAM (2 行 x 512bit, 车道 32..63 补 0) ----
    (* max_fanout = 8 *) output reg [0:0] weight_addr_o,
    input  wire [511:0]  weight_i,

    // ---- 逐通道输出 (截位后的 8bit 有符号值) ----
    output reg           fc_output_wren_o,
    output reg  [7:0]    fc_output_data_o,
    output reg  [0:0]    fc_output_addr_o,

    // ---- 共用乘法器阵列的接口 ----
    output wire [511:0]  mul_data1_o,
    output wire [511:0]  mul_data2_o,
    input  wire signed [31:0] sum_i
);

    // ======================= 本层参数 ==================================
    localparam OUTPUT_DIM = 2;
    localparam GROUPS     = 1;      // 32 维一次读完 (64 车道, 高 32 车道补 0)
    localparam LANES      = 64;

    localparam L_RAM  = 3;
    localparam L_MULT = 3;
    localparam D_TREE = 6;

    localparam T_PRE    = L_RAM + L_MULT + D_TREE;   // 12
    localparam DLY_ACC  = T_PRE;                     // 12
    localparam DLY_BIAS = T_PRE + 1;                 // 13
    localparam DLY_OUT  = T_PRE + 3;                 // 15

    // 只有 2 个偏置, 直接写成常数 (fc3.bias.coe = 00111110, 00001100)
    localparam signed [7:0] BIAS_CH0 = 8'sd62;
    localparam signed [7:0] BIAS_CH1 = 8'sd12;

    // ======================= 循环变量 ==================================
    reg [0:0] out_channel;              // 0 ~ 1
    reg [0:0] group_idx;                // 恒 0 (GROUPS=1)

    reg [0:0] out_channel_dly [0:DLY_OUT];
    reg [0:0] group_idx_dly   [0:DLY_OUT];
    reg       running_dly     [0:DLY_OUT];   // GROUPS=1 时的"在飞"标志

    reg signed [31:0] accum_reg;
    reg signed [31:0] accumulator;
    wire signed [31:0] final_sum = sum_i;

    reg        running;
    reg        finish_r;
    reg        done_r;
    integer    i;

    reg signed [31:0] lin_result;       // 第 13 级: 线性层, 恒等寄存

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
    // 循环计数: GROUPS=1, group_idx 恒 0; out_channel 每拍 +1 (0 -> 1 -> 回绕)
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
            out_channel <= 1'b0;
        end else begin
            if (start_i && !running) begin
                out_channel <= 1'b0;
            end else if (running && (group_idx == GROUPS-1)) begin
                out_channel <= out_channel + 1'b1;
            end
        end
    end

    // ===================================================================
    // 延迟链 (含 running 延迟链 —— GROUPS=1 时必须用它门控 wren)
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (i = 0; i <= DLY_OUT; i = i + 1) begin
                out_channel_dly[i] <= 0;
                group_idx_dly[i]   <= 0;
                running_dly[i]     <= 1'b0;
            end
        end else begin
            out_channel_dly[0] <= out_channel;
            group_idx_dly[0]   <= group_idx;
            running_dly[0]     <= running;
            for (i = 1; i <= DLY_OUT; i = i + 1) begin
                out_channel_dly[i] <= out_channel_dly[i-1];
                group_idx_dly[i]   <= group_idx_dly[i-1];
                running_dly[i]     <= running_dly[i-1];
            end
        end
    end

    // ===================================================================
    // 阶段1: 地址 (组号恒 0: 输入永远读第 0 行; 权重行号 = 通道号)
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            input_data_addr_o <= 1'b0;
            weight_addr_o     <= 1'b0;
        end else if (running) begin
            input_data_addr_o <= group_idx;          // 恒 0
            weight_addr_o     <= out_channel;
        end
    end

    assign mul_data1_o = input_data_i;      // 512bit = 64 x 8bit (高 32 车道为 0)
    assign mul_data2_o = weight_i;          // 512bit = 64 x 8bit (高 32 车道权重为 0)

    // ===================================================================
    // 阶段11: 通道累加 (GROUPS=1: 每个通道就一组, 直接赋值)
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
    // 阶段12: 加偏置 (常数, 用该级的通道号选)
    // ===================================================================
    wire signed [7:0] bias_sel = out_channel_dly[DLY_BIAS][0] ? BIAS_CH1 : BIAS_CH0;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            accumulator <= 32'd0;
        end else begin
            accumulator <= accum_reg + {{24{bias_sel[7]}}, bias_sel};
        end
    end

    // ===================================================================
    // 阶段13: 线性层 —— 无激活, 但寄存器保留 (DLY_OUT 靠它凑满 3 级)
    // ===================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) lin_result <= 32'd0;
        else          lin_result <= accumulator;
    end

    // ===================================================================
    // 阶段14: 截位 + 输出
    //   有符号值: 算术右移 (Verilog >>> 对 signed 操作数 = 向下取整,
    //   与 Python 对负数的 >> 语义一致, 模型和 RTL 逐位可比)。
    //   wren 用 running_dly 门控, 见文件头注释。
    // ===================================================================
    wire signed [31:0] shifted3 = lin_result >>> SH3;

    wire [7:0] trunc3;
    generate
        if (CUT_W == 8) begin : TC8
            assign trunc3 = shifted3[7:0];
        end else begin : TCL
            assign trunc3 = {{(8-CUT_W){shifted3[CUT_W-1]}}, shifted3[CUT_W-1:0]};
        end
    endgenerate

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            fc_output_wren_o <= 1'b0;
            fc_output_addr_o <= 1'b0;
            fc_output_data_o <= 8'd0;
        end else begin
            fc_output_wren_o <= running_dly[DLY_OUT]
                              & (group_idx_dly[DLY_OUT] == GROUPS-1);
            fc_output_addr_o <= out_channel_dly[DLY_OUT];
            fc_output_data_o <= trunc3;
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

endmodule
