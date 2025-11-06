module controlled #(
  parameters
) (
      // 时钟与复位
    input logic         clk_i,  // 系统时钟
    input logic         rst_ni,  // 异步复位（低电平有效）

    // 前端（取指阶段）控制
    output logic        set_pc_commit_o,  // 通知前端将PC设置为提交阶段的PC（用于指令同步）
    output logic        flush_if_o,  // 刷新取指（IF）阶段
    output logic        flush_unissued_instr_o,  // 刷新记分板中未发射的指令
    output logic        flush_bp_o,  // 刷新分支预测器

    // 流水线各阶段刷新
    output logic        flush_id_o,  // 刷新译码（ID）阶段
    output logic        flush_ex_o,  // 刷新执行（EX）阶段

    // 缓存控制
    output logic        flush_icache_o,  // 刷新指令缓存（ICache）
    output logic        flush_dcache_o,  // 刷新数据缓存（DCache）
    input  logic        flush_dcache_ack_i,  // DCache刷新完成的确认信号

    // TLB控制
    output logic        flush_tlb_o,  // 刷新普通TLB
    output logic        flush_tlb_vvma_o,  // 刷新虚拟化相关的VVMA TLB
    output logic        flush_tlb_gvma_o,  // 刷新虚拟化相关的GVMA TLB

    // 暂停控制
    input  logic        halt_csr_i,  // CSR模块的暂停请求（如WFI指令）
    output logic        halt_frontend_o,  // 暂停前端（取指阶段）
    output logic        halt_o,  // 暂停提交阶段

    // 异常与调试
    input  logic        eret_i,  // 从异常返回（如ERET指令）
    input  logic        ex_valid_i,  // 异常有效信号
    input  logic        set_debug_pc_i,  // 设置调试PC（调试模式）

    // 分支预测结果
    input  bp_resolve_t resolved_branch_i,  // 分支解析结果（是否预测错误）

    // 特殊指令与刷新请求
    input  logic        flush_csr_i,  // CSR操作触发的流水线刷新请求
    input  logic        fence_i_i,  // FENCE.I指令输入（指令屏障）
    input  logic        fence_i,  // FENCE指令输入（数据屏障）
    input  logic        sfence_vma_i,  // SFENCE.VMA指令输入（TLB刷新）
    input  logic        flush_commit_i  // 提交阶段触发的刷新请求
);

  // 跟踪数据缓存刷新状态（FENCE指令）
  logic fence_active_d, fence_active_q;  // _d:下一状态；_q:当前状态（寄存器存储）
  logic flush_dcache;  // 数据缓存刷新请求（组合逻辑信号）

  // 跟踪FENCE.I指令的处理状态
  logic fence_i_active_d, fence_i_active_q;  // 同上，用于FENCE.I的状态跟踪
  
    always_comb begin : flush_ctrl
    fence_active_d         = fence_active_q;
    fence_i_active_d       = fence_i_active_q;
    set_pc_commit_o        = 1'b0;
    flush_if_o             = 1'b0;
    flush_unissued_instr_o = 1'b0;
    flush_id_o             = 1'b0;
    flush_ex_o             = 1'b0;
    flush_dcache           = 1'b0;
    flush_icache_o         = 1'b0;
    flush_tlb_o            = 1'b0;
    flush_tlb_vvma_o       = 1'b0;
    flush_tlb_gvma_o       = 1'b0;
    flush_bp_o             = 1'b0;

    //===========
    // 分支预测错误 
    //===========
    if (resolved_branch_i.is_mispredict) begin
      flush_unissued_instr_o = 1'b1;  // 清除记分板中未发射的指令（错误路径）
      flush_if_o             = 1'b1;  // 刷新取指阶段，开始从正确分支地址取指
    end

    // ---------------------------------
    // FENCE
    // ---------------------------------
    if (fence_i) begin  // 收到FENCE指令
      set_pc_commit_o        = 1'b1;  // 通知前端将PC同步到提交阶段的PC（确保指令顺序）
      flush_if_o             = 1'b1;  // 刷新取指阶段
      flush_unissued_instr_o = 1'b1;  // 刷新未发射指令
      flush_id_o             = 1'b1;  // 刷新译码阶段
      flush_ex_o             = 1'b1;  // 刷新执行阶段
      // 若配置要求FENCE时刷新DCache（如写回型缓存）
      if (CVA6Cfg.DcacheFlushOnFence) begin
        flush_dcache   = 1'b1;  // 触发DCache刷新
        fence_active_d = 1'b1;  // 激活FENCE处理状态（等待刷新完成）
      end
    end

    // ---------------------------------
    // FENCE.I
    // ---------------------------------
    if (fence_i_i) begin  // 收到FENCE.I指令
      set_pc_commit_o        = 1'b1;  // 同步PC
      flush_if_o             = 1'b1;  // 刷新取指阶段
      flush_unissued_instr_o = 1'b1;  // 刷新未发射指令
      flush_id_o             = 1'b1;  // 刷新译码阶段
      flush_ex_o             = 1'b1;  // 刷新执行阶段
      flush_icache_o         = 1'b1;  // 刷新ICache（确保取到最新指令）
      // 若配置要求FENCE.I时刷新DCache
      if (CVA6Cfg.DcacheFlushOnFence) begin
        flush_dcache = 1'b1;  // 触发DCache刷新
        fence_active_d = 1'b1;  // 激活FENCE状态
        fence_i_active_d = 1'b1;  // 激活FENCE.I状态（单独跟踪）
      end
    end

    // 处理缓存刷新的确认信号（等待DCache刷新完成）
    if (CVA6Cfg.DcacheFlushOnFence) begin
      // FENCE.I状态：仅在DCache刷新完成后清除
      if (flush_dcache_ack_i && fence_i_active_q) begin
        fence_i_active_d = 1'b0;  // 清除FENCE.I活跃状态
      end
      // FENCE状态：仅在DCache刷新完成后清除
      if (flush_dcache_ack_i && fence_active_q) begin
        fence_active_d = 1'b0;            // 清除FENCE活跃状态
      end else if (fence_active_q) begin  // 若FENCE仍活跃，保持DCache刷新信号
        flush_dcache = 1'b1;
      end
    end

    // ---------------------------------
    // SFENCE.VMA
    // ---------------------------------
    if (sfence_vma_i) begin  
      set_pc_commit_o        = 1'b1;  // 同步PC
      flush_if_o             = 1'b1;  // 刷新取指阶段
      flush_unissued_instr_o = 1'b1;  // 刷新未发射指令
      flush_id_o             = 1'b1;  // 刷新译码阶段
      flush_ex_o             = 1'b1;  // 刷新执行阶段
      flush_tlb_o            = 1'b1;  // 刷新TLB
    end

    // ---------------------------------
    // CSR副作用和AMO的刷新
    // ---------------------------------
    if (flush_csr_i) begin  // CSR操作或加速器请求刷新
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
    end else if (flush_commit_i) begin  // 原子操作触发的刷新
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
    end

    // ---------------------------------
    // 1. 异常发生 2. 异常返回 3. 调试模式
    // ---------------------------------
    if (ex_valid_i || eret_i || (CVA6Cfg.DebugEn && set_debug_pc_i)) begin
      set_pc_commit_o        = 1'b0;  // 不使用提交阶段PC（异常处理有独立PC来源）
      flush_if_o             = 1'b1;  // 刷新取指阶段
      flush_unissued_instr_o = 1'b1;  // 刷新未发射指令
      flush_id_o             = 1'b1;  // 刷新译码阶段
      flush_ex_o             = 1'b1;  // 刷新执行阶段
      flush_bp_o             = 1'b1;  // 刷新分支预测器（避免投机执行错误）
    end
  end

  // ----------------------
  // Halt Logic
  // ----------------------
  always_comb begin
    // 核心暂停条件：CSR请求暂停（如WFI）、加速器请求暂停、DCache刷新中
    halt_o = halt_csr_i || halt_acc_i || (CVA6Cfg.DcacheFlushOnFence && fence_active_q);
    // 前端暂停条件：FENCE.I处理中（防止取到未刷新的旧指令）
    halt_frontend_o = fence_i_active_q;
  end

  // ----------------------
  // Registers
  // ----------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      fence_active_q   <= 1'b0;
      fence_i_active_q <= 1'b0;
      flush_dcache_o   <= 1'b0;
    end else begin
      fence_active_q   <= fence_active_d;
      fence_i_active_q <= fence_i_active_d;
      // register on the flush signal, this signal might be critical
      flush_dcache_o   <= flush_dcache;
    end
  end

endmodule