// 重放逻辑
  // ICache->instr_realign->instr_scan->bp->instr_queue
  //      ^                             |       | 主要是重放判断
  //      |                             |<———————
  //      |_____________________________|

module fromtend #(
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
    
    input   logic [31:0]      boot_addr_i,               // 复位pc值

    input   bp_resolve_t      resolved_branch_i,         // 分支预测结果，用来更新分支预测器
    // ICache
    input   icache_data_req_t icache_dreq_i,  // 前端送到ICache的请求包
    output  icache_data_res_t icache_dreq_o,  // ICache返回给前端的响应包

    input   logic             backend_ready_i,

    output fetch_entry_t      fetch_entry_o,
    output logic              fetch_entry_valid_o
);
    
// =====================================
// Branch Prediction --- 分支预测
// =====================================
  
  // BTB更新信息：是否有效、更新地址、目标地址
  localparam type btb_update_t = struct packed {
    logic                        valid;
    logic [config_pkg::VLEN-1:0] pc;              // update at PC
    logic [config_pkg::VLEN-1:0] target_address;
  };

  //分支历史表更新信息：是否有效，更新地址，是否跳转
  localparam type bht_update_t = struct packed {
    logic                        valid;
    logic [config_pkg::VLEN-1:0] pc;     // update at PC
    logic                        taken;
  };

  localparam type bht_prediction_t = struct packed  {
    logic valid;
    logic taken;
  };

  // 返回地址栈：是否有效，返回地址
  localparam type ras_t = struct packed {
    logic                        valid;
    logic [config_pkg::VLEN-1:0] ra;
  };

  //分支魔表缓冲器：是否有效、目标地址
  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [config_pkg::VLEN-1:0] target_address;
  };

  logic [31:0]                  icache_vaddr_q ;
  logic [31:0]                  icache_data  ;
  logic                         icache_valid ;
  logic [31:0]                  icache_data_q;
  logic                         icache_valid_q;
  logic [config_pkg::VLEN-1:0]  icache_vaddr_q;
  logic                         instr_queue_ready;
  logic [1:0]                   instr_queue_consumed;
  logic [config_pkg::VLEN-1:0]  npc_d,npc_q;
  logic                         replay;
  logic [config_pkg::VLEN-1:0]  replay_addr;
  btb_prediction_t              btb_q;
  bht_prediction_t              bht_q;
  logic [1:0]                   taken_rvi_cf;
  logic [1:0]                   taken_rvc_cf;
  logic [config_pkg::VLEN-1:0]  predict_address;
  logic ras_push, ras_pop;
  logic [config_pkg::VLEN-1:0]  ras_update;
//===================
// instr_realign 
//===================
  // logic [1:0]                       is_compressed;
  logic [1:0]                       instruction_valid;
  logic [1:0][31:0]                 instr;
  logic [1:0][config_pkg::VLEN-1:0] addr;
  logic                             serving_unaligned;

  instr_realign i_instr_realign(
    .clk_i                    (clk_i),
    .rst_ni                   (rst_ni),
    .flush_i                  (icache_dreq_o.kill_s2),  // 在指令重放，整体刷新，预测错误，预测跳转时候刷新
    .valid_i                  (icache_valid_q),
    .address_i                (icache_vaddr_q),
    .data_i                   (icache_data_q),

    .instr_is_compressed_o    (),
    .serving_unaligned_o      (serving_unaligned),
    .valid_o                  (instruction_valid),
    .addr_o                   (addr),
    .instr_o                  (instr)
  )

