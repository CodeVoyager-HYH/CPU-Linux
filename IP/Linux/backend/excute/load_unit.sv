// Load buffer 是无序的，因为发射是经过数据冲突检查的，所以不需要使用队列，只需要前导零来判断哪一个有空写入就行
module load_unit 
  import config_pkg::*;
#(
  parameter type dcache_req_i_t = logic,
  parameter type dcache_req_o_t = logic,
  parameter type exception_t = logic,
  parameter type lsu_ctrl_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // LSU 交互
  input   logic       valid_i,    // 表示当前load有效
  output  logic       pop_ld_o,   // 表示弹出的指令有效
  input   lsu_ctrl_t  lsu_ctrl_i, 

  // 结果输出
  output logic                    valid_o,                // load结果有效
  output logic [POINTER_SIZE-1:0] pointer_o,              // 对应指令的事务ID
  output logic [        XLEN-1:0] result_o,               // load结果
  output exception_t              ex_o                    // 异常信息

  // MMU
  output logic                    mmu_vaddr_valid_o,      // mmu转换许可
  output logic [       VLEN-1:0]  vaddr_o,                // 要转换的虚拟地址
  input  logic [           55:0]  paddr_i,                // MMU转换后的物理地址
  input  exception_t              ex_i,                   // MMU可能返回的异常
  input  logic                    dtlb_hit_i,             // DTLB命中标志
  input  logic [   PPN_SIZE-1:0]  dtlb_ppn_i,             // 页号

  // Store Unit
  output logic [           11:0]  page_offset_o,          // 当前load地址页内偏移
  input  logic                    page_offset_matches_i,  // 是否与store单元的地址冲突
  input  logic                    store_buffer_empty_i,   // store buffer是否为空
  input  logic [POINTER_SIZE-1:0] commit_pointer_i,     

  // Dcache
  input  dcache_req_o_t           req_port_i,             // DCache响应（data_gnt, data_rvalid, data_rdata等）
  output dcache_req_i_t           req_port_o,             // DCache请求（data_req, tag_valid, kill_req等）
  input  logic                    dcache_wbuffer_not_ni_i // DCache写缓冲是否存在非幂等操作
);

  logic stall_ni;
  logic not_commit_time;
  logic paddr_ni;
  logic inflight_stores;
  // 判断物理地址是否在非幂等区域
  assign paddr_ni = config_pkg::is_inside_nonidempotent_regions( {{52 - PPN_SIZE{1'b0}}, dtlb_ppn_i, 12'd0} );
  assign vaddr_o                  = lsu_ctrl_i.vaddr;
  assign not_commit_time          = commit_pointer_i != lsu_ctrl_i.pointer;
  assign inflight_stores          = (!dcache_wbuffer_not_ni_i || !store_buffer_empty_i);
  assign page_offset_o            = lsu_ctrl_i.vaddr[11:0];
  // TODO:设计Cache时记得修改tag
  assign req_port_o.address_tag   = paddr_i[DCACHE_TAG_WIDTH + DCACHE_INDEX_WIDTH-1 : DCACHE_INDEX_WIDTH];
  // 非幂等访问停滞信号
  // 停止条件：（有未完成的写操作 或 指令未提交）且 （是非密等区域）
  assign stall_ni = (inflight_stores || not_commit_time) && (paddr_ni);
  
  // 异常
  assign ex_o.cause = ex_i.cause;
  assign ex_o.tval = ex_i.tval;

  always_comb begin : rvalid_output
    pointer_o  = ldbuf_q[ldbuf_rindex].pointer;
    valid_o    = 1'b0;
    ex_o.valid = 1'b0;

    if (req_port_i.data_rvalid && !ldbuf_flushed_q[ldbuf_rindex]) begin // 缓存返回有效数据，对应加载请求未被冲刷
      if ((ldbuf_last_id_q != ldbuf_rindex) || !req_port_o.kill_req) valid_o = 1'b1;  
      if (ex_i.valid && (state_q == SEND_TAG)) begin // 若在SEND_TAG状态收到异常，说明异常与当前加载请求相关
        valid_o    = 1'b1;
        ex_o.valid = 1'b1;
      end
    end
    // 地址转换阶段（WAIT_TRANSLATION）发生异常，且无缓存数据返回、请求有效
    if ((state_q == WAIT_TRANSLATION) && !req_port_i.data_rvalid && ex_i.valid && valid_i) begin 
      pointer_o   = lsu_ctrl_i.pointer;
      valid_o     = 1'b1;
      ex_o.valid  = 1'b1;
    end
  end


  // FSM
  enum logic [3:0] {
    IDLE,                   // 空闲状态
    WAIT_GNT,               // 等待数据缓存
    SEND_TAG,               // 向缓存发送物理地址标签，完成缓存访问
    WAIT_PAGE_OFFSET,       // 等待缓冲区的冲突地址完成
    ABORT_TRANSACTION,      // TLB未命中，暂停流水线(取消访问数据)
    ABORT_TRANSACTION_NI,   // 访问设备寄存器
    WAIT_TRANSLATION,       // 等待MMU完成地址转换
    WAIT_FLUSH,             // 冲刷
    WAIT_WB_EMPTY           // 只访问一次的设备(多次访问会造成数据变换)
  }
      state_d, state_q;

  // Load Buffer
  typedef struct packed {
    logic [$clog2(NR_SB_ENTRIES):0] pointer;         // scoreboard identifier
    logic [XLEN_ALIGN_BYTES-1:0]    address_offset;  // least significant bits of the address
    fu_op                           operation;      
  } ldbuf_t;

  localparam int unsigned REQ_ID_BITS = $clog2(LOAD_BUFF_SIZE) ;
  typedef logic [REQ_ID_BITS-1:0] ldbuf_id_t;

  logic       [LOAD_BUFF_SIZE-1:0] ldbuf_valid_q, ldbuf_valid_d;
  logic       [LOAD_BUFF_SIZE-1:0] ldbuf_flushed_q, ldbuf_flushed_d;
  ldbuf_t     [LOAD_BUFF_SIZE-1:0] ldbuf_q;
  logic       ldbuf_empty, ldbuf_full;
  ldbuf_id_t  ldbuf_free_index;
  ldbuf_t     ldbuf_d;
  ldbuf_id_t  ldbuf_windex;
  ldbuf_t     ldbuf_rdata;
  ldbuf_id_t  ldbuf_rindex;
  ldbuf_id_t  ldbuf_last_id_q;

  assign ldbuf_d = {
    lsu_ctrl_i.pointer, lsu_ctrl_i.vaddr[XLEN_ALIGN_BYTES-1:0], lsu_ctrl_i.operation
  };
  assign ldbuf_rindex = ldbuf_id_t'(req_port_i.data_rid) ;
  assign ldbuf_rdata  = ldbuf_q[ldbuf_rindex];
  assign ldbuf_full   = &ldbuf_valid_q;

  lzc #(
          .WIDTH(LOAD_BUFF_SIZE),
          .MODE (1'b0)                       
      ) lzc_windex_i (
          .in_i   (~ldbuf_valid_q),
          .cnt_o  (ldbuf_free_index),
          .empty_o(ldbuf_empty)
      );
  assign ldbuf_windex = ldbuf_free_index;

  always_comb begin : ldbuf_comb
    ldbuf_flushed_d = ldbuf_flushed_q;
    ldbuf_valid_d   = ldbuf_valid_q;

    if (flush_i) begin
      ldbuf_flushed_d = '1;
    end
    if (req_port_i.data_rvalid) begin
      ldbuf_valid_d[ldbuf_rindex] = 1'b0;
    end
    if (req_port_o.data_req & req_port_i.data_gnt) begin
      ldbuf_flushed_d[ldbuf_windex] = 1'b0;
      ldbuf_valid_d[ldbuf_windex]   = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : ldbuf_ff
    if (!rst_ni) begin
      ldbuf_flushed_q <= '0;
      ldbuf_valid_q   <= '0;
      ldbuf_last_id_q <= '0;
      ldbuf_q         <= '0;
    end else begin
      ldbuf_flushed_q <= ldbuf_flushed_d;
      ldbuf_valid_q   <= ldbuf_valid_d;
      if (req_port_o.data_req & req_port_i.data_gnt) begin  // 总线仲裁+数据有效
        ldbuf_last_id_q       <= ldbuf_windex;
        ldbuf_q[ldbuf_windex] <= ldbuf_d;
      end
    end
  end

  // Load 状态机转换
  always_comb begin
    automatic logic accept_req;
    accept_req           = (valid_i && (!ldbuf_full ));

    state_d              = state_q;
    mmu_vaddr_valid_o    = 1'b0;
    req_port_o.data_req  = 1'b0;
    req_port_o.kill_req  = 1'b0;
    req_port_o.tag_valid = 1'b0;
    req_port_o.data_be   = lsu_ctrl_i.be;
    req_port_o.data_size = extract_transfer_size(lsu_ctrl_i.operation);
    pop_ld_o             = 1'b0;

    case (state_q)
      IDLE: begin
        if (accept_req ) begin // 请求有效
          mmu_vaddr_valid_o = 1'b1;
          if (!page_offset_matches_i) begin // 和Store单元没有冲突
            req_port_o.data_req = 1'b1;     // 向Cache发出数据请求
            if (!req_port_i.data_gnt) begin // 判断仲裁，如果未获得cache的授权则去 WAIT_GNT
              state_d = WAIT_GNT;
            end else begin
              if (!dtlb_hit_i) begin  // 页表转换
                state_d = ABORT_TRANSACTION;
              end else begin
                if (!stall_ni) begin  // 非幂等性冲突
                  state_d  = SEND_TAG;
                  pop_ld_o = 1'b1;
                end else begin
                  state_d = ABORT_TRANSACTION_NI;
                end
              end
            end
          end else begin
            state_d = WAIT_PAGE_OFFSET;
          end
        end
      end

      WAIT_PAGE_OFFSET: begin // 暂停Load单元 等待和Store单元冲突结束
        if (!page_offset_matches_i) begin // 冲突结束，重新尝试获取cache授权
          state_d = WAIT_GNT;
        end
      end

      WAIT_GNT: begin 
        mmu_vaddr_valid_o   = 1'b1;
        req_port_o.data_req = 1'b1;
        if (req_port_i.data_gnt) begin
          if (!dtlb_hit_i) begin
            state_d = ABORT_TRANSACTION;
          end else begin
            if (!stall_ni) begin
              state_d  = SEND_TAG;
              pop_ld_o = 1'b1;
            end else  begin
              state_d = ABORT_TRANSACTION_NI;
            end
          end
        end
      end

      SEND_TAG: begin
        req_port_o.tag_valid = 1'b1;
        state_d = IDLE;

        if (accept_req) begin
          mmu_vaddr_valid_o = 1'b1;
          if (!page_offset_matches_i) begin
            req_port_o.data_req = 1'b1;
            if (!req_port_i.data_gnt) begin
              state_d = WAIT_GNT;
            end else begin
              if (!dtlb_hit_i) begin
                state_d = ABORT_TRANSACTION;
              end else begin
                if (!stall_ni) begin
                  state_d  = SEND_TAG;
                  pop_ld_o = 1'b1;
                end else begin
                  state_d = ABORT_TRANSACTION_NI;
                end
              end
            end
          end else begin
            state_d = WAIT_PAGE_OFFSET;
          end
        end
        // ----------
        // Exception
        // ----------
        if (ex_i.valid) begin // 如果发生异常立即取消当前数据缓存发起的加载请求
          req_port_o.kill_req = 1'b1;
        end
      end

      WAIT_FLUSH: begin
        req_port_o.kill_req = 1'b1;
        req_port_o.tag_valid = 1'b1;
        state_d = IDLE;
      end

      default: begin
        if (state_q == ABORT_TRANSACTION) begin 
          req_port_o.kill_req = 1'b1;
          req_port_o.tag_valid = 1'b1;
          state_d = WAIT_TRANSLATION;
        end else if (state_q == ABORT_TRANSACTION_NI ) begin
          req_port_o.kill_req = 1'b1;
          req_port_o.tag_valid = 1'b1;
          state_d = WAIT_WB_EMPTY;
        end else if (state_q == WAIT_WB_EMPTY && dcache_wbuffer_not_ni_i) begin
          state_d = WAIT_TRANSLATION;
        end else if(state_q == WAIT_TRANSLATION ) begin
          mmu_vaddr_valid_o = 1'b1;
          if (dtlb_hit_i) state_d = WAIT_GNT;

          if (ex_i.valid) begin
            state_d  = IDLE;
            pop_ld_o = ~req_port_i.data_rvalid;
          end
        end else begin
          state_d = IDLE;
        end
      end
    endcase

    if (flush_i) begin
      state_d = WAIT_FLUSH;
    end
  end

  //=======================
  //  符号扩展+result 输出
  //=======================

  //注意这里使用的是Dcache中的数据，如果Dcache未命中则需要等待命中后才可以输出数据
  
  // 对齐
  logic [XLEN-1:0] shifted_data;
  assign shifted_data = req_port_i.data_rdata >> {ldbuf_rdata.vaddr[XLEN_ALIGN_BYTES-1:0], 3'b000};

  logic [        (XLEN/8)-1:0] rdata_sign_bits; // 符号位
  logic [XLEN_ALIGN_BYTES-1:0] rdata_offset;    
  logic rdata_sign_bit, rdata_is_signed;
  
  for (genvar i = 0; i < (XLEN / 8); i++) begin : gen_sign_bits
    assign rdata_sign_bits[i] = req_port_i.data_rdata[(i+1)*8-1]; // 第 i 个字节的最高位（bit (i+1)*8-1）
  end

  assign rdata_offset       =  ((ldbuf_rdata.operation == riscv_pkg::LW)) ? ldbuf_rdata.address_offset + 3 :
                                (ldbuf_rdata.operation == ariane_pkg::LH) ? ldbuf_rdata.address_offset + 1 :ldbuf_rdata.address_offset;

  // 判断是否需要符号扩展（如 LB/LH/LW 需要，LBU/LHU/LWU 不需要）
  assign rdata_is_signed    =   ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::LH,  ariane_pkg::LB};
  // 符号位 = （需要符号扩展时，选择对应偏移的符号位)
  assign rdata_sign_bit = (rdata_is_signed && rdata_sign_bits[rdata_offset]) ;

  always_comb begin
    unique case (ldbuf_rdata.operation)
      LW, LWU:
        result_o = {{XLEN - 32{rdata_sign_bit}}, shifted_data[31:0]};
      LH, LHU:
        result_o = {{XLEN - 32 + 16{rdata_sign_bit}}, shifted_data[15:0]};
      LB, LBU:
        result_o = {{XLEN - 32 + 24{rdata_sign_bit}}, shifted_data[7:0]};
      default: 
        result_o = shifted_data[XLEN-1:0];
    endcase
  end
endmodule