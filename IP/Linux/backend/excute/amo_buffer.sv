module amo_buffer 
  import config_pkg::*;
(
    input   logic clk_i,   
    input   logic rst_ni,  
    input   logic flush_i, 

    input   logic             valid_i,  
    output  logic             ready_o,  
    input   amo_t             amo_op_i,  
    input   logic [55:0]      paddr_i,            
    input   logic [XLEN-1:0]  data_i,  
    input   logic [1:0]       data_size_i, 
    // D$
    output  amo_req_t         amo_req_o,  
    input   amo_resp_t        amo_resp_i,  
    // Auxiliary signals
    input   logic             amo_valid_commit_i,  
    input   logic             no_st_pending_i  
);
  logic flush_amo_buffer;
  logic amo_valid;

  typedef struct packed {
    amo_t             op;
    logic [55:0]      paddr;
    logic [XLEN-1:0]  data;
    logic [1:0]       size;
  } amo_op_t;

  amo_op_t amo_data_in, amo_data_out;

  assign amo_req_o.req = no_st_pending_i & amo_valid_commit_i & amo_valid;
  assign amo_req_o.amo_op = amo_data_out.op;
  assign amo_req_o.size = amo_data_out.size;
  assign amo_req_o.operand_a = {{64 - 55{1'b0}}, amo_data_out.paddr};
  assign amo_req_o.operand_b = {{64 - XLEN{1'b0}}, amo_data_out.data};

  assign amo_data_in.op = amo_op_i;
  assign amo_data_in.data = data_i;
  assign amo_data_in.paddr = paddr_i;
  assign amo_data_in.size = data_size_i;
  assign flush_amo_buffer = flush_i & !amo_valid_commit_i;

  fifo #(
      .DEPTH  (1),
      .dtype  (amo_op_t),
  ) i_amo_fifo (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .flush_i    (flush_amo_buffer),                  
      
      .data_i0    (amo_data_in),
      .push_i0    (valid_i),

      .data_i1    (),
      .push_i1    (),

      .data_o     (amo_data_out),
      .pop_i      (amo_resp_i.ack),
      
      .full_o     (amo_valid),
      .empty_o    (ready_o),
      .usage_o    ()
  );

endmodule
