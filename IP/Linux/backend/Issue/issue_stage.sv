// 发射模块 其中包含scoreboard，issue_read, regfile
module issue_stage #(
    parameter
) (
  input logic clk_i,
  input logic rst_ni,
  input logic stall_i,
  input logic flush_i,
  input logic flush_unissued_instr_i,

  // 与译码阶段的交互
  input   scoreboard_entry_t            decoded_instr_i,
  input   logic                         decoded_instr_valid_i,  // 指令合法
  output  logic                         decoded_instr_ack_o,  // 暂停译码

  // 与执行阶段的交互
  input   fu_back_t                     fu_result_i,          // 数据前递
  output  logic [config_pkg::XLEN-1:0]  pc_o,
  input   bp_resolve_t                  resolved_branch_i,    // 分支预测错误
  input   logic                         lsu_ready_i,
  input   logic                         flu_ready_i,
  output  logic                         alu_valid_o,
  output  logic                         branch_valid_o,
  output  logic                         lsu_valid_o,
  output  logic                         mult_valid_o,
  output  logic                         csr_valid_o,
  output  logic                         stall_issue_o, 
  output  fu_data_t                     fu_data_o,
  output  branchpredict_sbe_t           branch_predict_o,

  // 与提交阶段的交互
  input   logic                         commit_ack_i,         // 写回更改scoreboard
  input   logic [config_pkg::XLEN-1:0 ] wdata_i,
  input   logic                         we_gpr_i,             
  input   logic [4:0]                   waddr_i,
  output  scoreboard_entry_t            commit_instr_o
);
  //=================
  // 变量声明
  //=================
  forwarding_t        fwd;
  logic               issue_instr_valid; // 给issue_read合法性
  logic               issue_ack;
  scoreboard_entry_t  issue_instr;
  //=================
  // 模块声明
  //=================

  // scoreboard
  scoreboard #(
    .bp_resolve_t       (bp_resolve_t),
    .scoreboard_entry_t (scoreboard_entry_t),
    .forwarding_t       (forwarding_t),
    .writeback_t        (writeback_t),
  ) i_scoreboard (
    .clk_i,
    .rst_ni,
    .stall_i,
    .flush_i,
    .fwd_o                (fwd),
    .fu_result_i,
    .resolved_branch_i,
    .issue_instr_valid_o  (issue_instr_valid),
    .issue_ack_i          (issue_ack),
    .issue_instr_o        (issue_instr),
    .decoded_instr_i,
    .decoded_instr_valid_i,
    .decoded_instr_ack_o,
    .commit_instr_o,
    .commit_ack_i
  );

  // issue_read
  issue_read #(
    .branchpredict_sbe_t  (branchpredict_sbe_t),
    .fu_data_t            (fu_data_t),
    .scoreboard_entry_t   (scoreboard_entry_t)
  ) i_issue_read (
    .clk_i,
    .rst_ni,
    .flush_i,
    .stall_i,
    .issue_instr_i        (issue_instr),
    .issue_instr_valid_i  (issue_instr_valid),
    .issue_ack_o          (issue_ack),
    .fwd_i                (fwd),
    .rs1_idx_o            (rs1_idx),
    .rs2_idx_o            (rs2_idx),
    .rs1_i                (rs1),
    .rs2_i                (rs2),
    .lsu_ready_i,
    .flu_ready_i,
    .alu_valid_o,
    .branch_valid_o,
    .lsu_valid_o,
    .mult_valid_o,
    .csr_valid_o,
    .branch_predict_o,
    .stall_issue_o,
    .pc_o,
    .fu_data_o
  );

  // regfile
  regfile i_regfile(
    .clk_i,
    .rst_ni,
    .rs1_idx_i  (rs1_idx),
    .rs2_idx_i  (rs2_idx),
    .rs1_o      (rs1),
    .rs2_o      (rs2),
    .wdata_i,
    .waddr_i,
    .we_gpr_i
  );
endmodule