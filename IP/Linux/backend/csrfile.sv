module csrfile 
#(
  parameters
) (
  input logic clk_i,
  input logic rst_ni,

  input logic time_irq_i,
  // send a flush request out when a CSR with a side effect changes - CONTROLLER
  output logic flush_o,
  // halt requested - CONTROLLER
  output logic halt_csr_o,
);
  
endmodule