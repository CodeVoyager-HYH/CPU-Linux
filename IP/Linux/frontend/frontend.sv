// 重放逻辑
  // ICache->instr_realign->instr_scan->bp->instr_queue
  //      ^                             |       | 主要是重放判断
  //      |                             |<———————
  //      |_____________________________|

module fromtend 
  import config_pkg::*;
#(
    parameter type fetch_entry_t      = logic,
    parameter type icache_data_res_t  = logic,
    parameter type icache_data_req_t  = logic
) (
    input   logic clk_i,
    input   logic rst_ni,
    input   logic flush_i,
    input   logic halt_i,
    input   logic flush_bp_i,
    input   logic halt_frontend_i,
    input   logic set_pc_commit_i,

    input   logic [VLEN-1:0]  boot_addr_i,        // 复位pc值
    input   logic [VLEN-1:0]  trap_vector_base_i, //异常入口基地址
    input   logic                         eret_i,             //异常返回信号
    input   logic [VLEN-1:0]  epc_i,
    input   bp_resolve_t                  resolved_branch_i,  // 分支预测结果，用来更新分支预测器
    // ICache
    input   icache_data_req_t             icache_dreq_i,      // 前端送到ICache的请求包
    output  icache_data_res_t             icache_dreq_o,      // ICache返回给前端的响应包

    input   logic                         backend_ready_i,

    output fetch_entry_t                  fetch_entry_o,
    output logic                          fetch_entry_valid_o
);
    
// =====================================
// Branch Prediction --- 分支预测
// =====================================

  // 分支历史表更新信息：是否有效，更新地址，是否跳转
  localparam type bht_update_t = struct packed {
    logic                        valid;
    logic [VLEN-1:0] pc;     // update at PC
    logic                        taken;
  };

  localparam type bht_prediction_t = struct packed  {
    logic valid;
    logic taken;
  };

  // 返回地址栈：是否有效，返回地址
  localparam type ras_t = struct packed {
    logic                        valid;
    logic [VLEN-1:0] ra;
  };

  // BTB
  localparam type btb_update_t = struct packed {
    logic                        valid;
    logic [VLEN-1:0] pc;              // update at PC
    logic [VLEN-1:0] target_address;
  };

  localparam type btb_prediction_t = struct packed {
    logic [VLEN-1:0] target_address; // BTB 预测的目标地址
    logic                        hit;            // 预测是否命中 (Tag 匹配且 Valid 为真)
  };

  logic [VLEN-1:0]  icache_vaddr_q ;
  logic [XLEN-1:0]  icache_data  ;
  logic                         icache_valid ;
  logic [XLEN-1:0]  icache_data_q;
  logic                         icache_valid_q;
  logic [VLEN-1:0]  icache_vaddr_q;
  logic                         instr_queue_ready;
  logic                         instr_queue_consumed;
  logic [VLEN-1:0]  npc_d,npc_q;
  logic                         replay;
  logic [VLEN-1:0]  replay_addr;
  logic                         taken_rvi_cf;
  logic [VLEN-1:0]  predict_address;
  logic ras_push, ras_pop;
  logic [VLEN-1:0]  ras_update;

//===================
// instr_scan
//===================  
  logic                        is_return;
  logic                        is_call;  
  logic                        is_branch;
  logic                        is_jalr;
  logic                        is_jump;

  logic                        rvi_return;
  logic                        rvi_call;
  logic                        rvi_branch;
  logic                        rvi_jalr;
  logic                        rvi_jump;
  logic [VLEN-1:0] rvi_imm;

  instr_scan i_instr_scan (
    .instr_i     (icache_data_q),

    .rvi_return_o(rvi_return),
    .rvi_call_o  (rvi_call),
    .rvi_branch_o(rvi_branch),
    .rvi_jalr_o  (rvi_jalr),
    .rvi_jump_o  (rvi_jump),
    .rvi_imm_o   (rvi_imm),

    .rvc_branch_o(),
    .rvc_jump_o  (),
    .rvc_jr_o    (),
    .rvc_return_o(),
    .rvc_jalr_o  (),
    .rvc_call_o  (),
    .rvc_imm_o   ()
  );

  // 判断指令
    // branch history table -> BHT
    assign is_branch = icache_valid_q & (rvi_branch);
    // function calls -> RAS
    assign is_call = icache_valid_q & (rvi_call);
    // function return -> RAS
    assign is_return = icache_valid_q & (rvi_return);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump = icache_valid_q & (rvi_jump);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr = icache_valid_q & ~is_return & (rvi_jalr);


