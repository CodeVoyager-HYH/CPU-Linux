module ptw
  import ariane_pkg::*;  // 导入CVA6处理器的全局定义（如类型、常量）
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,  // CVA6配置参数（如页表级数、地址宽度等）
    parameter type pte_cva6_t = logic,  // 页表项（PTE）类型（由外部定义，如包含权限位、物理页号等）
    parameter type tlb_update_cva6_t = logic,  // TLB更新信息类型（用于通知TLB更新缓存）
    parameter type dcache_req_i_t = logic,  // 数据缓存请求输入类型
    parameter type dcache_req_o_t = logic,  // 数据缓存请求输出类型
    parameter int unsigned HYP_EXT = 0  // 是否支持Hypervisor扩展（0：不支持；1：支持）
) (
    // 时钟与复位
    input   logic clk_i,  // 时钟信号
    input   logic rst_ni,  // 异步复位（低电平有效）
    input   logic flush_i,  // 刷新信号（清空PTW状态，处理推测执行带来的不一致）
    
    // PTW状态输出
    output  logic                               ptw_active_o,           // PTW正在进行页表遍历（活跃状态）
    output  logic                               walking_instr_o,        // PTW因ITLB未命中而遍历（区分指令/数据遍历）
    output  logic                               ptw_error_o,            // 页表遍历出错（如无效PTE）
    output  logic                               ptw_access_exception_o, // PMP（物理内存保护）访问异常
    
    // 虚拟地址转换使能信号
    input   logic                               enable_translation_i,   // 使能S地址转换（来自CSR）
    input   logic                               en_ld_st_translation_i, // 使能加载/存储的S/VS-stage转换
    
    input   logic                               lsu_is_store_i,         // 本次遍历是否由存储操作触发
    
    // 数据缓存接口（用于访问内存中的页表）
    input   dcache_req_o_t                      req_port_i,             // 缓存返回的响应（如页表项数据）
    output  dcache_req_i_t                      req_port_o,             // 向缓存发送的请求（如读取页表项）
    
    // TLB更新输出（遍历完成后通知TLB更新缓存）
    output  tlb_update_cva6_t                   shared_tlb_update_o,
    output  logic [VLEN-1:0]                    update_vaddr_o,         // 需要更新TLB的虚拟地址
    
    // 地址空间标识（区分不同进程/虚拟机）
    input   logic [ASID_WIDTH-1:0]              asid_i,                 // 当前ASID（地址空间ID）
    
    // TLB未命中信息（来自共享TLB控制器）
    input   logic                               shared_tlb_access_i,    // 共享TLB有访问请求
    input   logic                               shared_tlb_hit_i,       // 共享TLB命中
    input   logic [VLEN-1:0]                    shared_tlb_vaddr_i,     // TLB未命中的虚拟地址
    
    input   logic                               itlb_req_i,             // 本次遍历是否由ITLB（指令TLB）未命中触发
    
    // 页表基址（来自CSR寄存器）
    input   logic [PPNW-1:0]                    satp_ppn_i,             // satp寄存器的PPN（物理页号，S-stage页表基址）
    input   logic                               mxr_i,                  // 允许读取可执行页（Make eXecutable Readable）
    
    // 性能计数
    output  logic                               shared_tlb_miss_o,      // 共享TLB未命中计数
    
    // PMP（物理内存保护）配置
    input   pmpcfg_t [NrPMPEntries-1:0]         pmpcfg_i,               // PMP配置寄存器
    input   logic [NrPMPEntries-1:0][PLEN-3:0]  pmpaddr_i,              // PMP地址寄存器
    output  logic [PLEN-1:0]                    bad_paddr_o             // 访问出错的物理地址（用于异常）
);

  // FSM
  enum logic [2:0] {
    IDLE,                   // 空闲（无页表遍历请求）
    WAIT_GRANT,             // 等待缓存授权（发送页表读取请求后，等待缓存允许）
    PTE_LOOKUP,             // 解析页表项（检查PTE有效性、权限等）
    WAIT_RVALID,            // 等待缓存数据有效（读取页表项时，等待数据返回）
    PROPAGATE_ERROR,        // 传播页表错误（如无效PTE）
    PROPAGATE_ACCESS_ERROR, // 传播PMP访问错误
    LATENCY                 // 延迟状态（用于时序对齐）
  } state_q, state_d;  
  
  logic [PtLevels-2:0] misaligned_page;
  logic shared_tlb_update_valid;
  logic [PtLevels-2:0] ptw_lvl_n, ptw_lvl_q;
  logic data_rvalid_q;
  logic [XLEN-1:0] data_rdata_q;

  pte_cva6_t pte;
  assign pte = pte_cva6_t'(data_rdata_q);
  logic is_instr_ptw_q, is_instr_ptw_n;
  logic global_mapping_q, global_mapping_n;
  logic tag_valid_n, tag_valid_q;
  logic [ASID_WIDTH-1:0] tlb_update_asid_q, tlb_update_asid_n;
  logic [VMID_WIDTH-1:0] tlb_update_vmid_q, tlb_update_vmid_n;
  logic [VLEN-1:0] vaddr_q, vaddr_n;
  logic [PtLevels-2:0][(VpnLen/PtLevels)-1:0] vaddr_lvl;
  logic [PLEN-1:0] ptw_pptr_q, ptw_pptr_n;

  // 输出需要更新TLB的虚拟地址
  assign update_vaddr_o = vaddr_q;
  // PTW活跃状态
  assign ptw_active_o = (state_q != IDLE);
  // 是否为指令遍历（由ITLB未命中触发）
  assign walking_instr_o = is_instr_ptw_q;
  // 缓存地址映射（将物理指针转换为缓存的索引和标签）
  assign req_port_o.address_index = ptw_pptr_q[DCACHE_INDEX_WIDTH-1:0];  // 缓存索引（物理地址低位）
  assign req_port_o.address_tag   = ptw_pptr_q[DCACHE_INDEX_WIDTH+DCACHE_TAG_WIDTH-1:DCACHE_INDEX_WIDTH];  // 缓存标签（物理地址高位）
  assign req_port_o.kill_req      = '0;  // 不取消请求
  assign req_port_o.data_wdata    = '0;  // PTW只读取页表，不写入
  assign req_port_o.data_id       = '0;  // 单请求，无需ID

  // 页表级别和地址映射关系
  genvar z, w;
  generate
    // 遍历页表级别（z：0到页表级数-2）
    for (z = 0; z < PtLevels - 1; z++) begin
      // 检查超级页是否对齐：若当前级别>0，且PPN的低i位非0，则为未对齐超级页（抛出异常）
      assign misaligned_page[z] = (ptw_lvl_q[0] == (z)) && (pte.ppn[(VpnLen/PtLevels)*(PtLevels-1-z)-1:0] != '0);

      // 提取各级页表的VPN（虚拟页号）部分（用于生成下一级页表地址）
      assign vaddr_lvl[z] = vaddr_q[12+((VpnLen/PtLevels)*(PtLevels-z-1))-1:12+((VpnLen/PtLevels)*(PtLevels-z-2))];
    end
  endgenerate

  // 更新TLB
  always_comb begin : tlb_update
    shared_tlb_update_o.valid = shared_tlb_update_valid;  // TLB更新有效标志

    // 设置页大小标志（根据遍历的页表级别，区分4K/2M/1G页）
    for (int unsigned x = 0; x < PtLevels - 1; x++) begin
      shared_tlb_update_o.is_page[x] = (ptw_lvl_q[0] == x) ;  // 找到需要更新的页表大小，0 = 4k， 1 = 2M， 2 = 1G
    end

    // 设置TLB更新的页表项内容（含全局映射标志）
    shared_tlb_update_o.content   = (pte | (global_mapping_q << 5)); 
    // 设置TLB更新的ASID
    shared_tlb_update_o.asid = tlb_update_asid_q;
    shared_tlb_update_o.vpn = vaddr_q[12+VpnLen-1:12];  // 虚拟页号（去掉页内偏移）

    // 错误地址输出（用于异常）
    bad_paddr_o = ptw_access_exception_o ? ptw_pptr_q : 'b0;
  end

  logic allow_access;
  pmp i_pmp_ptw (
    .addr_i       (ptw_pptr_q),
    .priv_lvl_i   (riscv::PRIV_LVL_S),
    .access_type_i(riscv::ACCESS_READ),
    .conf_addr_i  (pmpaddr_i),
    .conf_i       (pmpcfg_i),
    .allow_o      (allow_access)
  );

  assign req_port_o.data_be = '1;

  // PTW 转换过程：
  // 1. a = stap.ppn × PAGESIZE 生成根页表的物理基地址，i = LEVELS - 1 表示当前在最顶层页表开始遍历， SV39 LEVELS = 3
  // 2. 读取当前层页表项 PTE address = a + va.vpn[i] * PTESIZE，如果违反了PMA或PMP则抛出访问异常 access fault 异常
  // 3. 检查页表项是否合法，检查V=1，或者r=0并且w=1是非法编码，抛出页错误异常 page-fault 异常
  // 4. 判断是否到达叶子页表项，当 R=1 或 X=1，这个 PTE 是叶子结点，否则就是中间结点，指向下一级页表，如果进下一层页表返回第二步
  // 5. 检查超级页对齐，如果不是最后一级就发现了叶子阶段，那么他就是一个大页，但是必须对齐，且如果PPN低位不为0，则说明对齐错误
  // 6. 根据当前特权模式以及 mstatus 寄存器的 SUM 和 MXR 字段的值，
  //    确定 pte.u 位是否允许请求的内存访问。如果不允许，则停止并引发与原始访问类型对应的缺页错误异常。
  //         1) MXR 位修改加载程序访问虚拟内存的权限。当 MXR=0 时，只有从标记为可读的页面加载才会成功。
  //            当 MXR=1 时，从标记为可读或可执行的页面（R=1 或 X=1）加载都会成功
  //         2）SUM 位修改 S 模式加载和存储程序访问虚拟内存的权限。当 SUM=0 时，S 模式对 U 模式可访问的页面的内存访问会失败。当 SUM=1 时，允许这些访问。当基于页面的虚拟内存未启用时，SUM 位无效。
  //            注意，虽然 SUM 通常在非 S 模式下执行时会被忽略，但当 MPRV=1 且 MPP=S 时，SUM 会生效。如果不支持 S 模式或 satp.MODE 为只读 0，则 SUM 为只读 0。
  // 7. 如果实现了 Shadow Stack Memory Protection 扩展（安全机制），则额外检查 R/W/X 访问权限，否则可跳过。
  // 8. 检查R/W/X权限
  // 9.  如果 pte.a=0，或者原始内存访问是存储操作且 pte.d=0：
  //        如果对pte 的存储操作会违反 PMA 或 PMP 检查，则抛出与原始访问类型对应的访问错误异常。
  //        如果是原子指令：
  //          将 pte 与地址 a+va.vpn[i]×PTESIZE 处的 PTE 值进行比较
  //          如果值匹配，则将 pte.a 设置为 1，并且如果原始内存访问是存储操作，则还将 pte.d 设置为 1。如果失败返回步骤2
  // 10. 转换成功。转换后的物理地址如下：
  //        pa.pgoff = va.pgoff。
  //        如果 i>0，则表示这是超级页转换，且 pa.ppn[i-1:0] = va.vpn[i-1:0]。
  //        pa.ppn[LE​​VELS-1:i] = pte.ppn[LE​​VELS-1:i]。

    always_comb begin : ptw
    // 默认赋值（避免 latch）
    tag_valid_n             = 1'b0;
    req_port_o.data_req     = 1'b0;  // 缓存读取请求
    req_port_o.data_size    = 2'(PtLevels);  // 读取大小（页表级数相关）
    req_port_o.data_we      = 1'b0;  // 不写入（PTW只读）
    ptw_error_o             = 1'b0;
    ptw_error_at_g_st_o     = 1'b0;
    ptw_err_at_g_int_st_o   = 1'b0;
    ptw_access_exception_o  = 1'b0;
    shared_tlb_update_valid = 1'b0;
    is_instr_ptw_n          = is_instr_ptw_q;
    ptw_lvl_n               = ptw_lvl_q;
    ptw_pptr_n              = ptw_pptr_q;
    state_d                 = state_q;
    global_mapping_n        = global_mapping_q;
    tlb_update_asid_n       = tlb_update_asid_q;
    vaddr_n                 = vaddr_q;
    shared_tlb_miss_o       = 1'b0;  // 默认TLB命中

    case (state_q)
      IDLE: begin  // 空闲状态：等待TLB未命中请求
        ptw_lvl_n        = '0;  // 重置页表级别
        global_mapping_n = 1'b0;  // 重置全局映射标志
        is_instr_ptw_n   = 1'b0;  // 重置指令遍历标志

        // 若TLB未命中且需要地址转换，则启动页表遍历, 共享tlb是tlb命中的最后一环
        if (shared_tlb_access_i && ~shared_tlb_hit_i) begin
          // 计算S-stage页表地址，特权级手册虚拟地址转换第一步，a = satp.ppn × PAGESIZE
          ptw_pptr_n = {satp_ppn_i, shared_tlb_vaddr_i[SV-1:SV-(VpnLen/PtLevels)], (PtLevels)'(0)};

          is_instr_ptw_n    = itlb_req_i;  // 标记是否为指令遍历
          vaddr_n           = shared_tlb_vaddr_i;  // 保存未命中的虚拟地址
          state_d           = WAIT_GRANT;  // 进入等待缓存授权状态
          shared_tlb_miss_o = 1'b1;  // 记录TLB未命中

          // 设置ASID
          if (itlb_req_i) begin
            tlb_update_asid_n = asid_i;
          end else begin
            tlb_update_asid_n = asid_i;
          end
        end
      end

      WAIT_GRANT: begin  // 等待缓存授权：发送页表读取请求
        req_port_o.data_req = 1'b1;  // 向缓存发送读取请求
        if (req_port_i.data_gnt) begin  // 缓存允许请求
          tag_valid_n = 1'b1;  // 标记缓存标签有效
          state_d     = PTE_LOOKUP;  // 进入解析PTE状态
        end
      end

      PTE_LOOKUP: begin  // 解析PTE：检查有效性、权限，决定下一步
        if (data_rvalid_q) begin  // 缓存返回的PTE数据有效
          // 检查PTE的全局映射位（g位）
          if (pte.g) global_mapping_n = 1'b1;

          // 无效PTE检查（RISC-V规范）：
          // 1. PTE有效位v=0；2. 读权限r=0但写权限w=1；3. 保留位非0
          if (!pte.v || (!pte.r && pte.w) || (|pte.reserved ))
            state_d = PROPAGATE_ERROR;  // 异常
          else begin  // PTE有效
            state_d = LATENCY;  // 默认进入延迟状态
            // 叶子PTE（r=1或x=1，表示找到最终物理页）
            if (pte.r || pte.x) begin // 叶子结点
              if (is_instr_ptw_q) begin
                // 指令遍历：PTE必须可执行（x=1）且访问位a=1，否则出错
                if (!pte.x || !pte.a) begin
                  state_d = PROPAGATE_ERROR;
                end 
                else 
                  shared_tlb_update_valid = 1'b1;  // 遍历成功，更新TLB
              end 
              else begin  // 数据遍历
                // 数据遍历：PTE必须可读（r=1）且访问位a=1；存储操作需可写（w=1）且脏位d=1
                if ((pte.a && (pte.r || (pte.x && mxr_i ))) && (!lsu_is_store_i || (pte.w && pte.d))) begin
                  shared_tlb_update_valid = 1'b1;  // 遍历成功，更新TLB
                end else begin
                  state_d = PROPAGATE_ERROR;  // 权限不足，抛出错误
                end
              end

              // 检查超级页是否对齐，未对齐则出错
              if (|misaligned_page) begin
                state_d = PROPAGATE_ERROR;
                shared_tlb_update_valid = 1'b0;
              end
            end 
            
            else begin  // 非叶子PTE（指向更低级页表）
              if (ptw_lvl_q[0] == PtLevels - 1) begin  // 已到最低级，仍非叶子PTE→错误
                ptw_lvl_n[0] = ptw_lvl_q[0];
                state_d = PROPAGATE_ERROR;
              end else begin  // 继续遍历下一级页表
                ptw_lvl_n[0] = ptw_lvl_q[0] + 1'b1;  // 页表级别+1
                state_d = WAIT_GRANT;  // 再次发送读取请求
                ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (PtLevels)'(0)};  // 非虚拟化
              end
            end
          end

          // 检查PMP权限，不允许则触发访问异常
          if (!allow_access) begin
            shared_tlb_update_valid = 1'b0;
            ptw_pptr_n = ptw_pptr_q;  // 保存出错地址
            state_d = PROPAGATE_ACCESS_ERROR;
          end
        end
      end

      PROPAGATE_ERROR: begin  // 传播页表错误（如无效PTE）
        state_d = LATENCY;
        ptw_error_o = 1'b1;  // 标记页表错误
      end

      PROPAGATE_ACCESS_ERROR: begin  // 传播PMP访问错误
        state_d = LATENCY;
        ptw_access_exception_o = 1'b1;  // 标记PMP错误
      end

      WAIT_RVALID: begin  // 等待缓存数据有效（刷新时用）
        if (data_rvalid_q) state_d = IDLE;
      end

      LATENCY: begin  // 延迟状态（时序对齐）
        state_d = IDLE;
      end

      default: state_d = IDLE;
    endcase

    // 处理刷新信号（清空状态）
    if (flush_i) begin
      if (((state_q inside {PTE_LOOKUP, WAIT_RVALID}) && !data_rvalid_q) || ((state_q == WAIT_GRANT) && req_port_i.data_gnt))
        state_d = WAIT_RVALID;  // 等待缓存数据返回后再空闲
      else state_d = LATENCY;  // 直接进入延迟状态后空闲
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q           <= IDLE;
      is_instr_ptw_q    <= 1'b0;
      ptw_lvl_q         <= '0;
      tag_valid_q       <= 1'b0;
      tlb_update_asid_q <= '0;
      vaddr_q           <= '0;
      ptw_pptr_q        <= '0;
      global_mapping_q  <= 1'b0;
      data_rdata_q      <= '0;
      data_rvalid_q     <= 1'b0;
    end else begin
      state_q           <= state_d;
      ptw_pptr_q        <= ptw_pptr_n;
      is_instr_ptw_q    <= is_instr_ptw_n;
      ptw_lvl_q         <= ptw_lvl_n;
      tag_valid_q       <= tag_valid_n;
      tlb_update_asid_q <= tlb_update_asid_n;
      vaddr_q           <= vaddr_n;
      global_mapping_q  <= global_mapping_n;
      data_rdata_q      <= req_port_i.data_rdata;
      data_rvalid_q     <= req_port_i.data_rvalid;
    end
  end
  
endmodule