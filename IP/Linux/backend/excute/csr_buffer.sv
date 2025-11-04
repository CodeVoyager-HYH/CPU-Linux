module csr_buffer
  import config_pkg::*;
#(
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush CSR - CONTROLLER
    input logic flush_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // CSR FU is ready - ISSUE_STAGE
    output logic csr_ready_o,
    // CSR instruction is valid - ISSUE_STAGE
    input logic csr_valid_i,
    // CSR buffer result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] csr_result_o,
    // commit the pending CSR OP - TO_BE_COMPLETED
    input logic csr_commit_i,
    // CSR address to write - COMMIT_STAGE
    output logic [11:0] csr_addr_o
);
  // this is a single entry store buffer for the address of the CSR
  // which we are going to need in the commit stage
  struct packed {
    logic [11:0] csr_address;
    logic        valid;
  }
      csr_reg_n, csr_reg_q;

  // control logic, scoreboard signals
  assign csr_result_o = fu_data_i.operand_a;
  assign csr_addr_o   = csr_reg_q.csr_address;

  // write logic
  always_comb begin : write
    csr_reg_n   = csr_reg_q;
    csr_ready_o = 1'b1;
    if ((csr_reg_q.valid || csr_valid_i) && ~csr_commit_i) csr_ready_o = 1'b0;
    if (csr_valid_i) begin
      csr_reg_n.csr_address = fu_data_i.operand_b[11:0];
      csr_reg_n.valid       = 1'b1;
    end
    if (csr_commit_i && ~csr_valid_i) begin
      csr_reg_n.valid = 1'b0;
    end
    if (flush_i) csr_reg_n.valid = 1'b0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      csr_reg_q <= '{default: 0};
    end else begin
      csr_reg_q <= csr_reg_n;
    end
  end

endmodule
