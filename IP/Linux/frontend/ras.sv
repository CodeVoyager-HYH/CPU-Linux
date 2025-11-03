module ras #(
    parameter type ras_t = logic,
    parameter int unsigned DEPTH = 2
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Branch prediction flush request - zero
    input logic flush_bp_i,
    // Push address in RAS - FRONTEND
    input logic push_i,
    // Pop address from RAS - FRONTEND
    input logic pop_i,
    // Data to be pushed - FRONTEND
    input logic [config_pkg::VLEN-1:0] data_i,
    // Popped data - FRONTEND
    output ras_t data_o
);

  ras_t [DEPTH-1:0] stack_d, stack_q;

  assign data_o = stack_q[0];

  always_comb begin
    stack_d = stack_q;

    // push on the stack
    if (push_i) begin
      stack_d[0].ra = data_i;
      // mark the new return address as valid
      stack_d[0].valid = 1'b1;
      stack_d[DEPTH-1:1] = stack_q[DEPTH-2:0];
    end

    if (pop_i) begin
      stack_d[DEPTH-2:0] = stack_q[DEPTH-1:1];
      // we popped the value so invalidate the end of the stack
      stack_d[DEPTH-1].valid = 1'b0;
      stack_d[DEPTH-1].ra = 'b0;
    end
    // leave everything untouched and just push the latest value to the
    // top of the stack
    if (pop_i && push_i) begin
      stack_d = stack_q;
      stack_d[0].ra = data_i;
      stack_d[0].valid = 1'b1;
    end

    if (flush_bp_i) begin
      stack_d = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      stack_q <= '0;
    end else begin
      stack_q <= stack_d;
    end
  end
endmodule
