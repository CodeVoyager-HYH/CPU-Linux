// 负责管理存储和原子操作，负责接收Store/AMO请求，处理地址转换，数据对齐，异常反馈
// 有两个队列，一个是推测队列，一个是提交队列，如果
module store_unit 
  import config_pkg::*;
#(
  parameters
) (
  input logic clk_i,
  input logic rst_ni,

  // 控制信号
  input   logic                     flush_i,
  input   logic                     stall_st_pending_i,     // 防止未推测结束的指令进入提交队列
  output  logic                     no_st_pending_o,        // 表示没有store操作正在进行
  output  logic                     store_buffer_empty_o,   // Store buffer 是否为空,在Load unit中使用
  output  logic                     pop_st_o,               // 用于仲裁器弹入新的指令

  // 传入的新指令
  input   logic                     valid_i,                // 指令有效信号
  input   lsu_ctrl_t                lsu_ctrl_i,             // 指令信息

  // 提交相关
  input   logic                     commit_i,               // 指令提交信号
  input   logic                     commit_ready_o,         // 存储缓冲区准备好接收提交指令
  input   logic                     amo_valid_commit_i      // AMO操作提交有效

  // 异常 与 MMU
  output  logic                     valid_o,                // 存储结果有效
  output  logic                     translation_req_o,      // MMU 翻译请求
  output  logic [POINTER_SIZE-1:0]  pointer_o,              // 用于乱序执行，在scoreboard中的下标
  output  logic [VLEN-1:0]          vaddr_o,                // 虚拟地址
    // 来自MMU/DTLB的输入
  input   logic [55:0]              paddr_i,                // 翻译后的物理地址
  input   exception_t               ex_i,                   // 外部异常（如地址翻译失败）
  input   logic                     dtlb_hit_i,             // DTLB命中信号

  // 与Load单元的地址冲突检测
  input   logic [11:0]              page_offset_i,          // Load单元的页内偏移（用于冲突检测）
  output  logic                     page_offset_matches_o,  // 页内偏移匹配（存在Store-Load冲突）
  
  // AMO操作接口（与缓存交互）
  output  amo_req_t                 amo_req_o,              // AMO请求
  input   amo_resp_t                amo_resp_i,             // AMO响应
  
  // 数据缓存接口
  input   dcache_req_o_t            req_port_i,             // 缓存输入请求
  output  dcache_req_i_t            req_port_o              // 缓存输出响应
);
  
  // FSM
  enum logic [1:0] {
    IDLE,             // 空闲
    VALID_STORE,      // 有效存储状态（已获取地址翻译）
    WAIT_TRANSLATION, // 等待地址翻译完成
    WAIT_STORE_READY  // 等待存储缓冲区就绪
  }state_d, state_q;

  // 存储缓冲区控制信号
  logic st_ready;                        // 存储缓冲区就绪
  logic st_valid;                        // 存储操作有效（含冲刷判断）
  logic st_valid_without_flush;          // 存储操作有效（不含冲刷判断）
  logic instr_is_amo;                    // 当前指令是AMO操作
  assign instr_is_amo = (lsu_ctrl_i.operation == (AMO_LRW || AMO_MINDU))? 1'b1: 1'b0;  

  // 寄存器：保存数据、字节使能、数据大小（用于地址翻译后的周期）
  logic [XLEN-1:0]              st_data_n, st_data_q;       // 存储数据
  logic [XLEN_ALIGN_BYTES-1:0]  st_be_n, st_be_q;           // 字节使能
  logic [1:0] st_data_size_n, st_data_size_q;               // 数据大小
  amo_t amo_op_d, amo_op_q;                                 // AMO操作类型

  // 跟踪指令顺序
  logic [POINTER_SIZE-1:0] trans_id_n, trans_id_q;
  
  // 存储缓冲区与AMO缓冲区的控制信号
  logic store_buffer_valid, amo_buffer_valid;
  logic store_buffer_ready, amo_buffer_ready;
  // 普通存储与AMO操作的信号分流
  assign store_buffer_valid = st_valid & (amo_op_q == AMO_NONE);  // 普通存储有效
  assign amo_buffer_valid = st_valid & (amo_op_q != AMO_NONE);    // AMO操作有效
  assign st_ready = store_buffer_ready & amo_buffer_ready;        // 存储就绪需两者均就绪

  // 外部接口赋值
  assign vaddr_o    = lsu_ctrl_i.vaddr; // 输出虚拟地址到MMU
  assign pointer_o  = trans_id_q;       // 输出事务ID到Issue阶段

  // 状态机更新
  always_comb begin
    // Define
    translation_req_o      = 1'b0;
    valid_o                = 1'b0;
    st_valid               = 1'b0;  
    st_valid_without_flush = 1'b0; 
    pop_st_o               = 1'b0;  
    ex_o                   = ex_i;  
    trans_id_n             = lsu_ctrl_i.trans_id;  
    state_d                = state_q;  

    case (state_q)
      IDLE  : begin // 空闲状态
        if(valid_i) begin
          state_d = VALID_STORE;
          translation_req_o = 1'b1;
          pop_st_o = 1'b1;

          if(!dtlb_hit_i) begin // TLB是时序逻辑所以直接可以判断是否是miss
            state_d = WAIT_TRANSLATION;
            pop_st_o = 1'b0;
          end

          if (!st_ready) begin  // 缓冲区满了，等待空闲
            state_d  = WAIT_STORE_READY;
            pop_st_o = 1'b0;
          end

        end
      end

      VALID_STORE : begin // 可以向缓冲区写入
        valid_o = 1'b1;
        if(!flush) st_valid = 1'b1; // 未冲刷的写请求
        st_valid_without_flush = 1'b1;  
      
        if (valid_i && !instr_is_amo) begin //如果新指令不是AMO指令

          translation_req_o = 1'b1;
          state_d = VALID_STORE;
          pop_st_o = 1'b1;

          if (!dtlb_hit_i) begin
            state_d  = WAIT_TRANSLATION;
            pop_st_o = 1'b0;
          end

          if (!st_ready) begin
            state_d  = WAIT_STORE_READY;
            pop_st_o = 1'b0;
          end
        end else begin
          state_d = IDLE;
        end
      end

      WAIT_STORE_READY: begin
        translation_req_o = 1'b1;
        if (st_ready && dtlb_hit_i) begin
          state_d = IDLE;
        end
      end

      default: begin
        if (state_q == WAIT_TRANSLATION) begin
          translation_req_o = 1'b1;

          if (dtlb_hit_i) begin
            state_d = IDLE;
          end
        end
      end
    endcase

    if (ex_i.valid && (state_q != IDLE)) begin  //异常处理，立刻弹回指令
      pop_st_o = 1'b1;
      st_valid = 1'b0;
      state_d  = IDLE;
      valid_o  = 1'b1;
    end

    if (flush_i) state_d = IDLE;
  end

  // AMO
  always_comb begin
    st_be_n   = lsu_ctrl_i.be;
    st_data_n = lsu_ctrl_i.data[XLEN-1:0] ;
    st_data_size_n  = extract_transfer_size(lsu_ctrl_i.operation);

    case (lsu_ctrl_i.operation)
      AMO_LRW, AMO_LRD:     amo_op_d = AMO_LR;
      AMO_SCW, AMO_SCD:     amo_op_d = AMO_SC;
      AMO_SWAPW, AMO_SWAPD: amo_op_d = AMO_SWAP;
      AMO_ADDW, AMO_ADDD:   amo_op_d = AMO_ADD;
      AMO_ANDW, AMO_ANDD:   amo_op_d = AMO_AND;
      AMO_ORW, AMO_ORD:     amo_op_d = AMO_OR;
      AMO_XORW, AMO_XORD:   amo_op_d = AMO_XOR;
      AMO_MAXW, AMO_MAXD:   amo_op_d = AMO_MAX;
      AMO_MAXWU, AMO_MAXDU: amo_op_d = AMO_MAXU;
      AMO_MINW, AMO_MIND:   amo_op_d = AMO_MIN;
      AMO_MINWU, AMO_MINDU: amo_op_d = AMO_MINU;
      default:              amo_op_d = AMO_NONE;
    endcase
  end

  // Buffer 实例化

    // 普通访存指令
  store_buffer #(
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t)
  ) store_buffer_i (
      .clk_i,
      .rst_ni,
      .flush_i,
      .stall_st_pending_i,
      .no_st_pending_o,
      .store_buffer_empty_o,
      .page_offset_i,
      .page_offset_matches_o,
      .commit_i,
      .commit_ready_o,
      .ready_o              (store_buffer_ready),
      .valid_i              (store_buffer_valid),
      .valid_without_flush_i(st_valid_without_flush),
      .paddr_i,
      .rvfi_mem_paddr_o     (rvfi_mem_paddr_o),
      .data_i               (st_data_q),
      .be_i                 (st_be_q),
      .data_size_i          (st_data_size_q),
      .req_port_i           (req_port_i),
      .req_port_o           (req_port_o)
  );

    // AMO原子指令
  amo_buffer i_amo_buffer (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i           (amo_buffer_valid),
      .ready_o           (amo_buffer_ready),
      .paddr_i           (paddr_i),
      .amo_op_i          (amo_op_q),
      .data_i            (st_data_q),
      .data_size_i       (st_data_size_q),
      .amo_req_o         (amo_req_o),
      .amo_resp_i        (amo_resp_i),
      .amo_valid_commit_i(amo_valid_commit_i),
      .no_st_pending_i   (no_st_pending_o)
  );

  // 时序转换
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q        <= IDLE;
      st_be_q        <= '0;
      st_data_q      <= '0;
      st_data_size_q <= '0;
      trans_id_q     <= '0;
      amo_op_q       <= AMO_NONE;
    end else begin
      state_q        <= state_d;
      st_be_q        <= st_be_n;
      st_data_q      <= st_data_n;
      trans_id_q     <= trans_id_n;
      st_data_size_q <= st_data_size_n;
      amo_op_q       <= amo_op_d;
    end
  end
endmodule