//===================
// Branch Prediction
//===================  
  btb_prediction_t  btb_prediction;
  btb_update_t      btb_update;
  bht_update_t      bht_update;
  bht_prediction_t  bht_prediction;
  bht_prediction_t  bht_prediction_shifted; // 当指令是拼接指令的时候需要用上个周期的预测结果
  btb_prediction_t  btb_prediction_shifted;
  ras_t             ras_predict;
  cf_t              cf_type;

  assign bht_prediction_shifted     =  bht_prediction;
  assign btb_prediction_shifted     =  btb_prediction;
  assign bht_update.valid           =  resolved_branch_i.valid
                                    & (resolved_branch_i.cf_type == Branch);
  assign bht_update.pc              =  resolved_branch_i.pc;
  assign bht_update.taken           =  resolved_branch_i.is_taken;
  assign btb_update.valid           =  resolved_branch_i.valid
                                    &  resolved_branch_i.is_mispredict
                                    & (resolved_branch_i.cf_type == JumpR);
  assign btb_update.pc              =  resolved_branch_i.pc;
  assign btb_update.target_address  =  resolved_branch_i.target_address;

  // 没有必要判断使用哪一个，因为BTB和BHT是支持两条指令预测的，只需要判断是不是需要判断RAS
  // 需要移位操作，这样可以防止拼接地址导致预测错误
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    // 有记录就跳转，无记录就静态分支预测
    cf_type = NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

        unique case ({
          is_branch, is_return, is_jump, is_jalr
        })
          4'b0000: ;  
          4'b0001: begin
            ras_pop  = 1'b0;
            ras_push = 1'b0;
            if(btb_prediction_shifted.hit) begin
              predict_address = btb_prediction_shifted.target_address;
              cf_type = JumpR;
            end
          end
          // its an unconditional jump to an immediate
          4'b0010: begin
            ras_pop = 1'b0;
            ras_push = 1'b0;
            taken_rvi_cf = rvi_jump;
            taken_rvc_cf = rvc_jump;
            cf_type = Jump;
          end
          // return
          4'b0100: begin
            ras_pop = ras_predict.valid & instr_queue_consumed;
            ras_push = 1'b0;
            predict_address = ras_predict.ra;
            cf_type = Return;
          end
          // branch prediction
          4'b1000: begin
            ras_pop  = 1'b0;
            ras_push = 1'b0;
            if (bht_prediction_shifted.valid) begin
              taken_rvi_cf = rvi_branch & bht_prediction_shifted.taken;
              taken_rvc_cf = rvc_branch & bht_prediction_shifted.taken;
            end else begin
              taken_rvi_cf = rvi_branch & rvi_imm[VLEN-1];
              taken_rvc_cf = rvc_branch & rvc_imm[VLEN-1];
            end
            if (taken_rvi_cf || taken_rvc_cf) begin
              cf_type = Branch;
            end
          end
          default: ;
        endcase
        
        if (is_call) begin
          ras_push   = instr_queue_consumed;
          ras_update = icache_vaddr_q +  4;
        end
        if (taken_rvi_cf) begin
          predict_address = icache_vaddr_q +  rvi_imm;
        end
  end

  // BTB
    btb i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i       (flush_bp_i),
        .vpc_i            (icache_vaddr_q),
        .btb_update_i     (btb_update),
        .btb_prediction_o (btb_prediction)
    );

  // BHT
    bht i_bht (
      .clk_i
      .rst_ni
      .flush_bp_i         (flush_bp_i),
      .vpc_i              (icache_vaddr_q),
      .bht_update_i       (bht_update),
      .bht_prediction_o   (bht_prediction)
    );

  // RAS
  ras #(
      .ras_t  (ras_t),
      .DEPTH  (8)
  ) i_ras (
      .clk_i,
      .rst_ni,
      .flush_bp_i         (flush_bp_i),
      .push_i             (ras_push),
      .pop_i              (ras_pop),
      .data_i             (ras_update),
      .data_o             (ras_predict)
  );

