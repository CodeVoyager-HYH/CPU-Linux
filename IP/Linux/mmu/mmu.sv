module cva6_mmu  // 定义CVA6处理器的内存管理单元（MMU）模块
  import ariane_pkg::*;  // 导入ariane_pkg包（包含CVA6相关常量/类型）
#(
    // 参数：配置MMU功能、接口类型、扩展支持
    parameter type                   icache_areq_t  = logic,  // 指令缓存地址请求类型
    parameter type                   icache_arsp_t  = logic,  // 指令缓存地址响应类型
    parameter type                   icache_dreq_t  = logic,  // 指令缓存数据请求类型
    parameter type                   icache_drsp_t  = logic,  // 指令缓存数据响应类型
    parameter type                   dcache_req_i_t = logic,  // 数据缓存输入请求类型
    parameter type                   dcache_req_o_t = logic,  // 数据缓存输出请求类型
    parameter type                   exception_t    = logic,  // 异常信息类型（含原因、地址等）
    parameter int unsigned           HYP_EXT        = 0  // 是否支持Hypervisor扩展（0=不支持，1=支持）
) (
    // 输入输出端口（见下文逐行解释）
    input   logic clk_i,  // 时钟信号
    input   logic rst_ni,  // 异步复位（低电平有效）
    input   logic flush_i,  // 全局刷新信号（清空内部状态）

    input   logic                                   enable_translation_i,  // 使能指令/通用虚拟地址翻译
    input   logic                                   en_ld_st_translation_i,  // 使能加载/存储的虚拟地址翻译

    // IF（指令取指）接口
    input   icache_arsp_t                           icache_areq_i,      // 指令缓存的虚拟地址请求（含取指地址）
    output  icache_areq_t                           icache_areq_o,      // 翻译后的物理地址及异常信息

    // LSU（加载存储单元）接口
    input   exception_t                             misaligned_ex_i,    // 输入的未对齐异常（如访问非对齐地址）
    input   logic                                   lsu_req_i,          // LSU请求地址翻译
    input   logic     [VLEN-1:0]                    lsu_vaddr_i,        // LSU输入的虚拟地址
    input   logic                                   lsu_is_store_i,     // 标识是否为存储操作（1=存储，0=加载）
    
    // DTLB命中信息（同周期输出）
    output  logic                                   lsu_dtlb_hit_o,     // DTLB命中标志
    output  logic     [PPNW-1:0]                    lsu_dtlb_ppn_o,     // 命中时的物理页号（PPN）
    
    // 翻译结果（下一拍输出）
    output  logic                                   lsu_valid_o,        // 翻译结果有效标志
    output  logic     [PLEN-1:0]                    lsu_paddr_o,        // 翻译后的物理地址
    output  exception_t                             lsu_exception_o,    // 翻译过程中的异常信息
    
    // 通用控制信号
    input   priv_lvl_t                              priv_lvl_i,         // 当前特权级（U/S/M）
    input   priv_lvl_t                              ld_st_priv_lvl_i,   // 加载/存储操作的特权级
    input   logic                                   sum_i,              // 特权级S的用户页访问允许标志（Sum=1时S级可访问U级页）
    input   logic                                   mxr_i,              // 允许加载未标记为可读的页（Make eXecutable Readable）
    
    // 页表基地址（PPN）
    input   logic     [PPNW-1:0]                    satp_ppn_i,         // S级页表基地址（来自satp寄存器）
    
    // 地址空间标识符与刷新控制
    input   logic     [ASID_WIDTH-1:0]              asid_i,                 // 当前地址空间标识符（区分进程）
    input   logic     [ASID_WIDTH-1:0]              asid_to_be_flushed_i,   // 待刷新的ASID
    input   logic     [VLEN-1:0]                    vaddr_to_be_flushed_i,  // 待刷新的虚拟地址
    
    // TLB刷新信号
    input   logic                                   flush_tlb_i,  // 全量刷新TLB
    
    // 性能计数器
    output  logic                                   itlb_miss_o,  // ITLB未命中计数
    output  logic                                   dtlb_miss_o,  // DTLB未命中计数
    
    // PTW（页表遍历器）与数据缓存接口
    input   dcache_req_o_t                          req_port_i,   // 数据缓存到PTW的响应
    output  dcache_req_i_t                          req_port_o,   // PTW到数据缓存的请求（用于访问页表）
    
    // PMP（物理内存保护）配置
    input   pmpcfg_t  [NrPMPEntries-1:0]            pmpcfg_i,   // PMP配置寄存器
    input   logic     [NrPMPEntries-1:0][PLEN-3:0]  pmpaddr_i   // PMP地址寄存器
);
  // 页表项
