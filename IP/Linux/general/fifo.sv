module fifo#(
    parameter int unsigned DATA_WIDTH = 32, // 数据宽度
    parameter int unsigned DEPTH = 8,       // 队列深度
    parameter type dtype = logic [DATA_WIDTH-1:0] // 数据类型（默认就是逻辑向量）
)  (
    input   logic clk_i,
    input   logic rst_ni,
    input   logic flush_i,

    // 输入端口0（高优先级）
    input   dtype       data_i0, 
    input   logic       push_i0, 

    // 输入端口1（低优先级）
    input   dtype       data_i1, 
    input   logic       push_i1, 

    // 输出端口
    output  dtype       data_o, 
    input   logic       pop_i,  

    // 状态
    output              full_o, 
    output              empty_o,
    output              usage_o 
);

    logic [DATA_WIDTH-1:0] fifo_q [DEPTH-1:0];
    logic [ADDR_DEPTH_VALUE-1:0]  wr_ptr_q, rd_ptr_q;
    logic [ADDR_DEPTH_VALUE:0]    status_cnt_q;

    logic [ADDR_DEPTH_VALUE-1:0]  wr_ptr_n, rd_ptr_n;
    logic [ADDR_DEPTH_VALUE:0]    status_cnt_n;

    // -----------------------------
    // 组合逻辑：计算下一个状态
    // -----------------------------
    always_comb begin : fifo_change
        wr_ptr_n     = wr_ptr_q;
        rd_ptr_n     = rd_ptr_q;
        status_cnt_n = status_cnt_q;

        // 出队
        if (pop_i && !empty_o) begin
            rd_ptr_n     = (rd_ptr_q == DEPTH-1) ? 0 : rd_ptr_q + 1;
            status_cnt_n = status_cnt_q - 1;
        end

        // 入队
        if (push_i0 && push_i1 && (status_cnt_q <= DEPTH-2)) begin
            // 同时写两条
            wr_ptr_n     = (wr_ptr_q + 2 >= DEPTH) ? (wr_ptr_q + 2 - DEPTH) : (wr_ptr_q + 2);
            if (pop_i && !empty_o)
                status_cnt_n = status_cnt_q + 1; // 入2出1
            else
                status_cnt_n = status_cnt_q + 2; // 入2出0
        end else if (push_i0 && (status_cnt_q < DEPTH)) begin
            wr_ptr_n     = (wr_ptr_q == DEPTH-1) ? 0 : wr_ptr_q + 1;
            if (pop_i && !empty_o)
                status_cnt_n = status_cnt_q; // 入1出1
            else
                status_cnt_n = status_cnt_q + 1; // 入1出0
        end else if (push_i1 && (status_cnt_q < DEPTH)) begin
            wr_ptr_n     = (wr_ptr_q == DEPTH-1) ? 0 : wr_ptr_q + 1;
            if (pop_i && !empty_o)
                status_cnt_n = status_cnt_q; 
            else
                status_cnt_n = status_cnt_q + 1;
        end
    end

    // -----------------------------
    // 时序逻辑：状态更新
    // -----------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            wr_ptr_q     <= 0;
            rd_ptr_q     <= 0;
            status_cnt_q <= 0;
        end else if (flush_i) begin
            wr_ptr_q     <= 0;
            rd_ptr_q     <= 0;
            status_cnt_q <= 0;
        end else begin
            wr_ptr_q     <= wr_ptr_n;
            rd_ptr_q     <= rd_ptr_n;
            status_cnt_q <= status_cnt_n;

            // 写数据
            if (push_i0 && push_i1 && (status_cnt_q <= DEPTH-2)) begin
                fifo_q[wr_ptr_q] <= data_i0;
                fifo_q[(wr_ptr_q == DEPTH-1) ? 0 : wr_ptr_q+1] <= data_i1;
            end else if (push_i0 && (status_cnt_q < DEPTH)) begin
                fifo_q[wr_ptr_q] <= data_i0;
            end else if (push_i1 && (status_cnt_q < DEPTH)) begin
                fifo_q[wr_ptr_q] <= data_i1;
            end
        end
    end

    // -----------------------------
    // 输出信号
    // -----------------------------
    assign data_o  = fifo_q[rd_ptr_q];
    assign full_o  = (status_cnt_q == DEPTH);
    assign empty_o = (status_cnt_q == 0);
    assign usage_o = ((status_cnt_q+2) > DEPTH)?1'b1:1'b0;



endmodule
