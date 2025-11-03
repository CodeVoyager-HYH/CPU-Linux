module moduleName #(
  parameter type fetch_entry_t       = logic,
  parameter type scoreboard_entry_t  = logic,
  parameter type branchpredict_sbe_t = logic 
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic flush_i,

  // 前端交互
  input  fetch_entry_t      fetch_entry_i, 
  input  logic              fetch_entry_valid_i,
  output logic              backend_ready_o,

  // 发射阶段交互
  input  logic              decoded_instr_ack_i,
  output logic              decoded_instr_valid_o,
  output scoreboard_entry_t decoded_instr_o
);
  typedef struct packed {
    logic              valid;
    scoreboard_entry_t sbe;
    logic [31:0]       orig_instr;
  } issue_struct_t;

  issue_struct_t issue_n, issue_q;
  scoreboard_entry_t  reg_decoded_instr;
  logic               backend_ready;
  logic               is_illegal;
  logic               is_control_flow_instr;
  logic               decoded_instr_valid;
  logic               decoded_instruction_valid;
  scoreboard_entry_t  decoded_instruction;
  
  decoder i_decoder(
    .pc_i                     (fetch_entry_i.address),
    .instruction_i            (fetch_entry_i.instruction),
    .branch_predict_i         (fetch_entry_i.branch_predict),
    .instruction_o            (decoded_instruction),
    .is_control_flow_instr_o  (is_control_flow_instr)
  );

  assign decoded_instr_o = issue_q.sbe;
  assign decoded_instr_valid_o = issue_q.valid;
  assign stall_instr_fetch = ~(fetch_entry_valid_i || decoded_instr_ack_i); // 前端发射指令无效需要暂停，后端发射无效需要暂停

  always_comb begin 
    issue_n = issue_q;
    backend_ready_o = 1'b0;
    decoded_instruction_valid = 1'b1; // TODO: 没有异常操作指令目前不会非法

    if (issue_instr_ack_i) issue_n.valid = 1'b0;
    if (!issue_n.valid && fetch_entry_valid_i) begin
      backend_ready_o = ~stall_instr_fetch; // 后端未准备好，需要暂停前端发送指令
      issue_n = '{
          decoded_instruction_valid,
          decoded_instruction,
          is_control_flow_instr
      };
    end
    if (flush_i) issue_n[0].valid = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni ) begin 
    if(~rst_ni) begin
      issue_q <= '0;
    end
    else
      issue_q <= issue_n;
  end
endmodule