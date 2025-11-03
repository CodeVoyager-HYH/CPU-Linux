module scoreboard #(
  parameter type bp_resolve_t       = logic,
  parameter type scoreboard_entry_t = logic,
  parameter type forwarding_t       = logic,
  parameter type writeback_t        = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic stall_i,
  input logic flush_i,
  input logic flush_unissued_instr_i, // 阻止发射

  // 数据前递(同时包括了执行阶段的运算结果，需要更新scoreboard)
  output  forwarding_t        fwd_o,
  input   fu_back_t           fu_result_i,  // 从执行阶段传回的数据，主要就是数据是否可用和计算结果，目标寄存器

  // 分支跳转
  input   bp_resolve_t        resolved_branch_i,

  // 发射阶段的交互
  output  logic               issue_instr_valid_o,
  input   logic               issue_ack_i, 
  output  scoreboard_entry_t  issue_instr_o,

  // 与译码阶段的交互
  input   scoreboard_entry_t  decoded_instr_i,
  input   logic               decoded_instr_valid_i,
  output  logic               decoded_instr_ack_o,  // 用于暂停发射阶段往前的流水线

  // 与写回阶段的交互(主要是从scoreboard中删除数据)
  // 同时这是写回阶段的寄存器，所以需要传递需要提交的信息
  output  scoreboard_entry_t  commit_instr_o,
  input   logic               commit_ack_i  // 用于scoreboard删除已经提交的数据
);

  typedef struct packed {
  logic valid;
  logic [config_pkg::XLEN-1:0] result;
  logic [$clog2(config_pkg::NR_SB_ENTRIES):0] issue_pointer;
  } fu_back_t;

  typedef struct packed {
    logic issued;  
    logic cancelled;  
    scoreboard_entry_t sbe;  
  } sb_mem_t;

  sb_mem_t  [config_pkg::NR_SB_ENTRIES-1:0] mem_q, mem_n;
  logic     [config_pkg::NR_SB_ENTRIES-1:0] still_issued; // 用于chack_raw模块
  logic     sb_full;
  logic     [$clog2(config_pkg::NR_SB_ENTRIES):0] scoreboard_usage;
  logic     bmiss;

  logic     [$clog2(config_pkg::NR_SB_ENTRIES):0] issue_pointer_n, issue_pointer_q;
  logic     [$clog2(config_pkg::NR_SB_ENTRIES):0] issue_pointer;
  
  logic     [$clog2(config_pkg::NR_SB_ENTRIES):0] commit_pointer_n, commit_pointer_q;
  
  for (genvar i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
    assign still_issued[i] = mem_q[i].issued & ~mem_q[i].cancelled;  // 判断条件 已发射且未取消
  end

  assign sb_full = (scoreboard_usage == config_pkg::NR_SB_ENTRIES);
  assign decoded_instr_ack_o = (issue_ack_i & ~sb_full);
  assign bmiss = resolved_branch_i.valid && resolved_branch_i.is_mispredict;

  always_comb begin
    //=================
    // Commit
    //=================
    commit_instr_o    = mem_q [commit_pointer_q].sbe;
    mem_n             = mem_q;
    commit_pointer_n  = commit_pointer_q;
    sb_usage_n        = sb_usage_q;

    // 修改数据
    if(commit_ack_i && sb_usage_n) begin
      sb_usage_n--;

      // 不全部清空方便保存信息，用于调试
      mem_n[commit_pointer_q].issued    = 1'b0;
      mem_n[commit_pointer_q].cancelled = 1'b0;
      mem_n[commit_pointer_q].sbe.valid = 1'b0;

      if(commit_pointer_n == config_pkg::NR_SB_ENTRIES-1) begin  //表示在数组顶端
        commit_pointer_n = 0;
      end
      else commit_pointer_n++;
    end

    //================
    // Issue
    //=================
    issue_instr_o       = decoded_instr_i;
    issue_pointer_n     = issue_pointer_q;
    issue_instr_valid_o = decoded_instr_valid_i & ~issue_full;

    // 成功发射 & 修改数据
    if (decoded_instr_valid_i && decoded_instr_ack_o && !flush_unissued_instr_i) begin 
      mem_n[issue_pointer_q] = '{
          issued: 1'b1,
          cancelled: 1'b0,
          sbe: decoded_instr_i
      };
      // 更新指针
      if (issue_pointer_q == config_pkg::NR_SB_ENTRIES-1) begin
        issue_pointer_n = 0;
      end
      else issue_pointer_n++;
      
    end

    //==================
    // 数据前递1
    //==================
    if(fu_result_i.valid) begin
      mem_n[fu_result_i.issue_pointer].sbe.result = fu_result_i.result;
    end

    //==================
    // 分支跳转异常
    //==================
    if(bmiss) begin
      for(int unsigned i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
        if(mem_n[i].issued == 1'b0)begin
          mem_n[i].cancelled = 1'b1;
        end
      end
    end

    //==================
    // Flush
    //==================
    commit_pointer_n = '0;
    issue_pointer_n  = '0;

    if (flush_i) begin
      for (int unsigned i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
        mem_n[i].issued       = 1'b0;
        mem_n[i].cancelled    = 1'b0;
        mem_n[i].sbe.valid    = 1'b0;
        mem_n[i].sbe.ex.valid = 1'b0;
      end
    end

  end

  //==================
  // 数据前递2
  //==================
  writeback_t wb;
  assign wb.valid         = fu_result_i.valid;
  assign wb.data          = fu_result_i.result;
  assign wb.issue_pointer = fu_result_i.issue_pointer;
  // assign wb[i].ex_valid = ex_i[i].valid;

  assign fwd_o.still_issued  = still_issued;
  assign fwd_o.issue_pointer = issue_pointer_q;
  assign fwd_o.wb = wb;
  for (genvar i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
    assign fwd_o.sbe[i] = mem_q[i].sbe;
  end

  //==================
  // 逻辑更新
  //==================
  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      mem_q            <= '{default: sb_mem_t'(0)};
      commit_pointer_q <= '0;
      issue_pointer_q  <= '0;
    end else begin
      issue_pointer_q <= issue_pointer_n;
      mem_q <= mem_n;
      commit_pointer_q <= commit_pointer_n;
    end
  end
endmodule