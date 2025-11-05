module lsu 
  import config_pkg::*;
  import mmu_pkg::*;
#(
  parameter type fu_data_t      = logic,
  parameter type dcache_req_i_t = logic,    
  parameter type dcache_req_o_t = logic,   
  parameter type exception_t    = logic,     
  parameter type fu_data_t      = logic,         
  parameter type icache_areq_t  = logic,     
  parameter type icache_arsp_t  = logic,    
  parameter type icache_dreq_t  = logic,   
  parameter type icache_drsp_t  = logic,    
  parameter type lsu_ctrl_t     = logic
) (
  input   logic     clk_i,
  input   logic     rst_ni,
  
  // 控制信号
  input   logic     flush_i,
  input   logic     stall_st_pending_i,
  input   logic     amo_valid_commit_i,  
  output  logic     no_st_pending_o,

  input   fu_data_t                 fu_data_i,
  input   logic                     lsu_valid_i,
  output  logic                     lsu_ready_o,
  
  // 输出结果与异常
  output  logic                     lsu_result_valid_o,
  output  logic [         XLEN-1:0] lsu_result_o,
  output  logic [ POINTER_SIZE-1:0] lsu_pointer_o,
  output  exception_t               load_exception_o, 

  // 提交
  input   logic                     commit_i,             
  output  logic                     commit_ready_o,     
  input   logic [ POINTER_SIZE-1:0] commit_pointer_i,  

  // 与数据缓存交互
  input   icache_arsp_t             icache_areq_i,
  output  icache_areq_t             icache_areq_o,

  // 与 MMU 交互
    // CSR
  input   priv_lvl_t                priv_lvl_i,           // 当前特权级（M/S/U）
  input   priv_lvl_t                ld_st_priv_lvl_i,     // 加载/存储的特权级
  input   logic                     sum_i,                // 监督模式用户内存访问使能（SUM）
  input   logic                     mxr_i,                // 可执行内存可读（MXR）
  input   logic [XLEN-1:0]          satp_i,               // SATP寄存器的PPN（页表基址）
    // TLB冲刷信号
  input   logic [ASID_WIDTH-1:0]    asid_to_be_flushed_i, // 待冲刷的ASID,避免不必要的全冲刷
  input   logic                     flush_tlb_i,          // TLB全冲刷
  output  logic                     itlb_miss_o,          // ITLB未命中（性能计数）
  output  logic                     dtlb_miss_o,          // DTLB未命中（性能计数）

  // Dcache接口
  input   dcache_req_o_t [2:0]      dcache_req_ports_i,       // 缓存输入请求（3个端口：MMU/加载/存储）
  output  dcache_req_i_t [2:0]      dcache_req_ports_o,       // 缓存输出请求
  input   logic                     dcache_wbuffer_empty_i,   // DCache写缓冲区空
  input   logic                     dcache_wbuffer_not_ni_i,  // DCache写缓冲区非空

  // AMO 接口
  output  amo_req_t                 amo_req_o,                // AMO请求（原子操作，如SWAP/ADD）
  input   amo_resp_t                amo_resp_i                // AMO响应（原子操作结果）

  //  PMP 配置
  input pmpcfg_t [NrPMPEntries-1:0]           pmpcfg_i,   // PMP配置（权限+模式）
  input logic    [NrPMPEntries-1:0][PLEN-3:0] pmpaddr_i   // PMP地址配置
);

  // 数据未对齐
  logic data_misaligned;

  lsu_ctrl_t lsu_ctrl, lsu_ctrl_byp;
  logic pop_st;  // 存储指令弹出
  logic pop_ld;  // 加载指令弹出

  // 地址计算
  logic [VLEN-1:0]      vaddr_i;
  logic [XLEN-1:0]      vaddr_xlen;
  logic                 overflow;
  logic [(XLEN/8)-1:0]  be_i; // 字节使能

  // 地址计算
  assign vaddr_xlen = $unsigned($signed(fu_data_i.imm) + $signed(fu_data_i.operand_a));
  assign vaddr_i    = vaddr_xlen[VLEN-1:0];

  // 64位下地址溢出：SV39要求地址低39位以外的全0或全1（符号扩展）
  assign overflow   = (!((&vaddr_xlen[XLEN-1:38]) == 1'b1 || (|vaddr_xlen[XLEN-1:38]) == 1'b0));

  // 加载/存储有效信号（标记当前指令类型）
  logic st_valid_i;  // 存储指令有效
  logic ld_valid_i;  // 加载指令有效
  
  // MMU翻译请求（加载/存储/加速器）
  logic ld_translation_req;                  // 加载翻译请求
  logic st_translation_req, cva6_st_translation_req, acc_st_translation_req;  // 存储翻译请求
  
  // 加载/存储的虚拟地址、陷阱指令、虚拟化标记
  logic [VLEN-1:0] ld_vaddr, st_vaddr;  // 加载/存储虚拟地址
  logic [31:0] ld_tinst, st_tinst;              // 加载/存储陷阱指令
  
  // MMU仲裁信号（CVA6与加速器共享MMU）
  logic translation_req, cva6_translation_req, acc_translation_req;  // 总翻译请求
  logic translation_valid, cva6_translation_valid;                  // 翻译有效
  logic [VLEN-1:0] mmu_vaddr, cva6_mmu_vaddr, acc_mmu_vaddr; // MMU虚拟地址
  logic [PLEN-1:0] mmu_paddr, cva6_mmu_paddr, acc_mmu_paddr, lsu_paddr; // 物理地址
  logic [31:0] mmu_tinst;                      // MMU陷阱指令
  logic mmu_hs_ld_st_inst, mmu_hlvx_inst;      // MMU虚拟化标记
  input logic en_ld_st_translation_i,
  
  // 异常信号（MMU/PMP/未对齐）
  exception_t mmu_exception, cva6_mmu_exception, acc_mmu_exception;
  exception_t pmp_exception;
  
  // PMP与ICache交互信号
  icache_areq_t pmp_icache_areq_i;             // PMP输入的ICache请求
  logic pmp_translation_valid;                 // PMP翻译有效
  
  // DTLB命中与PPN（页帧号）
  logic dtlb_hit, cva6_dtlb_hit, acc_dtlb_hit; // DTLB命中
  logic [PPNW-1:0] dtlb_ppn, cva6_dtlb_ppn, acc_dtlb_ppn; // DTLB PPN
  
  // 加载/存储结果与事务ID
  logic ld_valid;  // 加载结果有效
  logic [POINTER_SIZE-1:0] ld_trans_id;  // 加载事务ID
  logic [XLEN-1:0] ld_result;  // 加载结果
  logic st_valid;  // 存储结果有效
  logic [POINTER_SIZE-1:0] st_trans_id;  // 存储事务ID
  logic [XLEN-1:0] st_result;  // 存储结果
  
  // 地址冲突检测（加载与未提交存储）
  logic [11:0] page_offset;  // 加载页内偏移（12位，与存储匹配）
  logic page_offset_matches;  // 页内偏移匹配（1=存在冲突）
  
  // 未对齐异常信号
  exception_t misaligned_exception, cva6_misaligned_exception, acc_misaligned_exception;
  exception_t ld_ex, st_ex;  // 加载/存储最终异常
  
  // 存储缓冲区空标记
  logic store_buffer_empty;


  //============================
  //  MMU 实例化
  //============================
    cva6_mmu #(
        .CVA6Cfg       (CVA6Cfg),       // CVA6配置
        .exception_t   (exception_t),   // 异常类型
        .icache_areq_t (icache_areq_t), // ICache请求类型
        .icache_arsp_t (icache_arsp_t), // ICache响应类型
        .icache_dreq_t (icache_dreq_t), // ICache数据请求类型
        .icache_drsp_t (icache_drsp_t), // ICache数据响应类型
        .dcache_req_i_t(dcache_req_i_t),// DCache请求类型
        .dcache_req_o_t(dcache_req_o_t),// DCache响应类型
        .HYP_EXT       (HYP_EXT)        // 是否支持Hypervisor
    ) i_cva6_mmu (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        // 虚拟内存使能
        .enable_translation_i(enable_translation_i),
        .enable_g_translation_i(enable_g_translation_i),
        .en_ld_st_translation_i(en_ld_st_translation_i),
        .en_ld_st_g_translation_i(en_ld_st_g_translation_i),
        // ICache接口
        .icache_areq_i(icache_areq_i),
        .icache_areq_o(pmp_icache_areq_i),  // MMU输出给PMP的ICache请求
        // 未对齐异常旁路
        .misaligned_ex_i(misaligned_exception),
        // LSU请求
        .lsu_req_i(translation_req),        // LSU翻译请求
        .lsu_vaddr_i(mmu_vaddr),           // LSU虚拟地址
        .lsu_tinst_i(mmu_tinst),           // LSU陷阱指令
        .lsu_is_store_i(st_translation_req),// 是否为存储操作
        .csr_hs_ld_st_inst_o(csr_hs_ld_st_inst_o), // HS标记输出
        // DTLB结果（同周期返回）
        .lsu_dtlb_hit_o(dtlb_hit),         // DTLB命中
        .lsu_dtlb_ppn_o(dtlb_ppn),         // DTLB PPN
        // MMU翻译结果（多周期后返回）
        .lsu_valid_o(pmp_translation_valid),// 翻译有效（输出给PMP）
        .lsu_paddr_o(lsu_paddr),           // 物理地址（输出给PMP）
        .lsu_exception_o(pmp_exception),   // MMU异常（输出给PMP）
        // 特权级与虚拟化状态
        .priv_lvl_i(priv_lvl_i),
        .v_i(v_i),
        .ld_st_priv_lvl_i(ld_st_priv_lvl_i),
        .ld_st_v_i(ld_st_v_i),
        .sum_i(sum_i),
        .vs_sum_i(vs_sum_i),
        .mxr_i(mxr_i),
        .vmxr_i(vmxr_i),
        // 虚拟化标记
        .hlvx_inst_i(mmu_hlvx_inst),
        .hs_ld_st_inst_i(mmu_hs_ld_st_inst),
        // 页表与TLB配置
        .satp_ppn_i(satp_ppn_i),
        .vsatp_ppn_i(vsatp_ppn_i),
        .hgatp_ppn_i(hgatp_ppn_i),
        .asid_i(asid_i),
        .vs_asid_i(vs_asid_i),
        .asid_to_be_flushed_i(asid_to_be_flushed_i),
        .vmid_i(vmid_i),
        .vmid_to_be_flushed_i(vmid_to_be_flushed_i),
        .vaddr_to_be_flushed_i(vaddr_to_be_flushed_i),
        .gpaddr_to_be_flushed_i(gpaddr_to_be_flushed_i),
        .flush_tlb_i(flush_tlb_i),
        .flush_tlb_vvma_i(flush_tlb_vvma_i),
        .flush_tlb_gvma_i(flush_tlb_gvma_i),
        // 性能计数
        .itlb_miss_o(itlb_miss_o),
        .dtlb_miss_o(dtlb_miss_o),
        // DCache接口（用于页表访问）
        .req_port_i(dcache_req_ports_i[0]),
        .req_port_o(dcache_req_ports_o[0]),
        // PMP配置（MMU内部可能需PMP检查页表访问）
        .pmpcfg_i(pmpcfg_i),
        .pmpaddr_i(pmpaddr_i)
    );


  // ------------------
  // PMP
  // ------------------

  pmp_data_if #(
      .icache_areq_t(icache_areq_t),
      .exception_t  (exception_t)
  ) i_pmp_data_if (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .icache_areq_i       (pmp_icache_areq_i),
      .icache_areq_o       (icache_areq_o),
      .icache_fetch_vaddr_i(icache_areq_i.fetch_vaddr),
      .lsu_valid_i         (pmp_translation_valid),
      .lsu_paddr_i         (lsu_paddr),
      .lsu_vaddr_i         (mmu_vaddr),
      .lsu_exception_i     (pmp_exception),
      .lsu_is_store_i      (st_translation_req),
      .lsu_valid_o         (translation_valid),
      .lsu_paddr_o         (mmu_paddr),
      .lsu_exception_o     (mmu_exception),
      .priv_lvl_i          (priv_lvl_i),
      .v_i                 (v_i),
      .ld_st_priv_lvl_i    (ld_st_priv_lvl_i),
      .ld_st_v_i           (ld_st_v_i),
      .pmpcfg_i            (pmpcfg_i),
      .pmpaddr_i           (pmpaddr_i)
  );

  assign misaligned_exception   = cva6_misaligned_exception;
  assign st_translation_req     = cva6_st_translation_req;
  assign translation_req        = cva6_translation_req;
  assign mmu_vaddr              = cva6_mmu_vaddr;
  // MMU output
  assign cva6_translation_valid = translation_valid;
  assign cva6_mmu_paddr         = mmu_paddr;
  assign cva6_mmu_exception     = mmu_exception;
  assign cva6_dtlb_hit          = dtlb_hit;
  assign cva6_dtlb_ppn          = dtlb_ppn;
  // No accelerator
  assign acc_mmu_resp_o         = '0;
  // Feed forward the lsu_ctrl bypass
  assign lsu_ctrl               = lsu_ctrl_byp;


  //=======================
  // Store Buffer 实例化
  //=======================
    store_unit #(
      .CVA6Cfg(CVA6Cfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t)
  ) i_store_unit (
      .clk_i,
      .rst_ni,
      .flush_i,
      .stall_st_pending_i,
      .no_st_pending_o(no_st_pending_o),
      .store_buffer_empty_o(store_buffer_empty),  // 存储缓冲区空（输出给加载单元）

      .valid_i   (st_valid_i),          // 存储指令有效（来自LSU顶层）
      .lsu_ctrl_i(lsu_ctrl),            // LSU控制信号（地址、操作类型等）
      .pop_st_o  (pop_st),              // 存储指令弹出（通知Issue阶段）
      .commit_i  (commit_i),            // 提交信号（确认存储有效）
      .commit_ready_o(commit_ready_o),  // 提交就绪（存储缓冲区可接收）
      .amo_valid_commit_i(amo_valid_commit_i),  // AMO提交有效

      .valid_o              (st_valid),  // 存储结果有效（输出给流水线寄存器）
      .trans_id_o           (st_trans_id),  // 存储事务ID
      .result_o             (st_result),  // 存储结果（无意义，传递输入）
      .ex_o                 (st_ex),     // 存储异常（输出给流水线寄存器）
      // MMU接口
      .translation_req_o    (cva6_st_translation_req),  // 存储翻译请求（给MMU）
      .vaddr_o              (st_vaddr),  // 存储虚拟地址（给MMU）
      .rvfi_mem_paddr_o     (rvfi_mem_paddr_o),  // RVFI物理地址
      .tinst_o              (st_tinst),  // 存储陷阱指令（给MMU）
      .hs_ld_st_inst_o      (st_hs_ld_st_inst),  // 存储HS标记（给MMU）
      .hlvx_inst_o          (st_hlvx_inst),  // 存储HLVX标记（给MMU）
      .paddr_i              (cva6_mmu_paddr),  // MMU输出的物理地址
      .ex_i                 (cva6_mmu_exception),  // MMU异常
      .dtlb_hit_i           (cva6_dtlb_hit),  // DTLB命中
      // 加载单元接口（地址冲突检测）
      .page_offset_i        (page_offset),  // 加载页内偏移（来自加载单元）
      .page_offset_matches_o(page_offset_matches),  // 偏移匹配（冲突标记）
      // AMO接口
      .amo_req_o            (amo_req_o),  // AMO请求（给DCache）
      .amo_resp_i           (amo_resp_i),  // AMO响应（来自DCache）
      // DCache接口
      .req_port_i           (dcache_req_ports_i[2]),
      .req_port_o           (dcache_req_ports_o[2])
  );

  //====================
  // Load Unit 实例化
  //====================
  load_unit #(
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t)
  ) i_load_unit (
      .clk_i,
      .rst_ni,
      .flush_i,

      .valid_i   (ld_valid_i),
      .lsu_ctrl_i(lsu_ctrl),
      .pop_ld_o  (pop_ld),

      .valid_o              (ld_valid),
      .trans_id_o           (ld_trans_id),
      .result_o             (ld_result),
      .ex_o                 (ld_ex),
      // MMU port
      .translation_req_o    (ld_translation_req),
      .vaddr_o              (ld_vaddr),
      .tinst_o              (ld_tinst),
      .hs_ld_st_inst_o      (ld_hs_ld_st_inst),
      .hlvx_inst_o          (ld_hlvx_inst),
      .paddr_i              (cva6_mmu_paddr),
      .ex_i                 (cva6_mmu_exception),
      .dtlb_hit_i           (cva6_dtlb_hit),
      .dtlb_ppn_i           (cva6_dtlb_ppn),
      // to store unit
      .page_offset_o        (page_offset),
      .page_offset_matches_i(page_offset_matches),
      .store_buffer_empty_i (store_buffer_empty),
      .commit_tran_id_i,
      // to memory arbiter
      .req_port_i           (dcache_req_ports_i[1]),
      .req_port_o           (dcache_req_ports_o[1]),
      .dcache_wbuffer_not_ni_i
  );
  
  // ----------------------------
  // Output Pipeline Register
  // ----------------------------
  // 加载操作流水线寄存器：暂存有效标记、事务ID、结果、异常
  shift_reg #(
      .dtype(logic [$bits(ld_valid) + $bits(ld_trans_id) + $bits(ld_result) + $bits(ld_ex) - 1:0]),
      .Depth(NrLoadPipeRegs)  // 流水线深度（配置参数）
  ) i_pipe_reg_load (
      .clk_i,
      .rst_ni,
      .d_i({ld_valid, ld_trans_id, ld_result, ld_ex}),  // 输入：加载中间结果
      .d_o({load_valid_o, load_trans_id_o, load_result_o, load_exception_o})  // 输出：加载最终结果
  );

  // 存储操作流水线寄存器：暂存有效标记、事务ID、结果、异常
  shift_reg #(
      .dtype(logic [$bits(st_valid) + $bits(st_trans_id) + $bits(st_result) + $bits(st_ex) - 1:0]),
      .Depth(NrStorePipeRegs)  // 流水线深度（配置参数）
  ) i_pipe_reg_store (
      .clk_i,
      .rst_ni,
      .d_i({st_valid, st_trans_id, st_result, st_ex}),  // 输入：存储中间结果
      .d_o({store_valid_o, store_trans_id_o, store_result_o, store_exception_o})  // 输出：存储最终结果
  );

    always_comb begin : which_op
    // 默认：加载/存储有效为0，MMU请求为0
    ld_valid_i           = 1'b0;
    st_valid_i           = 1'b0;
    cva6_translation_req = 1'b0;
    cva6_mmu_vaddr       = {VLEN{1'b0}};
    mmu_tinst            = {32{1'b0}};
    mmu_hs_ld_st_inst    = 1'b0;
    mmu_hlvx_inst        = 1'b0;

    // 根据LSU控制信号的功能单元（FU）区分加载/存储
    unique case (lsu_ctrl.fu)
      LOAD: begin  // 加载指令（如LD/LW/LH/LB）
        ld_valid_i           = lsu_ctrl.valid;  // 加载有效=指令有效
        cva6_translation_req = ld_translation_req;  // MMU请求=加载翻译请求
        cva6_mmu_vaddr       = ld_vaddr;  // MMU虚拟地址=加载虚拟地址
      end

      STORE: begin  // 存储指令（如SD/SW/SH/SB）
        st_valid_i           = lsu_ctrl.valid;  // 存储有效=指令有效
        cva6_translation_req = st_translation_req;  // MMU请求=存储翻译请求
        cva6_mmu_vaddr       = st_vaddr;  // MMU虚拟地址=存储虚拟地址
      end

      default: ; 
    endcase
  end

  // 64位系统：生成8字节（64位）的字节使能
  assign be_i = be_gen(vaddr_i[2:0], extract_transfer_size(fu_data_i.operation));

  
  // 数据未对齐检测
  ///////////////////////////////////////
    always_comb begin : data_misaligned_detection
    // 默认：未对齐异常无效
    cva6_misaligned_exception = {
      {XLEN{1'b0}}, {XLEN{1'b0}}, {GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    data_misaligned = 1'b0;

    // 仅当LSU指令有效时，检测未对齐
    if (lsu_ctrl.valid) begin
      // 64位系统：双字（64位）需地址低3位为0
        case (lsu_ctrl.operation)
          LD, SD, FLD, FSD, AMO_LRD, AMO_SCD, AMO_SWAPD, AMO_ADDD, AMO_ANDD, AMO_ORD,
          AMO_XORD, AMO_MAXD, AMO_MAXDU, AMO_MIND, AMO_MINDU, HLV_D, HSV_D: begin
            if (lsu_ctrl.vaddr[2:0] != 3'b000) begin
              data_misaligned = 1'b1;  // 双字未对齐
            end
          end
          default: ;
        endcase


      // 所有系统：字/半字/字节对齐检测
      case (lsu_ctrl.operation)
        // 字（32位）：地址低2位需为0
        LW, LWU, SW, FLW, FSW, AMO_LRW, AMO_SCW, AMO_SWAPW, AMO_ADDW, AMO_ANDW, AMO_ORW,
        AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW, AMO_MINWU, HLV_W, HLV_WU, HLVX_WU, HSV_W: begin
          if (lsu_ctrl.vaddr[1:0] != 2'b00) begin
            data_misaligned = 1'b1;  // 字未对齐
          end
        end
        // 半字（16位）：地址低1位需为0
        LH, LHU, SH, FLH, FSH, HLV_H, HLV_HU, HLVX_HU, HSV_H: begin
          if (lsu_ctrl.vaddr[0] != 1'b0) begin
            data_misaligned = 1'b1;  // 半字未对齐
          end
        end
        // 字节（8位）：始终对齐，无需检测
        default: ;
      endcase
    end

    // 生成未对齐异常
    if (data_misaligned) begin
      case (lsu_ctrl.fu)
        LOAD: begin
          cva6_misaligned_exception.cause = riscv::LD_ADDR_MISALIGNED;  // 加载地址未对齐
          cva6_misaligned_exception.valid = 1'b1;
          cva6_misaligned_exception.tval  = {{XLEN - VLEN{1'b0}}, lsu_ctrl.vaddr}; 
        end

        STORE: begin
          cva6_misaligned_exception.cause = riscv::ST_ADDR_MISALIGNED;  // 存储地址未对齐
          cva6_misaligned_exception.valid = 1'b1;
          cva6_misaligned_exception.tval  = {{XLEN - VLEN{1'b0}}, lsu_ctrl.vaddr};
        end
        default: ;
      endcase
    end

    // 64位下地址溢出：触发页错误（非未对齐）
    if ( en_ld_st_translation_i && lsu_ctrl.overflow) begin
      case (lsu_ctrl.fu)
        LOAD: begin
          cva6_misaligned_exception.cause = riscv::LOAD_PAGE_FAULT;  // 加载页错误
          cva6_misaligned_exception.valid = 1'b1;
          cva6_misaligned_exception.tval  = {{XLEN - VLEN{1'b0}}, lsu_ctrl.vaddr};
        end
        STORE: begin
          cva6_misaligned_exception.cause = riscv::STORE_PAGE_FAULT;  // 存储页错误
          cva6_misaligned_exception.valid = 1'b1;
          cva6_misaligned_exception.tval  = {{XLEN - VLEN{1'b0}}, lsu_ctrl.vaddr};
        end
        default: ;
      endcase
    end
  end

  // LSU 仲裁器
  lsu_ctrl_t lsu_req_i;
  assign lsu_req_i = {
    lsu_valid_i,          // 指令有效
    vaddr_i,              // 虚拟地址
    tinst_i,              // 陷阱指令
    overflow,             // 地址溢出
    fu_data_i.operand_b,  // 操作数B（存储数据）
    be_i,                 // 字节使能
    fu_data_i.fu,         // FU类型（LOAD/STORE）
    fu_data_i.operation,  // 操作类型（如LD/SW）
    fu_data_i.pointer     // 事务ID
  };

  // 实例化LSU旁路队列：当MMU被占用时，缓冲LSU请求
  lsu_bypass #(
      .lsu_ctrl_t(lsu_ctrl_t)
  ) lsu_bypass_i (
      .clk_i,
      .rst_ni,
      .flush_i,
      .lsu_req_i      (lsu_req_i),        // LSU请求
      .lsu_req_valid_i(lsu_valid_i),      // 请求有效
      .pop_ld_i       (pop_ld),           // 加载弹出
      .pop_st_i       (pop_st),           // 存储弹出

      .lsu_ctrl_o(lsu_ctrl_byp),          // 缓冲后的LSU控制信号
      .ready_o   (lsu_ready_o)            // LSU就绪（队列未满）
  );

endmodule