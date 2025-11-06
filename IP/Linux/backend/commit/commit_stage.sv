module commit_stage #(
  parameters
) (
    // 时钟与复位
    input logic                       clk_i,                // 系统时钟
    input logic                       rst_ni,               // 异步复位（低电平有效）

    // 控制信号
    input logic                       halt_i,               // 核心暂停请求（暂停提交指令）
    input logic                       flush_dcache_i,       // 刷新数据缓存请求（同时刷新流水线）

    // 异常输出
    output  exception_t               exception_o,          // 提交阶段产生的异常信息

    // 单步执行
    input   logic                     single_step_i,        // 单步执行模式（一次仅提交一条指令）

    // 待提交指令
    input   scoreboard_entry_t        commit_instr_i,       // 来自发射阶段的待提交指令（多端口，支持并行提交）
    input   logic                     commit_drop_i,        // 标记指令是否被取消（如因分支预测错误）
    output  logic                     commit_ack_o,         // 确认指令已提交
    output  logic                     commit_macro_ack_o,   // 确认宏指令（如多周期指令）最后一段已提交

    // 寄存器文件写信号
    output  logic [4:0]               waddr_o,              // 通用寄存器写地址（x0-x31）
    output  logic [XLEN-1:0]          wdata_o,              // 通用寄存器写数据
    output  logic                     we_gpr_o,             // 通用寄存器写使能

    // 原子操作（AMO）响应
    input   amo_resp_t                amo_resp_i,           // 原子操作的结果响应（来自缓存）

    // 程序计数器输出
    output  logic [VLEN-1:0]          pc_o,                 // 当前提交指令的程序计数器（用于异常/CSR更新）

    // CSR（控制状态寄存器）交互
    output  fu_op                     csr_op_o,             // CSR操作类型（如读/写/置位）
    output  logic [XLEN-1:0]          csr_wdata_o,          // 写入CSR的数据
    input   logic [XLEN-1:0]          csr_rdata_i,          // 从CSR读出的数据

    // CSR异常输入
    input   exception_t               csr_exception_i,      // CSR操作产生的异常

    // 存储指令（LSU）提交
    output  logic                     commit_lsu_o,         // 提交挂起的存储指令（通知LSU执行）
    input   logic                     commit_lsu_ready_i,   // LSU准备好接收提交的存储指令（存储缓冲区未满）

    // 事务ID输出
    output  logic [POINTER_SIZE-1:0]  commit_tran_id_o,     // 第一个提交端口的事务ID（用于乱序执行后的按序提交）

    // 原子操作提交
    output  logic                     amo_valid_commit_o,   // 标记当前提交的是原子操作

    // 存储缓冲状态
    input   logic                     no_st_pending_i,      // 无挂起的存储操作（存储缓冲区为空）

    // CSR指令提交
    output  logic                     commit_csr_o,         // 提交挂起的CSR指令

    // 缓存与流水线刷新
    output  logic                     fence_i_o,            // 刷新指令缓存（I$）和流水线（FENCE.I）
    output  logic                     fence_o,              // 刷新数据缓存（D$）和流水线（FENCE）
    output  logic                     flush_commit_o,       // 请求刷新流水线
    output  logic                     sfence_vma_o          // 刷新TLB并流水线（SFENCE.VMA，用于虚拟地址空间切换）
);

  assign waddr_o = commit_instr_i.rd;
  assign pc_o = commit_instr_i.pc;
  assign commit_tran_id_o = commit_instr_i.trans_id;  // 输出第一条指令的事务ID（用于乱序执行的按序确认）

  logic  instr_0_is_amo;  // 标记第一个提交端口的指令是否为原子操作（AMO）
  logic  commit_macro_ack;  // 宏指令提交确认（内部信号）
  assign instr_0_is_amo = is_amo(commit_instr_i.op);  // 调用函数判断是否为AMO指令

  always_comb begin : commit
    commit_ack_o        = 1'b0;  // 端口0默认未确认
    commit_macro_ack    = 1'b0;  // 端口0宏指令默认未确认
    amo_valid_commit_o  = 1'b0;  // 默认无有效原子操作提交
    we_gpr_o            = 1'b0;  // 通用寄存器写使能默认0
    commit_lsu_o        = 1'b0;  // 存储指令默认未提交
    commit_csr_o        = 1'b0;  // CSR指令默认未提交
    // 原子操作结果优先使用缓存返回的响应，否则用指令执行结果
    wdata_o             = (amo_resp_i.ack) ? amo_resp_i.result[XLEN-1:0] : commit_instr_i.result;
    csr_op_o            = ADD;  // CSR操作默认无操作（NOP）
    csr_wdata_o         = {XLEN{1'b0}};  // CSR写数据默认0
    fence_i_o           = 1'b0;  // FENCE.I默认未触发
    fence_o             = 1'b0;  // FENCE默认未触发
    sfence_vma_o        = 1'b0;  // SFENCE.VMA默认未触发
    csr_write_fflags_o  = 1'b0;  // 浮点标志默认不写
    flush_commit_o      = 1'b0;  // 流水线默认不刷新

    // 若第一条指令有效且未暂停，则处理提交
    if (commit_instr_i.valid && !halt_i) begin
      if (commit_instr_i.ex.valid && commit_drop_i) begin
        commit_ack_o = 1'b1;
      end else begin
        commit_ack_o = 1'b1;

        if (!commit_drop_i) // 写使能
          we_gpr_o = 1'b1;
        if (commit_instr_i.fu == STORE && !(instr_0_is_amo)) begin // 普通写指令
          if (commit_lsu_ready_i) begin // 存储缓冲区未满
            commit_lsu_o = 1'b1;
          end else begin
            commit_ack_o = 1'b0;
          end
        end

        // ---------
        // CSR
        // ---------
        if (commit_instr_i.fu == CSR) begin
          csr_op_o    = commit_instr_i.op;
          csr_wdata_o = commit_instr_i.result;
          if (!commit_drop_i) begin
            if (!csr_exception_i.valid) begin
              commit_csr_o  = 1'b1;
              wdata_o       = csr_rdata_i;
            end else begin
              commit_ack_o  = 1'b0;
              we_gpr_o      = 1'b0;
            end
          end
        end
        // ------------------
        // SFENCE.VMA TLB刷新
        // ------------------
        if (commit_instr_i[0].op == SFENCE_VMA) begin
          if (!commit_drop_i[0]) begin
            sfence_vma_o = no_st_pending_i;
            commit_ack_o[0] = no_st_pending_i;
          end
        end

        // ------------------
        // FENCE.I 刷新I$和流水线，确保指令缓存一致性 TODO: CVA6Cfg.DCacheType == config_pkg::WB?
        // ------------------
        if (commit_instr_i[0].op == FENCE_I || (flush_dcache_i && CVA6Cfg.DCacheType == config_pkg::WB && commit_instr_i[0].fu != STORE)) begin
          if (!commit_drop_i[0]) begin
            commit_ack_o[0] = no_st_pending_i;
            fence_i_o = no_st_pending_i;
          end
        end
        // ------------------
        // FENCE Logic
        // ------------------
        if (commit_instr_i[0].op == FENCE) begin
          if (!commit_drop_i[0]) begin
            commit_ack_o[0] = no_st_pending_i;
            fence_o = no_st_pending_i;
          end
        end
        // ------------------
        // AMO
        // ------------------
        if (instr_0_is_amo) begin
          commit_ack_o        = amo_resp_i.ack;
          flush_commit_o      = amo_resp_i.ack; // 保证内存一致性，让原子指令独占lsu
          amo_valid_commit_o  = 1'b1;
          we_gpr_o            = amo_resp_i.ack;
        end
      end
    end

  end

    always_comb begin : exception_handling
    // 默认无异常
    exception_o.valid = 1'b0;
    exception_o.cause = '0;
    exception_o.tval  = '0;
    exception_o.tval2 = '0;
    exception_o.tinst = '0;
    exception_o.gva   = 1'b0;

    // 若第一条指令有效且未被取消，检查异常
    if (commit_instr_i.valid && !commit_drop_i) begin
      // 优先处理CSR操作产生的异常
      if (csr_exception_i.valid) begin
        exception_o      = csr_exception_i;
        exception_o.tval = commit_instr_i.ex.tval;  // 补充异常相关的tval（如故障地址）
      end
      // 若有更早的异常（如取指/译码阶段的异常），优先处理
      if (commit_instr_i.ex.valid) begin
        exception_o = commit_instr_i.ex;
      end
    end
    // 若处理器已暂停，不处理任何异常
    if (halt_i) begin
      exception_o.valid = 1'b0;
    end
  end

endmodule