//===================
// instr_scan
//===================  
  logic [1:0]                       is_return;
  logic [1:0]                       is_call;  
  logic [1:0]                       is_branch;
  logic [1:0]                       is_jalr;
  logic [1:0]                       is_jump;

  logic [1:0]                       rvi_return;
  logic [1:0]                       rvi_call;
  logic [1:0]                       rvi_branch;
  logic [1:0]                       rvi_jalr;
  logic [1:0]                       rvi_jump;
  logic [1:0][config_pkg::VLEN-1:0] rvi_imm;

  logic [1:0]                       rvc_branch;
  logic [1:0]                       rvc_jump;
  logic [1:0]                       rvc_jr;
  logic [1:0]                       rvc_return;
  logic [1:0]                       rvc_jalr;
  logic [1:0]                       rvc_call;
  logic [1:0][config_pkg::VLEN-1:0] rvc_imm;

  for (genvar i = 0; i < 2; i++) begin : gen_instr_scan
    instr_scan i_instr_scan (
        .instr_i     (instr[i]),

        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),

        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  // 判断指令
  for (genvar i = 0; i < 2; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

//===================
// Branch Prediction
//===================  
  btb_prediction_t  [1:0]                  btb_prediction;
  btb_update_t                             btb_update;
  bht_update_t                             bht_update;
  bht_prediction_t  [1:0]                  bht_prediction;
  bht_prediction_t  [1:0]                  bht_prediction_shifted; // 当指令是拼接指令的时候需要用上个周期的预测结果
  btb_prediction_t  [1:0]                  btb_prediction_shifted; 
  ras_t                                    ras_predict;
  cf_t              [1:0]                  cf_type;


  assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
  assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
  assign bht_prediction_shifted[1] = bht_prediction[addr[1][1]];
  assign btb_prediction_shifted[1] = btb_prediction[addr[1][1]];
  assign bht_update.valid          = resolved_branch_i.valid
                                    & (resolved_branch_i.cf_type == config_pkg::Branch);
  assign bht_update.pc             = resolved_branch_i.pc;
  assign bht_update.taken          = resolved_branch_i.is_taken;
  assign btb_update.valid          = resolved_branch_i.valid
                                    & resolved_branch_i.is_mispredict
                                    & (resolved_branch_i.cf_type == config_pkg::JumpR);
  assign btb_update.pc             = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // 没有必要判断使用哪一个，因为BTB和BHT是支持两条指令预测的，只需要判断是不是需要判断RAS
  // 需要移位操作，这样可以防止拼接地址导致预测错误
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    // 有记录就跳转，无记录就静态分支预测
    for (int i = 0; i < 2; i++) cf_type[i] = config_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    for (int i = 0; i < 2; i++) begin
        unique case ({
          is_branch[i], is_return[i], is_jump[i], is_jalr[i]
        })
          4'b0000: ;  
          4'b0001: begin
            ras_pop  = 1'b0;
            ras_push = 1'b0;
            if(btb_prediction_shifted[i].valid) begin
              predict_address = btb_prediction_shifted[i].target_address;
              cf_type[i] = config_pkg::JumpR;
            end
          end
          // its an unconditional jump to an immediate
          4'b0010: begin
            ras_pop = 1'b0;
            ras_push = 1'b0;
            taken_rvi_cf[i] = rvi_jump[i];
            taken_rvc_cf[i] = rvc_jump[i];
            cf_type[i] = config_pkg::Jump;
          end
          // return
          4'b0100: begin
            // make sure to only alter the RAS if we actually consumed the instruction
            ras_pop = ras_predict.valid & instr_queue_consumed[i];
            ras_push = 1'b0;
            predict_address = ras_predict.ra;
            cf_type[i] = config_pkg::Return;
          end
          // branch prediction
          4'b1000: begin
            ras_pop  = 1'b0;
            ras_push = 1'b0;
            // if we have a valid dynamic prediction use it
            if (bht_prediction_shifted[i].valid) begin
              taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
              taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
              // otherwise default to static prediction 
            end else begin
              // set if immediate is negative - static prediction
              taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][config_pkg::VLEN-1];
              taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][config_pkg::VLEN-1];
            end
            if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
              cf_type[i] = config_pkg::Branch;
            end
          end
          default: ;
        endcase
        
        if (is_call[i]) begin
          ras_push   = instr_queue_consumed[i];
          ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
        end
        if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
          predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
        end
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
    .valid_i                (instruction_valid)
    .instr_i                (instr),
    .addr_i                 (addr),
    .backend_ready_i        (backend_ready_i),
    .cf_type_i              (cf_type),
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

  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;
  
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
    automatic logic [config_pkg::VLEN-1:0] fetch_address;

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
        fetch_address[config_pkg::VLEN-1:config_pkg::FETCH_ALIGN_BITS] + 1, {config_pkg::FETCH_ALIGN_BITS{1'b0}}
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

    icache_dreq_o.vaddr = fetch_address;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      npc_rst_load_q    <= 1'b1;
      npc_q             <= '0;
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      // icache_gpaddr_q   <= 'b0;
      // icache_tinst_q    <= 'b0;
      // icache_gva_q      <= 1'b0;
      // icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;
    end 
    else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      icache_valid_q <= icache_dreq_i.valid;
      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
        btb_q <= btb_prediction[1];
        bht_q <= bht_prediction[1];
      end
    end
  end 

endmodule