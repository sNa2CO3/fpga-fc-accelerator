module syn_fifo #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 5, // depth

    parameter remain_num = 'd6
    ) (
    input                       clk ,
    input                       rst_n ,

    input                       rd_en ,
    output reg  [DATA_WIDTH-1:0] rd_data ,
    output reg                  valid,

    input                       wr_en ,
    input       [DATA_WIDTH-1:0] wr_data ,

    output                      full,
    output                      near_full,
    output                      empty
    );

    wire [ADDR_WIDTH-1:0] rd_addr ;
    wire [ADDR_WIDTH-1:0] wr_addr ;
    reg  [ADDR_WIDTH:0]   rd_addr_ptr ;
    reg  [ADDR_WIDTH:0]   wr_addr_ptr ;

    assign rd_addr = rd_addr_ptr[ADDR_WIDTH-1:0];
    assign wr_addr = wr_addr_ptr[ADDR_WIDTH-1:0];

    reg [DATA_WIDTH-1:0] fifo_mem [ {ADDR_WIDTH{1'b1}}:0];
    integer i;
    //*****************************************
    // write fifo data
    //*****************************************
    always @(posedge clk)
    begin
        // ------------------------------------------------------------
        // Lab7 修改（相对 Lab3 原版）:
        //   原版在复位时用 for 循环把整块 fifo_mem 清零。这个写法在
        //   仿真里没问题, 但综合器**无法把它推断成 BRAM**, 只能摊成
        //   触发器阵列 —— 本工程两个 FIFO 一起会多出约 3.6 万个 FF
        //   (实测 46 893 个, 占 44%)。
        //
        //   RAM 的内容本来就不需要复位: 指针复位后 empty=1, 未被写过
        //   的地址永远不会被读出来。去掉清零后 Vivado 可以推断成
        //   RAMB36, 触发器回落到 6 千多。
        // ------------------------------------------------------------
        if (wr_en && (~full))
        begin
            fifo_mem[wr_addr] <= wr_data;
        end
    end
    //*****************************************
    // read fifo data
    //*****************************************
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            rd_data <= {DATA_WIDTH{1'b0}};
            valid <= 1'b0;
        end
        else
        begin
            if (rd_en && (~empty))
            begin
                rd_data <= fifo_mem[rd_addr];
                valid <= 1'b1;
            end
            else
            begin
                rd_data <= rd_data;
                valid <= 1'b0;
            end
        end
    end
    //*****************************************
    // write addr control
    //*****************************************
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            wr_addr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        else
        begin
            if (wr_en && (~full))
                wr_addr_ptr <= wr_addr_ptr + 1'b1;
            else
                wr_addr_ptr <= wr_addr_ptr;
        end
    end
    //*****************************************
    // read addr control
    //*****************************************
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            rd_addr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        else
        begin
            if (rd_en && (~empty))
                rd_addr_ptr <= rd_addr_ptr + 1'b1;
            else
                rd_addr_ptr <= rd_addr_ptr;
        end
    end
    //*****************************************
    // full and empty judgement
    //*****************************************
    assign full = ((rd_addr == wr_addr) && (rd_addr_ptr[ADDR_WIDTH] != wr_addr_ptr[ADDR_WIDTH]));
    assign near_full = ((rd_addr + remain_num) > wr_addr) && (rd_addr_ptr[ADDR_WIDTH] != wr_addr_ptr[ADDR_WIDTH]);

    assign empty = (rd_addr_ptr == wr_addr_ptr);
endmodule
