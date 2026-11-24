module asy_fifo #(
    parameter      data_width = 16,
    parameter      addr_width = 5
    ) (
    input                         rst_n,
    input                         wr_clk,
    input                         wr_en,
    input      [data_width-1:0]   din,
    input                         rd_clk,
    input                         rd_en,
    output reg                    valid,
    output reg [data_width-1:0]   dout,
    output                        empty,
    output                        full
    );
    localparam  data_depth = 1 << addr_width;

    reg   [addr_width:0]   wr_addr_ptr;
    reg   [addr_width:0]   rd_addr_ptr;
    wire  [addr_width-1:0] wr_addr;
    wire  [addr_width-1:0] rd_addr;

    wire  [addr_width:0]   wr_addr_gray;
    reg   [addr_width:0]   wr_addr_gray_d1;
    reg   [addr_width:0]   wr_addr_gray_d2;
    wire  [addr_width:0]   rd_addr_gray;
    reg   [addr_width:0]   rd_addr_gray_d1;
    reg   [addr_width:0]   rd_addr_gray_d2;

    (* ram_style = "block" *) reg [data_width-1:0] fifo_ram [data_depth-1:0];  // 强制推断成 BRAM

    //==================================================write fifo
    integer i;
    // ------------------------------------------------------------
    // Lab8 修改（相对 Lab3 原版）:
    //   原版在复位时 for 循环清零整个 fifo_ram。仿真没问题, 但综合器
    //   推断不出 BRAM, 摊成触发器阵列 —— 两个 FIFO 一共约 6.6 万个 FF
    //   (实测 76 565 个, 占 72%)。
    //   RAM 内容不需要复位: 指针复位后 empty=1, 没写过的地址不会被读出。
    // ------------------------------------------------------------
    always@(posedge wr_clk) begin
        if(wr_en && (~full)) begin
            fifo_ram[wr_addr] <= din;
        end
    end
    //==================================================read_fifo
    always@(posedge rd_clk or negedge rst_n) begin
        if(rst_n == 1'b0) begin
            dout <= 'h0;
            valid <= 1'b0;
        end else begin
            if(rd_en && (~empty)) begin
                dout <= fifo_ram[rd_addr];
                valid <= 1'b1;
            end else begin
                dout <= 'd0;      // 复位
                valid <= 1'b0;
            end
        end
    end
    assign wr_addr = wr_addr_ptr[addr_width-1-:addr_width];
    assign rd_addr = rd_addr_ptr[addr_width-1-:addr_width];
    //==================================================格雷码同步化
    always @(posedge wr_clk, negedge rst_n)
    begin
        if(!rst_n)
        begin
            rd_addr_gray_d1 <= 'b0;
            rd_addr_gray_d2 <= 'b0;
        end
        else
        begin
            rd_addr_gray_d1 <= rd_addr_gray;
            rd_addr_gray_d2 <= rd_addr_gray_d1;
        end
    end
    always @(posedge wr_clk or negedge rst_n) begin
        if(rst_n == 1'b0)
            wr_addr_ptr <= 'h0;
        else if(wr_en && (~full))
            wr_addr_ptr <= wr_addr_ptr + 1;
        else
            wr_addr_ptr <= wr_addr_ptr;
    end
    //==================================================rd_clk
    always @(posedge rd_clk or negedge rst_n)
    begin
        if(rst_n == 1'b0)
        begin
            wr_addr_gray_d1<=0;
            wr_addr_gray_d2<=0;
        end
        else
        begin
            wr_addr_gray_d1 <= wr_addr_gray;
            wr_addr_gray_d2 <= wr_addr_gray_d1;
        end
    end
    always@(posedge rd_clk or negedge rst_n) begin
        if(rst_n == 1'b0)
            rd_addr_ptr <= 'h0;
        else if(rd_en && (~empty))
            rd_addr_ptr <= rd_addr_ptr + 1;
        else
            rd_addr_ptr <= rd_addr_ptr;
    end

    //================================================== translation gary code
    assign wr_addr_gray = (wr_addr_ptr >> 1) ^ wr_addr_ptr;
    assign rd_addr_gray = (rd_addr_ptr >> 1) ^ rd_addr_ptr;

    assign full = (wr_addr_gray == {~(rd_addr_gray_d2[addr_width-:2]),rd_addr_gray_d2[addr_width-2:0]}) ;
    assign empty = ( rd_addr_gray == wr_addr_gray_d2 );

endmodule