localparam type pte_cva6_t = struct packed {  
    logic [9:0] reserved;           // 保留位（未使用，需为0）
    logic [PPNW-1:0] ppn;           // 物理页号（用于拼接物理地址）
    logic [1:0] rsw;                // 软件保留位（操作系统自定义使用）
    logic d;                        // 脏位（1=页被写入过，需硬件更新）
    logic a;                        // 访问位（1=页被访问过，需硬件更新）
    logic g;                        // 全局位（1=所有ASID共享，刷新TLB时不清除）
    logic u;                        // 用户位（1=允许用户模式访问）
    logic x;                        // 执行权限（1=允许执行）
    logic w;                        // 写权限（1=允许写入）
    logic r;                        // 读权限（1=允许读取）
    logic v;                        // 有效位（1=页表项有效）
};

// TLB更新信息
localparam type tlb_update_cva6_t = struct packed { 
    logic                                   valid;    // 更新有效标志（1=需更新TLB）
    logic [PtLevels-2:0]            is_page;  // 页大小标志（多级页表中是否为叶子节点）
    logic [VpnLen-1:0]              vpn;      // 虚拟页号（用于TLB索引）
    logic [ASID_WIDTH-1:0]          asid;     // 地址空间标识符（与VPN共同构成TLB标签）
    logic [VMID_WIDTH-1:0]          vmid;     // 虚拟机ID（Hypervisor模式下区分VM）
    pte_cva6_t                      content;  // S-stage的PTE内容
};

// 权限与异常相关信号
logic iaccess_err;  // 指令访问权限错误（如用户模式访问特权页）
logic i_g_st_access_err;  // G-stage指令访问权限错误（Hypervisor模式）
logic daccess_err;  // 数据访问权限错误（如无写权限却执行存储）
logic canonical_addr_check;  // 虚拟地址规范性检查（如Sv39高25位需符号扩展）
logic d_g_st_access_err;  // G-stage数据访问权限错误（Hypervisor模式）

// 页表遍历（PTW）相关信号
logic ptw_active;  // PTW正在进行页表遍历
logic walking_instr;  // PTW为ITLB未命中而遍历
logic ptw_error;  // PTW遍历出错（如无效PTE）
logic ptw_error_at_g_st;  // G-stage遍历出错（Hypervisor模式）
logic ptw_err_at_g_int_st;  // G-stage内部遍历出错
logic ptw_access_exception;  // PTW访问物理地址时触发PMP异常
logic [PLEN-1:0] ptw_bad_paddr;  // PTW出错的物理地址（用于异常tval）
logic [GPLEN-1:0] ptw_bad_gpaddr;  // G-stage出错的客户物理地址

// TLB更新与虚拟地址
logic [VLEN-1:0] update_vaddr, shared_tlb_vaddr;  // 更新/共享TLB的虚拟地址
tlb_update_cva6_t update_itlb, update_dtlb, update_shared_tlb;  // ITLB/DTLB/共享TLB的更新信息

// ITLB查找信号
logic                       itlb_lu_access;  // ITLB查找请求
pte_cva6_t                  itlb_content;  // ITLB命中的PTE内容
pte_cva6_t                  itlb_g_content;  // G-stage的PTE内容
logic      [  PtLevels-2:0] itlb_is_page;  // ITLB命中的页大小标志
logic                       itlb_lu_hit;  // ITLB命中标志
logic      [     GPLEN-1:0] itlb_gpaddr;  // G-stage翻译后的客户物理地址
logic      [ASID_WIDTH-1:0] itlb_lu_asid;  // ITLB查找的ASID