//===================
// Instruction Queue
//===================  

  instr_queue i_instr_queue(
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .flush_i                (flush_i),
    .valid_i                (icache_valid_q)
    .instr_i                (icache_data_q),
    .addr_i                 (icache_vaddr_q),
    .backend_ready_i        (backend_ready_i),
    .cf_type_i              (cf_type),
    .icache_ex_valid        (icache_ex_valid_q),
    .predict_address_i      (predict_address),

    .ready_o                (instr_queue_ready),
    .consumed_o             (instr_queue_consumed),
    .replay_o               (replay),
    .replay_addr_o          (replay_addr),
    .fetch_entry_o          (fetch_entry_o),
    .fetch_entry_valid_o    (fetch_entry_valid_o)
  );

// -------------------
// Next PC
// -------------------
  logic is_mispredict;
  logic if_ready;
  logic bp_valid;
  logic npc_rst_load_q;
  logic speculative_q, speculative_d; // ICache不会立刻写入预测的地址，这样可能会污染ICache

  assign speculative_d = (speculative_q && !resolved_branch_i.valid || is_branch || is_return || is_jalr) && !flush_i;
  
  assign icache_dreq_o.spec = speculative_d;
  assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
  // 刷新缓存第一级流水线（S1）的条件：
  // - 预测错误（需纠正PC）；
  // - 整体刷新（如异常、FENCE）；
  // - 指令重放（队列满未成功传递）。
  assign icache_dreq_o.kill_s1 = is_mispredict | flush_i | replay;
  // 刷新缓存第二级流水线（S2）的条件：
  // - S1已刷新（级联刷新）；
  // - 分支预测有效（无需继续取后续指令，直接跳转）。
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1 | bp_valid;
  
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;
  // 当if_ready为高时，ICache 会将指令数据传递给前端，同时前端会更新下一条 PC（npc_d），完成一次取指流程。
  assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;
  always_comb begin
    bp_valid = 1'b0;
    // 如果我们有返回指令，而 RAS 没有提供有效地址，则 BP 无效。
    // 检查我们是否遇到了控制流，以及对于返回，
    // RAS是否包含有效预测。
    for (int i = 0; i < 2; i++)
      //如果 cf_type != NoCF && cf_type != Return → 是 JAL、BRANCH 等，肯定是控制流，设为 valid。
      //如果是 cf_type == Return，只有在 ras_predict.valid == 1 时才算有效分支预测。
      bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) | ((cf_type[i] == Return) & ras_predict.valid));
  end


  assign icache_data = icache_dreq_i.data;
  
  always_comb begin : select_pc
    automatic logic [VLEN-1:0] fetch_address;

    // 复位
    if(npc_rst_load_q) begin
      npc_d         = boot_addr_i;
      fetch_address = boot_addr_i;
    end
    else begin
      fetch_address = npc_q;
      npc_d         = npc_q;
    end


    // 分支预测
    if(bp_valid) begin
      fetch_address = predict_address;
      npc_d = predict_address;
    end
    // 默认
    if (if_ready) begin
      npc_d = {
        fetch_address[VLEN-1:FETCH_ALIGN_BITS] + 1, {FETCH_ALIGN_BITS{1'b0}}
      };
    end
    // 重放
    if (replay) begin 
      npc_d = replay_addr;
    end
    // 控制流指令预测错误
    if (is_mispredict) begin
      npc_d = resolved_branch_i.target_address;
    end
    // eret
    if (eret_i) begin //异常返回
      npc_d = epc_i;
    end
    // 5. 异常中断
    if (ex_valid_i) begin 
      npc_d = trap_vector_base_i;
    end
    icache_dreq_o.vaddr = fetch_address;
  end
  if (set_pc_commit_i) begin
    npc_d = pc_commit_i + (halt_i ? '0 : {{VLEN - 3{1'b0}}, 3'b100});
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      npc_rst_load_q    <= 1'b1;
      npc_q             <= '0;
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_ex_valid_q <= FE_NONE;

    end 
    else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      icache_valid_q <= icache_dreq_i.valid;
      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
      end
      if (icache_dreq_i.ex.cause == INSTR_GUEST_PAGE_FAULT) begin
          icache_ex_valid_q <= FE_INSTR_GUEST_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == INSTR_PAGE_FAULT) begin
          icache_ex_valid_q <= FE_INSTR_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == INSTR_ACCESS_FAULT) begin
          icache_ex_valid_q <= FE_INSTR_ACCESS_FAULT;
        end else begin
          icache_ex_valid_q <= FE_NONE;
        end
    end
  end 

endmodule