module mmu
  import config_pkg::*;
  import mmu_pkg::*;
#(
  parameter type                   icache_areq_t  = logic,
  parameter type                   icache_arsp_t  = logic,
  parameter type                   icache_dreq_t  = logic,
  parameter type                   icache_drsp_t  = logic,
  parameter type                   dcache_req_i_t = logic,
  parameter type                   dcache_req_o_t = logic,
  parameter type                   exception_t    = logic,
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic enable_translation_i,
  input logic en_ld_st_translation_i,

  // IF
  input   icache_arsp_t icache_areq_i,
  output  icache_areq_t icache_areq_o,

  // exception
  input   exception_t                                   misaligned_ex_i,      // LSU输入未对齐地址
  input   logic                                         lsu_req_i,            // LSU地址转换请求（1=需要转换虚拟地址）
  input   logic           [VLEN-1:0]                    lsu_vaddr_i,          // LSU输入的虚拟地址
  input   logic                                         lsu_is_store_i,       // 1=当前请求是存储操作，0=加载操作


  // DTLB命中信号（同周期反馈）
  output  logic                                         lsu_dtlb_hit_o,       // 1=当前LSU请求在DTLB命中
  output  logic           [PPNW-1:0]                    lsu_dtlb_ppn_o,       // 命中时输出物理页号（PPN）

  // 地址转换结果（延迟1周期输出）
  output  logic                                         lsu_valid_o,          // 1=地址转换完成（有效）
  output  logic           [PLEN-1:0]                    lsu_paddr_o,          // 转换后的物理地址
  output  exception_t                                   lsu_exception_o,      // 转换过程中的异常信息（如页错误）

  // 特权级与 CSR 配置信号
  input   priv_lvl_t                                    priv_lvl_i,           // 当前指令执行的特权级（U/S/H/M，来自`riscv`包）
  input   logic                                         v_i,                  // 指令侧虚拟模式使能（1=使用VSATP，0=使用SATP）
  input   logic                                         ld_st_priv_lvl_i,     // LSU操作的特权级（同`priv_lvl_i`，单独传入避免时序问题）
  input   logic                                         sum_i,                // Supervisor模式用户页访问使能（SUM位，SATP扩展）
  input   logic                                         mxr_i,                // 使不可执行页可读取（MXR位，用于加载指令）

  // 页表基址寄存器（PPN部分，来自CSR）
  input   logic           [PPNW-1:0]                    satp_ppn_i,           // SATP寄存器的页表基址（物理模式）

  // ASID
  input   logic           [ASID_WIDTH-1:0]              asid_i,               // 当前ASID（物理模式）
  input   logic           [ASID_WIDTH-1:0]              asid_to_be_flushed_i, // 需要刷新的ASID
  input   logic           [VMID_WIDTH-1:0]              vmid_to_be_flushed_i, // 需要刷新的VMID

  // 刷新地址（用于局部TLB刷新）
  input   logic           [VLEN-1:0]                    vaddr_to_be_flushed_i,// 需要刷新的虚拟地址
  input   logic                                         flush_tlb_i,          // 全局TLB刷新（清空所有TLB条目）

  // 性能计数器
  output  logic                                         itlb_miss_o,          // ITLB未命中计数（每发生一次未命中置1）
  output  logic                                         dtlb_miss_o,          // DTLB未命中计数（每发生一次未命中置1）

  // PTW
  input   dcache_req_o_t                                req_port_i,           // DCache对PTW的响应（含页表项数据、就绪信号）
  output  dcache_req_i_t                                req_port_o,           // PTW对DCache的请求（含页表物理地址、读使能）

  // PMP
  input   pmpcfg_t        [NrPMPEntries-1:0]            pmpcfg_i,             // PMP配置寄存器（每个条目含权限）
  input   logic           [NrPMPEntries-1:0][PLEN-3:0]  pmpaddr_i             // PMP地址寄存器（页粒度）
);
  
  localparam type pte_cva6_t = struct packed {  // 页表项
    logic [9:0] reserved;   // 保留位
    logic [PPNW-1:0] ppn;   // 物理页号
    logic [1:0] rsw;        // 软件保留位(供操作系统使用)
    logic d;                // 脏位（是否被写入过）
    logic a;                // 访问位（是否被访问过）
    logic g;                // 全局位（所有ASID共享，刷新TLB时不清除）
    logic u;                // 用户位（用户模式可访问）
    logic x;                // 执行权限（1=可执行）
    logic w;                // 写权限（1=可写）
    logic r;                // 读权限（1=可读）
    logic v;                // 有效位（1=页表项有效）
  };

  localparam type tlb_update_cva6_t = struct packed { // 定义TLB更新信息结构
    logic                           valid;    // 更新有效标志
    logic [PtLevels-2:0][HYP_EXT:0] is_page;  // 页大小标志
    logic [VpnLen-1:0]              vpn;      // 虚拟页号
    logic [ASID_WIDTH-1:0]          asid;     // 地址空间标识符（区分进程）
    pte_cva6_t                      content;  // PTE内容
    pte_cva6_t                      g_content;// PTE内容
  };
    // 权限与异常相关信号
  logic iaccess_err;  // 权限不足，无法访问此说明页面
  logic i_g_st_access_err;  // H扩展 insufficient privilege at g stage to access this instruction page
  logic daccess_err;  // 数据访问权限不足 insufficient privilege to access this data page
  logic canonical_addr_check;  //虚拟地址规范性检查（Sv39高25位是否符号扩展） canonical check on the virtual address for SV39
  logic d_g_st_access_err;  // （Hypervisor模式）insufficient privilege to access this data page

  // 页表遍历相关的信号
  logic ptw_active;  // PTW正在进行页表遍历  PTW is currently walking a page table
  logic walking_instr;  //PTW因ITLB未命中而遍历 PTW is walking because of an ITLB miss
  logic ptw_error;  // PTW遍历出错 PTW threw an exception
  logic ptw_error_at_g_st;  //Hypervisor模式） PTW threw an exception at the G-Stage
  logic ptw_err_at_g_int_st;  // PTW threw an exception at the G-Stage during S-Stage translation
  logic ptw_access_exception;  //PTW访问异常 PTW threw an access exception (PMPs)
  logic [PLEN-1:0] ptw_bad_paddr;  //PTW出错的物理地址 PTW page fault bad physical addr
  logic [GPLEN-1:0] ptw_bad_gpaddr;  //（Hypervisor模式） PTW guest page fault bad guest physical addr

  logic [VLEN-1:0] update_vaddr, shared_tlb_vaddr; // 更新/共享TLB的虚拟地址

  tlb_update_cva6_t update_itlb, update_dtlb, update_shared_tlb;// ITLB/DTLB/共享TLB的更新信息

  logic                               itlb_lu_access;
  pte_cva6_t                          itlb_content;
  pte_cva6_t                          itlb_g_content;
  logic      [  PtLevels-2:0] itlb_is_page;
  logic                               itlb_lu_hit;
  logic      [     GPLEN-1:0] itlb_gpaddr;
  logic      [ASID_WIDTH-1:0] itlb_lu_asid;

  logic                               dtlb_lu_access;
  pte_cva6_t                          dtlb_content;
  pte_cva6_t                          dtlb_g_content;
  logic      [  PtLevels-2:0] dtlb_is_page;
  logic      [TH-1:0] dtlb_lu_asid;
  logic                               dtlb_lu_hit;
  logic      [     GPLEN-1:0] dtlb_gpaddr;

  logic shared_tlb_access, shared_tlb_miss;
  logic shared_tlb_hit, itlb_req;

  // Assignments

  assign itlb_lu_access = icache_areq_i.fetch_req;
  assign dtlb_lu_access = lsu_req_i & !misaligned_ex_i.valid;
  assign itlb_lu_asid   = v_i ? vs_asid_i : asid_i;
  assign dtlb_lu_asid   = (ld_st_v_i || flush_tlb_vvma_i) ? vs_asid_i : asid_i;


  //====================
  // 模块声明
  //====================

  // Itlb
  cva6_tlb #(
      .CVA6Cfg          (CVA6Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .TLB_ENTRIES      (InstrTlbEntries),
      .HYP_EXT          (HYP_EXT)
  ) i_itlb (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .flush_i       (flush_tlb_i),
      .flush_vvma_i  (flush_tlb_vvma_i),
      .flush_gvma_i  (flush_tlb_gvma_i),
      .s_st_enbl_i   (enable_translation_i),
      .g_st_enbl_i   (enable_g_translation_i),
      .v_i           (v_i),
      .update_i      (update_itlb),
      .lu_access_i   (itlb_lu_access),
      .lu_asid_i     (itlb_lu_asid),
      .lu_vmid_i     (vmid_i),
      .lu_vaddr_i    (icache_areq_i.fetch_vaddr),
      .lu_gpaddr_o   (itlb_gpaddr),
      .lu_content_o  (itlb_content),
      .lu_g_content_o(itlb_g_content),
      .asid_to_be_flushed_i,
      .vmid_to_be_flushed_i,
      .vaddr_to_be_flushed_i,
      .gpaddr_to_be_flushed_i,
      .lu_is_page_o  (itlb_is_page),
      .lu_hit_o      (itlb_lu_hit)
  );

  // Dtlb
  cva6_tlb #(
      .CVA6Cfg          (CVA6Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .TLB_ENTRIES      (DataTlbEntries),
      .HYP_EXT          (HYP_EXT)
  ) i_dtlb (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .flush_i       (flush_tlb_i),
      .flush_vvma_i  (flush_tlb_vvma_i),
      .flush_gvma_i  (flush_tlb_gvma_i),
      .s_st_enbl_i   (en_ld_st_translation_i),
      .g_st_enbl_i   (en_ld_st_g_translation_i),
      .v_i           (ld_st_v_i),
      .update_i      (update_dtlb),
      .lu_access_i   (dtlb_lu_access),
      .lu_asid_i     (dtlb_lu_asid),
      .lu_vmid_i     (vmid_i),
      .lu_vaddr_i    (lsu_vaddr_i),
      .lu_gpaddr_o   (dtlb_gpaddr),
      .lu_content_o  (dtlb_content),
      .lu_g_content_o(dtlb_g_content),
      .asid_to_be_flushed_i,
      .vmid_to_be_flushed_i,
      .vaddr_to_be_flushed_i,
      .gpaddr_to_be_flushed_i,
      .lu_is_page_o  (dtlb_is_page),
      .lu_hit_o      (dtlb_lu_hit)
  );


  cva6_shared_tlb #(
      .CVA6Cfg          (CVA6Cfg),
      .SHARED_TLB_WAYS  (2),
      .HYP_EXT          (HYP_EXT),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t)
  ) i_shared_tlb (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .flush_i       (flush_tlb_i),
      .flush_vvma_i  (flush_tlb_vvma_i),
      .flush_gvma_i  (flush_tlb_gvma_i),
      .s_st_enbl_i   (enable_translation_i),
      .g_st_enbl_i   (enable_g_translation_i),
      .v_i           (v_i),
      .s_ld_st_enbl_i(en_ld_st_translation_i),
      .ld_st_v_i     (ld_st_v_i),

      .dtlb_asid_i  (dtlb_lu_asid),
      .itlb_asid_i  (itlb_lu_asid),
      .lu_vmid_i    (vmid_i),
      // from TLBs
      // did we miss?
      .itlb_access_i(itlb_lu_access),
      .itlb_hit_i   (itlb_lu_hit),
      .itlb_vaddr_i (icache_areq_i.fetch_vaddr),

      .dtlb_access_i(dtlb_lu_access),
      .dtlb_hit_i   (dtlb_lu_hit),
      .dtlb_vaddr_i (lsu_vaddr_i),

      // to TLBs, update logic
      .itlb_update_o(update_itlb),
      .dtlb_update_o(update_dtlb),

      // Performance counters
      .itlb_miss_o(itlb_miss_o),
      .dtlb_miss_o(dtlb_miss_o),
      .shared_tlb_miss_i(shared_tlb_miss),

      .shared_tlb_access_o(shared_tlb_access),
      .shared_tlb_hit_o   (shared_tlb_hit),
      .shared_tlb_vaddr_o (shared_tlb_vaddr),

      .itlb_req_o         (itlb_req),
      // to update shared tlb
      .shared_tlb_update_i(update_shared_tlb)
  );

  // PTW
  ptw #(
      .CVA6Cfg          (CVA6Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .dcache_req_i_t   (dcache_req_i_t),
      .dcache_req_o_t   (dcache_req_o_t),
      .HYP_EXT          (HYP_EXT)
  ) i_ptw (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .flush_i,

      .ptw_active_o          (ptw_active),
      .walking_instr_o       (walking_instr),
      .ptw_error_o           (ptw_error),
      .ptw_access_exception_o(ptw_access_exception),

      .enable_translation_i,
      .en_ld_st_translation_i,

      .lsu_is_store_i(lsu_is_store_i),
      // PTW memory interface
      .req_port_i    (req_port_i),
      .req_port_o    (req_port_o),

      // to Shared TLB, update logic
      .shared_tlb_update_o(update_shared_tlb),

      .update_vaddr_o(update_vaddr),

      .asid_i,

      // from shared TLB
      // did we miss?
      .shared_tlb_access_i(shared_tlb_access),
      .shared_tlb_hit_i   (shared_tlb_hit),
      .shared_tlb_vaddr_i (shared_tlb_vaddr),

      .itlb_req_i(itlb_req),

      .satp_ppn_i,
      .mxr_i,

      // Performance counters
      .shared_tlb_miss_o(shared_tlb_miss),  //open for now

      // PMP
      .pmpcfg_i   (pmpcfg_i),
      .pmpaddr_i  (pmpaddr_i),
      .bad_paddr_o(ptw_bad_paddr)
  );

  //====================
  // 指令接口组合逻辑
  //====================
  logic [VLEN-1:0] lsu_vaddr_n, lsu_vaddr_q;
  pte_cva6_t dtlb_pte_n, dtlb_pte_q;
  logic lsu_req_n, lsu_req_q;
  logic lsu_is_store_n, lsu_is_store_q;
  logic dtlb_hit_n, dtlb_hit_q;
  logic [PtLevels-2:0] dtlb_is_page_n, dtlb_is_page_q;
  exception_t misaligned_ex_n, misaligned_ex_q;
  localparam int PPNWMin = PPNW - 1;
  assign lsu_dtlb_hit_o = (en_ld_st_translation_i || en_ld_st_g_translation_i) ? dtlb_lu_hit : 1'b1;

  always_comb begin 
    // MMU禁用
    icache_areq_o.fetch_valid = icache_areq_i.fetch_req;  // 取指有效信号直接传递
    icache_areq_o.fetch_paddr  = PLEN'(icache_areq_i.fetch_vaddr[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):0]);
    icache_areq_o.fetch_exception = '0;// 异常可能是：1.特权级不匹配 2.PTW发来异常

    // 检查指令访问权限错误
    iaccess_err = icache_areq_i.fetch_req && enable_translation_i &&  (((priv_lvl_i == PRIV_LVL_U) && ~itlb_content.u)  
    || ((priv_lvl_i == PRIV_LVL_S) && itlb_content.u));

    // 默认赋值
    lsu_vaddr_n = lsu_vaddr_i;
    lsu_req_n = lsu_req_i;
    dtlb_pte_n = dtlb_content;
    dtlb_hit_n = dtlb_lu_hit;
    lsu_is_store_n = lsu_is_store_i;
    dtlb_is_page_n = dtlb_is_page;
    misaligned_ex_n = misaligned_ex_i;

    // 默认输出
    lsu_valid_o = lsu_req_q;
    lsu_exception_o = misaligned_ex_q;

    misaligned_ex_n.valid = misaligned_ex_i.valid & lsu_req_i;// 防止LSU未响应时出现异常报错

    // 高位只能是1或者0
    canonical_addr_check = (lsu_req_i && en_ld_st_translation_i &&
          !((&lsu_vaddr_i[VLEN-1:SV-1]) == 1'b1 || (|lsu_vaddr_i[VLEN-1:SV-1]) == 1'b0));

    // 检查访问权限
    daccess_err = en_ld_st_translation_i &&
              ((ld_st_priv_lvl_i == PRIV_LVL_S && (!sum_i ) && dtlb_pte_q.u)  // Supervisor模式：无SUM位且访问用户页
              || (ld_st_priv_lvl_i == PRIV_LVL_U && !dtlb_pte_q.u));          // 用户模式：访问非用户页

    // 初始化物理地址和PPN,默认赋值：不启动MMU
    lsu_paddr_o = (PLEN)'(lsu_vaddr_q[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):0]);
    lsu_dtlb_ppn_o = (PPNW)'(lsu_vaddr_n[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):12]);

    if (en_ld_st_translation_i && !misaligned_ex_q.valid) begin // 表示 启动MMU 并无地址非对齐
      lsu_valid_o = 1'b0;
      // 计算DTLB命中时的PPN（输出给LSU同周期反馈）
      lsu_dtlb_ppn_o = dtlb_content.ppn;
      // 计算转换后的物理地址（延迟1周期，用寄存器中的PTE和虚拟地址）
      lsu_paddr_o = {dtlb_pte_q.ppn, lsu_vaddr_q[11:0]};

      // 处理大页（补充PPN中间位，同指令侧）
      if (PtLevels == 3 && dtlb_is_page_q[PtLevels-2]) begin
        lsu_paddr_o[PPNWMin-(VpnLen/PtLevels):9+PtLevels] = lsu_vaddr_q[PPNWMin-(VpnLen/PtLevels):9+PtLevels];
        lsu_dtlb_ppn_o[PPNWMin-(VpnLen/PtLevels):9+PtLevels] = lsu_vaddr_n[PPNWMin-(VpnLen/CPtLevels):9+PtLevels];
      end

      if (dtlb_is_page_q[0]) begin
        lsu_dtlb_ppn_o[PPNWMin:12] = lsu_vaddr_n[PPNWMin:12];
        lsu_paddr_o[PPNWMin:12] = lsu_vaddr_q[PPNWMin:12];
      end

      // 1.DTLB命中
      if(dtlb_hit_q && lsu_req_q) begin
        lsu_valid_o = 1'b1;

        // 1.Store 指令--错误（无写权限、权限错误、非规范地址、无脏位）——触发“存储页错误”
        if (lsu_is_store_q)begin
          if (!dtlb_pte_q.w || daccess_err || canonical_addr_check || !dtlb_pte_q.d) begin
            lsu_exception_o.cause = STORE_PAGE_FAULT;
            lsu_exception_o.valid = 1'b1;
            lsu_exception_o.tval = {
              {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, lsu_vaddr_q
            };
          end
        end
        else begin // Load 指令
          if (daccess_err || canonical_addr_check) begin
              lsu_exception_o.cause = LOAD_PAGE_FAULT;
              lsu_exception_o.valid = 1'b1;
              lsu_exception_o.tval = {
                {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, lsu_vaddr_q
              };
          end
        end
      end
      else begin // DTLB未命中（PTW正在遍历，且不是处理ITLB请求）
        if (ptw_active && !walking_instr) begin
          // PTW遍历出错
          if (ptw_error) begin
            lsu_valid_o = 1'b1; // 需要上报异常

            if (lsu_is_store_q) begin // 触发异常
              lsu_exception_o.cause = STORE_PAGE_FAULT;
              lsu_exception_o.valid = 1'b1;
              lsu_exception_o.tval = {
                {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr
              };
            end
            else begin
              lsu_exception_o.cause = LOAD_PAGE_FAULT;
              lsu_exception_o.valid = 1'b1;
              lsu_exception_o.tval = {
                {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr
              };
            end
          end

          if(ptw_access_exception) begin
            lsu_valid_o = 1'b1;
            if (lsu_is_store_q  && PtLevels == 3) begin
              lsu_exception_o.cause = ST_ACCESS_FAULT;
              lsu_exception_o.valid = 1'b1;
              lsu_exception_o.tval = {
                {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr
              };
            end else begin
              lsu_exception_o.cause = LD_ACCESS_FAULT;
              lsu_exception_o.valid = 1'b1;
              lsu_exception_o.tval = {
                {XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr
              };
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      lsu_vaddr_q     <= '0;
      lsu_req_q       <= '0;
      dtlb_pte_q      <= '0;
      dtlb_hit_q      <= '0;
      lsu_is_store_q  <= '0;
      dtlb_is_page_q  <= '0;
      misaligned_ex_q <= '0;
    end else begin
      lsu_vaddr_q     <= lsu_vaddr_n;
      lsu_req_q       <= lsu_req_n;
      dtlb_pte_q      <= dtlb_pte_n;
      dtlb_hit_q      <= dtlb_hit_n;
      lsu_is_store_q  <= lsu_is_store_n;
      dtlb_is_page_q  <= dtlb_is_page_n;
      misaligned_ex_q <= misaligned_ex_n;

    end
  end
endmodule