// DTLB查找信号
logic                       dtlb_lu_access;  // DTLB查找请求
pte_cva6_t                  dtlb_content;  // DTLB命中的PTE内容
pte_cva6_t                  dtlb_g_content;  // G-stage的PTE内容
logic      [  PtLevels-2:0] dtlb_is_page;  // DTLB命中的页大小标志
logic      [ASID_WIDTH-1:0] dtlb_lu_asid;  // DTLB查找的ASID
logic                       dtlb_lu_hit;  // DTLB命中标志
logic      [     GPLEN-1:0] dtlb_gpaddr;  // G-stage翻译后的客户物理地址

// 共享TLB信号
logic shared_tlb_access, shared_tlb_miss;  // 共享TLB访问与未命中
logic shared_tlb_hit, itlb_req;  // 共享TLB命中与ITLB请求

// ITLB查找使能：当指令缓存有取指请求时
assign itlb_lu_access = icache_areq_i.fetch_req;
// DTLB查找使能：当LSU有请求且无未对齐异常时
assign dtlb_lu_access = lsu_req_i & !misaligned_ex_i.valid;
// ITLB使用的ASID
assign itlb_lu_asid   = v_i ? vs_asid_i : asid_i;
// DTLB使用的ASID
assign dtlb_lu_asid   = (ld_st_v_i) ? vs_asid_i : asid_i;

tlb #( 
    .pte_cva6_t       (pte_cva6_t),  // 页表项类型
    .tlb_update_cva6_t(tlb_update_cva6_t),  // TLB更新信息类型
    .TLB_ENTRIES      (InstrTlbEntries)
) i_itlb (
    .clk_i            (clk_i),  // 时钟
    .rst_ni           (rst_ni),  // 复位
    .flush_i          (flush_tlb_i),   // 全量刷新
    .s_st_enbl_i      (enable_translation_i),  // S-stage翻译使能
    .update_i         (update_itlb),   // 来自共享TLB的更新信息
    .lu_access_i      (itlb_lu_access),// 查找请求
    .lu_asid_i        (itlb_lu_asid),  // 查找的ASID
    .lu_vaddr_i       (icache_areq_i.fetch_vaddr),  // 查找的虚拟地址
    .lu_content_o     (itlb_content),  // 输出命中的PTE内容
    .asid_to_be_flushed_i,          // 待刷新的ASID（连接顶层输入）
    .vaddr_to_be_flushed_i,         // 待刷新的虚拟地址（连接顶层输入）
    .lu_is_page_o     (itlb_is_page),  // 输出页大小标志
    .lu_hit_o         (itlb_lu_hit)    // 输出命中标志
);

tlb #(  
    .pte_cva6_t       (pte_cva6_t),
    .tlb_update_cva6_t(tlb_update_cva6_t),
    .TLB_ENTRIES      (DataTlbEntries)
) i_dtlb (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),

    .flush_i          (flush_tlb_i),
    .s_st_enbl_i      (en_ld_st_translation_i),  // 数据S-stage翻译使能

    .update_i         (update_dtlb),  // 来自共享TLB的更新信息
    
    .lu_access_i      (dtlb_lu_access),  // 查找请求
    .lu_asid_i        (dtlb_lu_asid),  // 查找的ASID
    .lu_vaddr_i       (lsu_vaddr_i),  // 查找的虚拟地址（来自LSU）
    .lu_content_o     (dtlb_content),  // 输出命中的PTE内容
    
    .asid_to_be_flushed_i,
    .vaddr_to_be_flushed_i,
    .lu_is_page_o     (dtlb_is_page),  // 输出页大小标志
    .lu_hit_o         (dtlb_lu_hit)  // 输出命中标志
);

