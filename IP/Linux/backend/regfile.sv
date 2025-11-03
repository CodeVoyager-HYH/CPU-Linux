module regfile(
    // clock and reset
    input  logic clk_i,
    input  logic rst_ni,
    // read port
    input  logic [4:0]                      rs1_idx_i,
    input  logic [4:0]                      rs2_idx_i,
    output logic [config_pkg::XLEN-1: 0]    rs1_o,
    output logic [config_pkg::XLEN-1: 0]    rs2_o,

    // write port
    input  logic [config_pkg::XLEN-1: 0]    rd_i,
    input  logic [4:0]                      rd_idx_i,
    input  logic                            we_i
);
  logic [config_pkg::XLEN-1:0] regfile [31:0];

  assign rs1_o = regfile[rs1_idx_i];
  assign rs2_o = regfile[rs2_idx_i];

  always_ff @(posedge clk_i, negedge rst_ni) begin 
    if (~rst_ni) begin
      regfile <= '0;
    end 
    else begin
      if (we_i) begin
        regfile[rd_idx_i] <= rd_i;
      end
    end
  end
endmodule
