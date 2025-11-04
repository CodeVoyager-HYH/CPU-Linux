// 此模块主要是用于检查数据相关性RAW 也是发射阶段流水线寄存器
module issue_read #(
  parameter type branchpredict_sbe_t = logic,
  parameter type fu_data_t = logic,
  parameter type scoreboard_entry_t = logic,
) (
  input   logic clk_i,
  input   logic rst_ni,
  input   logic flush_i,
  input   logic stall_i,

  // 与ScoreBoard交互
  input   scoreboard_entry_t  issue_instr_i,
  input   logic               issue_instr_valid_i,
  output  logic               issue_ack_o,
  input   logic               fwd_i,

  // 与Regfile交互 
  output  logic [4:0]                   rs1_idx_o,
  output  logic [4:0]                   rs2_idx_o,
  input   logic [config_pkg::XLEN-1:0]  rs1_i,
  input   logic [config_pkg::XLEN-1:0]  rs2_i,

  // FU
  input   logic   lsu_ready_i,
  input   logic   flu_ready_i,          
  output  logic   alu_valid_o,          // 普通指令
  output  logic   branch_valid_o,       // 控制流指令，比如跳转，分支跳转
  output  logic   lsu_valid_o,          // 访存指令
  output  logic   mult_valid_o,         // M扩展指令集
  output  logic   csr_valid_o,          // TODO:目前没有关于CSR指令

  // Issue
  output  branchpredict_sbe_t           branch_predict_o,
  output  logic                         stall_issue_o,
  output  logic [config_pkg::VLEN-1:0]  pc_o,
  output  fu_data_t                     fu_data_o
);

  //=============
  // 变量声明
  //=============
  logic     fu_busy;
  logic     rs1_raw_valid, rs2_raw_valid;
  logic     rs1_has_raw, rs2_has_raw;
  logic     stall_raw, stall_rs1, stall_rs2, stall_rs3;
  logic     forward_rs1, forward_rs2;
  fu_data_t fu_data_n, fu_data_q;
  logic     alu_valid_q, alu_valid_n;
  logic     branch_valid_q, branch_valid_n;
  logic     lsu_valid_q,  lsu_valid_n;
  logic     csr_valid_q, csr_valid_n;
  logic     mult_valid_q, mult_valid_n;
  logic     issue_ack;

  typedef struct packed {
    logic none, load, store, alu, alu2, ctrl_flow, mult, csr, fpu, fpu_vec, cvxif, accel, aes;
  } fus_busy_t;
  fus_busy_t [NrIssuePorts-1:0] fus_busy;

  logic [config_pkg::XLEN-1:0]          rs1_res, rs2_res;
  logic [config_pkg::NR_SB_ENTRIES-1:0] fwd_res_valid;
  logic [config_pkg::NR_SB_ENTRIES-1:0] rs1_is_not_csr, rs2_is_not_csr;
  logic [config_pkg::NR_SB_ENTRIES-1:0] rd_list;
  logic [$clog2(config_pkg::NR_SB_ENTRIES)-1:0] rs1_raw_idx, rs2_raw_idx;
  logic [config_pkg::NR_SB_ENTRIES-1:0][config_pkg::XLEN-1:0] fwd_res;

  for(genvar i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
    assign rd_list[i] = fwd_i.sbe[i].rd;
  end
  assign fu_data_o = fu_data_q;
  assign alu_valid_o = alu_valid_q;
  assign branch_valid_o = branch_valid_q;
  assign lsu_valid_o = lsu_valid_q;
  assign csr_valid_o = csr_valid_q;
  assign mult_valid_o = mult_valid_q;
  assign stall_issue_o = stall_raw;

  //==================
  // Chack RAW
  //==================
  raw_checker raw_checker_rs1(
    .clk_i,
    .rst_ni,
    .rs_i           (issue_instr_i.rs1),
    .rd_i           (rd_list),
    .still_issued_i (fwd_i.still_issued),
    .issue_pointer  (fwd_i.issue_pointer),
    .idx_o          (rs1_raw_idx),
    .valid_o        (rs1_raw_valid)
  );
  assign rs1_has_raw = rs1_raw_valid & !issue_instr_i.use_zimm;

  raw_checker raw_checker_rs2(
    .clk_i,
    .rst_ni,
    .rs_i           (issue_instr_i.rs2),
    .rd_i           (rd_list),
    .still_issued_i (fwd_i.still_issued),
    .issue_pointer  (fwd_i.issue_pointer),
    .idx_o          (rs2_raw_idx),
    .valid_o        (rs2_raw_valid)
  );
  assign rs2_has_raw = rs2_raw_valid;

  //================
  // 操作数可用性检查
  //================
  always_comb begin
    for (int unsigned i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
      fwd_res[i] = fwd_i.sbe[i].result;
      fwd_res_valid[i] = fwd_i.sbe[i].valid;
    end
    if (fwd_i.wb[i].valid && !fwd_i.wb[i].ex_valid) begin
      fwd_res[fwd_i.wb.issue_pointer] = fwd_i.wb.data;
      fwd_res_valid[fwd_i.wb.issue_pointer] = 1'b1;
    end
  end

    assign rs1_res = fwd_res[rs1_raw_idx];
    assign rs1_is_not_csr = (fwd_i.sbe[rs1_raw_idx].fu != config_pkg::CSR) || (issue_instr_i.op == config_pkg::SFENCE_VMA);
    assign rs1_valid = fwd_res_valid[rs1_raw_idx] && rs1_is_not_csr;

    assign rs2_res = fwd_res[rs2_raw_idx];
    assign rs2_is_not_csr =(fwd_i.sbe[rs2_raw_idx].fu != config_pkg::CSR) || (issue_instr_i.op == config_pkg::SFENCE_VMA);
    assign rs2_valid = fwd_res_valid[rs2_raw_idx] && rs2_is_not_csr;

  always_comb begin
    stall_raw   = '{default: stall_i};
    stall_rs1   = '{default: stall_i};
    stall_rs2   = '{default: stall_i};
    forward_rs1 = '0;
    forward_rs2 = '0;

    if (rs1_has_raw) begin  // 表示有RAW
      if (rs1_valid)  begin  // 表示数据前递的rs1是可以使用的
        forward_rs1 = 1'b1;
      end
      else begin
        stall_rs1 = 1'b1;
        stall_raw = 1'b1;
      end
    end

    if (rs2_has_raw) begin  // 表示有RAW
      if (rs2_valid)  begin  // 表示数据前递的rs1是可以使用的
        forward_rs2 = 1'b1;
      end
      else begin
        stall_rs2 = 1'b1;
        stall_raw = 1'b1;
      end
    end

  end

  //================
  // 数据前递
  //================
  always_comb begin
    fu_data_n.operand_a = rs1_i;
    fu_data_n.operand_b = rs2_i;
    fu_data_n.operation = issue_instr_i.op;
    fu_data_n.issue_pointer = fwd_i.issue_pointer;
    
    if (forward_rs1) begin
        fu_data_n.operand_a = rs1_res;
      end
      if (forward_rs2) begin
        fu_data_n.operand_b = rs2_res;
      end
  end

  if (issue_instr_i.use_pc) begin
        fu_data_n.operand_a = {
          {config_pkg::XLEN - config_pkg::VLEN{issue_instr_i.pc[config_pkg::VLEN-1]}}, issue_instr_i.pc
        };
  end

  if (issue_instr_i.use_zimm) begin
    fu_data_n.operand_a = {{config_pkg::XLEN - 5{1'b0}}, issue_instr_i.rs1[4:0]};
  end

  if (issue_instr_i.use_imm) begin
    fu_data_n.imm = issue_instr_i.imm;
    if((issue_instr_i.fu != STORE) && (issue_instr_i.fu != CTRL_FLOW)) begin
      fu_data_n.operand_b = issue_instr_i.imm;
    end
  end

  //==================
  // 结构性冒险
  //==================
  always_comb begin
    fus_busy = '0;

    if (!flu_ready_i) begin
      fus_busy[0].alu = 1'b1;
      fus_busy[0].ctrl_flow = 1'b1;
      fus_busy[0].csr = 1'b1;
      fus_busy[0].mult = 1'b1;
    end

    if (|mult_valid_q) begin
      fus_busy.alu = 1'b1;
      fus_busy.ctrl_flow = 1'b1;
      fus_busy.csr = 1'b1;
    end

    if (!lsu_ready_i) begin
      fus_busy.load  = 1'b1;
      fus_busy.store = 1'b1;
    end
  end

  always_comb begin
    unique case (issue_instr_i.fu)
      NONE:       fu_busy = fus_busy.none;
      ALU:        fu_busy = fus_busy.alu;
      CTRL_FLOW:  fu_busy = fus_busy.ctrl_flow;
      CSR:        fu_busy = fus_busy.csr;
      MULT:       fu_busy = fus_busy.mult;
      LOAD:       fu_busy = fus_busy.load;
      STORE:      fu_busy = fus_busy.store;
      
      default:    fu_busy = 1'b0;
    endcase
  end

  always_comb begin 
      issue_ack = 1'b0;

      if (issue_instr_valid_i && !fu_busy) begin
        if (!stall_raw) begin
          issue_ack = 1'b1;
        end
        if (issue_instr_i.ex.valid) begin
          issue_ack = 1'b1;
        end
      end

    issue_ack_o = issue_ack;

  end

    always_comb begin
    alu_valid_n    = '0;
    lsu_valid_n    = '0;
    mult_valid_n   = '0;
    csr_valid_n    = '0;
    branch_valid_n = '0;
      if (!issue_instr_i.ex.valid && issue_instr_valid_i && issue_ack_o) begin
        case (issue_instr_i.fu)
          ALU: begin
            alu_valid_n = 1'b1;
          end
          CTRL_FLOW: begin
            branch_valid_n = 1'b1;
          end
          MULT: begin
            mult_valid_n = 1'b1;
          end
          LOAD, STORE: begin
            lsu_valid_n = 1'b1;
          end
          CSR: begin
            csr_valid_n = 1'b1;
          end
        endcase
      end

    if (flush_i) begin
      alu_valid_n    = '0;
      lsu_valid_n    = '0;
      mult_valid_n   = '0;
      csr_valid_n    = '0;
      branch_valid_n = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fu_data_q         <= '0;
      alu_valid_q       <= '0;
      lsu_valid_q       <= '0;
      mult_valid_q      <= '0;
      csr_valid_q       <= '0;
      branch_valid_q    <= '0;
      pc_o              <= '0;
      branch_predict_o  <= {cf_t'(0), {config_pkg::VLEN{1'b0}}};
    end else begin
      fu_data_q       <= fu_data_n;
      alu_valid_q     <= alu_valid_n;
      lsu_valid_q     <= lsu_valid_n;
      mult_valid_q    <= mult_valid_n;
      csr_valid_q     <= csr_valid_n;
      branch_valid_q  <= branch_valid_n;

      if (issue_instr_i.fu == CTRL_FLOW) begin
        pc_o                  <= issue_instr_i.pc;
        branch_predict_o      <= issue_instr_i.bp;
      end

    end
  end
  
endmodule