shared_tlb #( 
    .SHARED_TLB_WAYS      (2),  // 共享TLB的路数（2路组相联）
    .pte_cva6_t           (pte_cva6_t),
    .tlb_update_cva6_t    (tlb_update_cva6_t)
) i_shared_tlb (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .flush_i              (flush_tlb_i),
    
    .dtlb_asid_i          (dtlb_lu_asid),  // DTLB的ASID
    .itlb_asid_i          (itlb_lu_asid),  // ITLB的ASID
    .s_st_enbl_i          (enable_translation_i),  // 指令S-stage翻译使能
    .s_ld_st_enbl_i       (en_ld_st_translation_i),  // 数据S-stage翻译使能

    .dtlb_access_i        (dtlb_lu_access),  // DTLB访问请求
    .dtlb_hit_i           (dtlb_lu_hit),  // DTLB命中标志
    .dtlb_vaddr_i         (lsu_vaddr_i),  // DTLB访问的虚拟地址

    .itlb_access_i        (itlb_lu_access),  // ITLB访问请求
    .itlb_hit_i           (itlb_lu_hit),  // ITLB命中标志
    .itlb_vaddr_i         (icache_areq_i.fetch_vaddr),  // ITLB访问的虚拟地址

    .shared_tlb_miss_i    (shared_tlb_miss),  // 共享TLB未命中输入（来自PTW）
    
    .itlb_update_o        (update_itlb),  // 更新ITLB的信息
    .dtlb_update_o        (update_dtlb),  // 更新DTLB的信息

    .itlb_miss_o          (itlb_miss_o),  // ITLB未命中输出
    .dtlb_miss_o          (dtlb_miss_o),  // DTLB未命中输出
    
    .shared_tlb_access_o  (shared_tlb_access),  // 共享TLB访问标志
    .shared_tlb_hit_o     (shared_tlb_hit),  // 共享TLB命中标志
    .shared_tlb_vaddr_o   (shared_tlb_vaddr),  // 共享TLB访问的虚拟地址
    .itlb_req_o           (itlb_req),  // ITLB请求标志（用于PTW）
    
    .shared_tlb_update_i  (update_shared_tlb)  // 来自PTW的共享TLB更新信息
);

ptw #(  
    .pte_cva6_t             (pte_cva6_t),
    .tlb_update_cva6_t      (tlb_update_cva6_t),
    .dcache_req_i_t         (dcache_req_i_t),
    .dcache_req_o_t         (dcache_req_o_t)
) i_ptw (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .flush_i, 
    
    .ptw_active_o           (ptw_active),  // PTW活跃标志
    .walking_instr_o        (walking_instr),  // 为指令遍历标志
    .ptw_error_o            (ptw_error),  // PTW出错标志
    .ptw_access_exception_o (ptw_access_exception),  // PMP访问异常标志
    
    .enable_translation_i,  // 指令翻译使能
    .en_ld_st_translation_i,  // 数据翻译使能
    .lsu_is_store_i         (lsu_is_store_i),  // 是否为存储操作
    
    .req_port_i             (req_port_i),  // 缓存响应输入
    .req_port_o             (req_port_o),  // 页表访问请求输出
    
    .shared_tlb_update_o    (update_shared_tlb),
    .update_vaddr_o         (update_vaddr),  // 更新的虚拟地址

    .asid_i,  // 当前ASID

    .shared_tlb_access_i    (shared_tlb_access),  // 共享TLB访问标志
    .shared_tlb_hit_i       (shared_tlb_hit),  // 共享TLB命中标志
    .shared_tlb_vaddr_i     (shared_tlb_vaddr),  // 共享TLB访问的虚拟地址

    .itlb_req_i             (itlb_req),  // ITLB请求标志
    // 页表基地址
    .satp_ppn_i,  // S级页表基地址
    .mxr_i,  // 加载可执行页标志
    // 性能计数器
    .shared_tlb_miss_o      (shared_tlb_miss),  // 共享TLB未命中输出
    // PMP配置
    .pmpcfg_i               (pmpcfg_i),  // PMP配置
    .pmpaddr_i              (pmpaddr_i),  // PMP地址
    .bad_paddr_o            (ptw_bad_paddr)  // 出错的物理地址
);

