module branch_unit
  import config_pkg::*;
#(
  parameter type bp_resolve_t = logic,
  parameter type branchpredict_sbe_t = logic,
  parameter type exception_t = logic,
  parameter type fu_data_t = logic
) (
  input   logic clk_i,
  input   logic rst_ni,

  input   logic [VLEN-1:0]  pc_i,
  input   fu_data_t             fu_data_i,
  input   logic                 branch_valid_i,
  input   branchpredict_sbe_t   branch_predict_i,   // 分支预测结果
  input   logic                 branch_comp_res_i,  // ALU条件分支比较结果，1为跳转

  output  logic [VLEN-1:0]      branch_rd_o,        // 寄存器链接指令需要修改寄存器的值
  output  logic [VLEN-1:0]      branch_result_o,    // 分支预测指令计算出的目标地址
  output  bp_resolve_t          resolved_branch_o,  // 用于修正预测结果
  output  logic                 resolve_branch_o,   // 指示当前指令已经被解析
  output  exception_t           branch_exception_o  // 分支指触发异常
);

  always_comb begin : mispredict_comb
    resolve_branch_o = 1'b0;                         
    resolved_branch_o.target_address = {VLEN{1'b0}};  
    resolved_branch_o.is_taken = 1'b0;               
    resolved_branch_o.valid = branch_valid_i;         
    resolved_branch_o.is_mispredict = 1'b0;      
    resolved_branch_o.cf_type = branch_predict_i.cf;  
    
    next_pc  = pc_i + {{VLEN-3{1'b0}}, 3'h4}; // 默认顺序执行
    target_address = $unsigned($signed(jump_base) + $signed(fu_data_i.imm[VLEN-1:0]));
    if (fu_data_i.operation == JALR) begin
      target_address[0] = 1'b0;
    end

    branch_result_o = next_pc;    
    resolved_branch_o.pc = pc_i;

    // 预测错误仅来自三类指令：1.分支（BEQ/BNE等）；2.寄存器跳转（JALR）；
    if (branch_valid_i) begin
      resolved_branch_o.target_address  = (branch_comp_res_i) ? target_address : next_pc;
      resolved_branch_o.is_taken        = branch_comp_res_i;

      // 处理普通分支指令的预测错误
      if(fu_data_i.operation inside {EQ, NE, LTS, GES, LTU, GEU}) begin
        resolved_branch_o.cf_type = Branch;
        resolved_branch_o.is_mispredict  = branch_comp_res_i != (branch_predict_i.cf == ariane_pkg::Branch);
      end

      if (fu_data_i.operation == JALR && (branch_predict_i.cf == NoCF || target_address != branch_predict_i.predict_address)) begin // 处理JALR指令的预测错误
        resolved_branch_o.is_mispredict = 1'b1;
        if (branch_predict_i.cf != Return)
          resolved_branch_o.cf_type = JumpR;
      end

      resolve_branch_o = 1'b1;
    end
  end

  // 异常处理
  always_comb begin : exception_comb
    branch_exception_o.cause = riscv::INSTR_ADDR_MISALIGNED;
    branch_exception_o.valid = 1'b0;  // 默认：无异常
    branch_exception_o.tval = {{XLEN - VLEN{pc_i[VLEN-1]}}, pc_i};
    branch_exception_o.tval2 = {41{1'b0}};
    branch_exception_o.tinst = '0;
    branch_exception_o.gva   = 1'b0;
  end
endmodule