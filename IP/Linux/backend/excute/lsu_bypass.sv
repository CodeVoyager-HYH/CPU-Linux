module lsu_bypass
  import config_pkg::*;
#(
    parameter type lsu_ctrl_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic flush_i,

    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input lsu_ctrl_t lsu_req_i,   // 新的LSU请求
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      lsu_req_valid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      pop_ld_i,    // LSU load操作完成，弹出一个load请求
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      pop_st_i,    // LSU store 操作完成，弹出一个 store 请求

    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output lsu_ctrl_t lsu_ctrl_o, // 当前送往 LSU 执行的请求
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic      ready_o     // 当 FIFO 为空时为 1，表示 LSU 可以接收新请求
);

  lsu_ctrl_t [1:0] mem_n, mem_q;
  logic read_pointer_n, read_pointer_q;
  logic write_pointer_n, write_pointer_q;
  logic [1:0] status_cnt_n, status_cnt_q;

  logic empty;
  assign empty   = (status_cnt_q == 0);
  assign ready_o = empty;

  always_comb begin
    automatic logic [1:0] status_cnt;
    automatic logic write_pointer;
    automatic logic read_pointer;

    status_cnt = status_cnt_q;
    write_pointer = write_pointer_q;
    read_pointer = read_pointer_q;

    mem_n = mem_q;
    // we've got a valid LSU request
    if (lsu_req_valid_i) begin
      mem_n[write_pointer_q] = lsu_req_i;
      write_pointer++;
      status_cnt++;
    end

    if (pop_ld_i) begin
      // invalidate the result
      mem_n[read_pointer_q].valid = 1'b0;
      read_pointer++;
      status_cnt--;
    end

    if (pop_st_i) begin
      // invalidate the result
      mem_n[read_pointer_q].valid = 1'b0;
      read_pointer++;
      status_cnt--;
    end

    if (pop_st_i && pop_ld_i) mem_n = '0;

    if (flush_i) begin
      status_cnt = '0;
      write_pointer = '0;
      read_pointer = '0;
      mem_n = '0;
    end
    // default assignments
    read_pointer_n  = read_pointer;
    write_pointer_n = write_pointer;
    status_cnt_n    = status_cnt;
  end

  // output assignment
  always_comb begin : output_assignments
    if (empty) begin
      lsu_ctrl_o = lsu_req_i;
    end else begin
      lsu_ctrl_o = mem_q[read_pointer_q];
    end
  end

  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mem_q           <= '0;
      status_cnt_q    <= '0;
      write_pointer_q <= '0;
      read_pointer_q  <= '0;
    end else begin
      mem_q           <= mem_n;
      status_cnt_q    <= status_cnt_n;
      write_pointer_q <= write_pointer_n;
      read_pointer_q  <= read_pointer_n;
    end
  end
endmodule