localparam int PPNWMin = (PPNW - 1 > 29) ? 29 : PPNW - 1;  // PPN宽度适配

always_comb begin : instr_interface  // 组合逻辑：处理指令翻译
    // 默认：MMU禁用时，直接将虚拟地址作为物理地址输出
    icache_areq_o.fetch_valid = icache_areq_i.fetch_req;  // 取指有效标志直通
    // 物理地址 = 虚拟地址的低PLEN位（地址截断）
    icache_areq_o.fetch_paddr  = PLEN'(icache_areq_i.fetch_vaddr[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):0]);
    icache_areq_o.fetch_exception = '0;  // 默认无异常

    // 指令访问权限错误判断：
    // - 使能翻译，且用户模式访问非用户页（!itlb_content.u）
    // - 或特权模式（S）访问用户页（itlb_content.u）
    iaccess_err = icache_areq_i.fetch_req && enable_translation_i &&  //
    (((priv_lvl_i == riscv::PRIV_LVL_U) && ~itlb_content.u)  //
    || ((priv_lvl_i == riscv::PRIV_LVL_S) && itlb_content.u));

    // 若使能翻译
    if ((enable_translation_i)) begin
        // 虚拟地址规范性检查（以Sv39为例：高25位需与bit38一致）
        if (icache_areq_i.fetch_req && !((&icache_areq_i.fetch_vaddr[VLEN-1:SV-1]) == 1'b1 || (|icache_areq_i.fetch_vaddr[VLEN-1:SV-1]) == 1'b0)) begin
            // 不规范地址：触发指令页错误
            icache_areq_o.fetch_exception.cause = riscv::INSTR_PAGE_FAULT;
            icache_areq_o.fetch_exception.valid = 1'b1;
            icache_areq_o.fetch_exception.tval = XLEN'(icache_areq_i.fetch_vaddr);
        end

        icache_areq_o.fetch_valid = 1'b0;  // 翻译未完成时，取指无效

        // 生成物理地址：PPN（来自PTE） + 页内偏移（虚拟地址低12位）
        icache_areq_o.fetch_paddr = {
            itlb_content.ppn,
            icache_areq_i.fetch_vaddr[11:0]
        };

        // 大页处理（如2MB页：页内偏移为21位，需拼接虚拟地址中间位）
        if (PtLevels == 3 && itlb_is_page[PtLevels-2]) begin
            icache_areq_o.fetch_paddr[PPNWMin-(VpnLen/PtLevels):9+PtLevels] = 
                icache_areq_i.fetch_vaddr[PPNWMin-(VpnLen/PtLevels):9+PtLevels];
        end

        // 4KB页处理（无需拼接中间位）
        if (itlb_is_page[0]) begin
            icache_areq_o.fetch_paddr[PPNWMin:12] = icache_areq_i.fetch_vaddr[PPNWMin:12];
        end

        // ITLB命中：输出有效物理地址
        if (itlb_lu_hit) begin
            icache_areq_o.fetch_valid = icache_areq_i.fetch_req;  // 取指有效
            // S-stage权限错误：触发指令页错误
            if (iaccess_err) begin
                icache_areq_o.fetch_exception.cause = riscv::INSTR_PAGE_FAULT;
                icache_areq_o.fetch_exception.valid = 1'b1;
                icache_areq_o.fetch_exception.tval = XLEN'(icache_areq_i.fetch_vaddr);
            end
        // ITLB未命中，PTW正在处理指令翻译
        end else if (ptw_active && walking_instr) begin
            // PTW完成（出错或异常）时，输出有效
            icache_areq_o.fetch_valid = ptw_error | ptw_access_exception;
            if (ptw_error) begin  // PTW翻译出错
              icache_areq_o.fetch_exception.cause = riscv::INSTR_PAGE_FAULT;
              icache_areq_o.fetch_exception.valid = 1'b1;
              icache_areq_o.fetch_exception.tval = XLEN'(update_vaddr);
            end else begin  // PTW物理访问异常（PMP）
              icache_areq_o.fetch_exception.cause = riscv::INSTR_ACCESS_FAULT;
              icache_areq_o.fetch_exception.valid = 1'b1;
              icache_areq_o.fetch_exception.tval = XLEN'(update_vaddr);
            end
        end
    end
end

// 数据接口寄存器（保存当前请求信息，用于多周期处理）
logic [VLEN-1:0] lsu_vaddr_n, lsu_vaddr_q;  // 虚拟地址（现态/次态）
logic [GPLEN-1:0] lsu_gpaddr_n, lsu_gpaddr_q;  // 客户物理地址
logic [31:0] lsu_tinst_n, lsu_tinst_q;  // 指令（异常信息）
logic hs_ld_st_inst_n, hs_ld_st_inst_q;  // Hypervisor指令标志
pte_cva6_t dtlb_pte_n, dtlb_pte_q;  // DTLB的PTE（现态/次态）
pte_cva6_t dtlb_gpte_n, dtlb_gpte_q;  // G-stage的PTE
logic lsu_req_n, lsu_req_q;  // LSU请求（现态/次态）
logic lsu_is_store_n, lsu_is_store_q;  // 存储标志
logic dtlb_hit_n, dtlb_hit_q;  // DTLB命中（现态/次态）
logic [PtLevels-2:0] dtlb_is_page_n, dtlb_is_page_q;  // 页大小标志
exception_t misaligned_ex_n, misaligned_ex_q;  // 未对齐异常

// DTLB命中标志：翻译使能时用DTLB结果，否则恒为1（无需翻译）
assign lsu_dtlb_hit_o = (en_ld_st_translation_i) ? dtlb_lu_hit : 1'b1;

always_comb begin : data_interface  // 组合逻辑：处理数据翻译
    // 寄存器次态赋值（保存当前请求信息）
    lsu_vaddr_n = lsu_vaddr_i;
    lsu_req_n = lsu_req_i;
    dtlb_pte_n = dtlb_content;
    dtlb_hit_n = dtlb_lu_hit;
    lsu_is_store_n = lsu_is_store_i;
    dtlb_is_page_n = dtlb_is_page;
    misaligned_ex_n = misaligned_ex_i;

    // 翻译结果有效标志：默认使用上一拍的请求标志
    lsu_valid_o = lsu_req_q;
    lsu_exception_o = misaligned_ex_q;  // 默认异常为未对齐异常

    // 未对齐异常仅在有请求时有效
    misaligned_ex_n.valid = misaligned_ex_i.valid & lsu_req_i;

    // 虚拟地址规范性检查（同指令逻辑）
    canonical_addr_check = (lsu_req_i && en_ld_st_translation_i &&
          !((&lsu_vaddr_i[VLEN-1:SV-1]) == 1'b1 || (|lsu_vaddr_i[VLEN-1:SV-1]) == 1'b0));

    // 数据访问权限错误判断：
    // - S级且SUM未使能时访问用户页（dtlb_pte_q.u）
    // - 或U级访问非用户页（!dtlb_pte_q.u）
    daccess_err = en_ld_st_translation_i &&
              ((ld_st_priv_lvl_i == riscv::PRIV_LVL_S && (!sum_i ) && dtlb_pte_q.u) ||
    (ld_st_priv_lvl_i == riscv::PRIV_LVL_U && !dtlb_pte_q.u));

    // 默认物理地址：虚拟地址低PLEN位（翻译禁用时）
    lsu_paddr_o = (PLEN)'(lsu_vaddr_q[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):0]);
    // 默认PPN：虚拟地址的页号部分（翻译禁用时）
    lsu_dtlb_ppn_o        = (PPNW)'(lsu_vaddr_n[((PLEN > VLEN) ? VLEN -1: PLEN -1 ):12]);

    // 若使能翻译且无未对齐异常
    if ((en_ld_st_translation_i) && !misaligned_ex_q.valid) begin
        lsu_valid_o = 1'b0;  // 翻译未完成时，结果无效

        // DTLB命中的PPN
        lsu_dtlb_ppn_o = dtlb_content.ppn;
        // 物理地址：PPN + 页内偏移
        lsu_paddr_o = {
            dtlb_pte_q.ppn,
            lsu_vaddr_q[11:0]
        };

        // 大页处理（拼接虚拟地址中间位）
        if (PtLevels == 3 && dtlb_is_page_q[PtLevels-2]) begin
            lsu_paddr_o[PPNWMin-(VpnLen/PtLevels):9+PtLevels] = 
                lsu_vaddr_q[PPNWMin-(VpnLen/PtLevels):9+PtLevels];
            lsu_dtlb_ppn_o[PPNWMin-(VpnLen/PtLevels):9+PtLevels] = 
                lsu_vaddr_n[PPNWMin-(VpnLen/PtLevels):9+PtLevels];
        end

        // 4KB页处理
        if (dtlb_is_page_q[0]) begin
            lsu_dtlb_ppn_o[PPNWMin:12] = lsu_vaddr_n[PPNWMin:12];
            lsu_paddr_o[PPNWMin:12] = lsu_vaddr_q[PPNWMin:12];
        end

        // DTLB命中且有请求：输出有效结果
        if (dtlb_hit_q && lsu_req_q) begin
            lsu_valid_o = 1'b1;

            // 存储操作的异常检查
            if (lsu_is_store_q) begin
                // S-stage存储异常
                if ((en_ld_st_translation_i ) && (!dtlb_pte_q.w || daccess_err || canonical_addr_check || !dtlb_pte_q.d)) begin
                    lsu_exception_o.cause = riscv::STORE_PAGE_FAULT;
                    lsu_exception_o.valid = 1'b1;
                    lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, lsu_vaddr_q};
                end
            // 加载操作的异常检查
            end else begin
                // S-stage加载异常（权限错误或地址不规范）
                if (daccess_err || canonical_addr_check) begin
                    lsu_exception_o.cause = riscv::LOAD_PAGE_FAULT;
                    lsu_exception_o.valid = 1'b1;
                    lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, lsu_vaddr_q};
                end
            end
        // DTLB未命中，PTW正在处理数据翻译
        end else if (ptw_active && !walking_instr) begin
            if (ptw_error) begin  // PTW翻译出错
                lsu_valid_o = 1'b1;  // 出错时结果有效
                if (lsu_is_store_q) begin  // 存储操作
                    lsu_exception_o.cause = riscv::STORE_PAGE_FAULT;
                    lsu_exception_o.valid = 1'b1;
                    lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr};
                end else begin  // 加载操作
                  lsu_exception_o.cause = riscv::LOAD_PAGE_FAULT;
                  lsu_exception_o.valid = 1'b1;
                  lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr};
                end
            end
            // PTW物理访问异常（PMP）
            if (ptw_access_exception) begin
                lsu_valid_o = 1'b1;
                if (lsu_is_store_q && PtLevels == 3) begin  // 存储操作异常
                  lsu_exception_o.cause = riscv::ST_ACCESS_FAULT;
                  lsu_exception_o.valid = 1'b1;
                  lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr};
                end else begin  // 加载操作异常
                  lsu_exception_o.cause = riscv::LD_ACCESS_FAULT;
                  lsu_exception_o.valid = 1'b1;
                  lsu_exception_o.tval = {{XLEN - VLEN{lsu_vaddr_q[VLEN-1]}}, update_vaddr};
                end
            end
        end
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin  // 时序逻辑：更新寄存器
    if (~rst_ni) begin  // 复位时初始化
        lsu_vaddr_q     <= '0;
        lsu_gpaddr_q    <= '0;
        lsu_req_q       <= '0;
        dtlb_pte_q      <= '0;
        dtlb_gpte_q     <= '0;
        dtlb_hit_q      <= '0;
        lsu_is_store_q  <= '0;
        dtlb_is_page_q  <= '0;
        lsu_tinst_q     <= '0;
        hs_ld_st_inst_q <= '0;
        misaligned_ex_q <= '0;
    end else begin  // 时钟沿更新寄存器（次态→现态）
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