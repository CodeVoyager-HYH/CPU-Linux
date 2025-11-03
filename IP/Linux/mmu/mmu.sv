// TODO:实现pmp和pma并且集成Dcache到mmu

module mmu 
  import mmu_pkg::*;
#(
  parameter type icache_ares_t = logic,
  parameter type icache_arsp_t = logic,
) (
  input logic clk_i,
  input logic rst_ni,

  // I-Cache接口
  input  icache_ares_t  icache_req_i,  // Icache 向 MMU 请求
  output icache_arsp_t  icache_rsp_o,  // MMU 向 Icache 响应

  // dTLB接口
    // dTLB requests
  input  logic [26:0]   io_dtlb_ptw_req_bits_addr,      // 需要翻译的虚拟页号
  input  logic [1:0]    io_dtlb_ptw_req_bits_prv,       // 当前访问的特权级(00=U, 01=S, 11=M)
  input  logic          io_dtlb_ptw_req_bits_store,     // 该请求是否需要写操作
  input  logic          io_dtlb_ptw_req_valid,          // 请求有效信号
  output logic          io_dtlb_ptw_req_ready,          // PTW是否准备好接收请求

    // dTLB responses
  output logic          io_dtlb_ptw_resp_bits_error,    // 翻页失败
  output logic [26:0]   io_dtlb_ptw_resp_bits_pte_ppn,  // 页表物理页号
  output logic          io_dtlb_ptw_resp_bits_pte_d,
  output logic          io_dtlb_ptw_resp_bits_pte_u,
  output logic          io_dtlb_ptw_resp_bits_pte_x,
  output logic          io_dtlb_ptw_resp_bits_pte_w,
  output logic          io_dtlb_ptw_resp_bits_pte_r,
  output logic          io_dtlb_ptw_resp_bits_pte_v,  
  output logic [1:0]    io_dtlb_ptw_resp_bits_level,    // 命中的页表层级（0=leaf, 1/2=上层页表）
  output logic          io_dtlb_ptw_resp_valid,         // 响应有效信号

    // CSR mstatus
  output logic          io_dtlb_ptw_status_mxr,
  output logic          io_dtlb_ptw_status_sum,
  output logic          io_dtlb_ptw_invalidate,         // 刷新 TLB

  // D-cache 接口
    // dCache requests
  output logic          io_ptw_mem_req_valid,           // PWT发出读取请求
  output logic [39:0]   io_ptw_mem_req_bits_addr,       // 要访问的物理地址
  output logic [63:0]   io_ptw_mem_req_bits_data,       // 写入数据  
  output logic          io_ptw_mem_req_bits_phys,       // 是否是物理访问
  output logic [3:0]    io_ptw_mem_req_bits_typ,        // 访问宽度
  output logic          io_ptw_mem_req_bits_kill,       // 是否取消请求
  input  logic          io_ptw_mem_req_ready,           // D-cache是否准备好

    // dCache response
  input logic           io_ptw_mem_resp_valid,
  input logic [63:0]    io_ptw_mem_resp_bits_data,
  input logic           io_ptw_mem_resp_bits_nack,

  // PTW控制信号
  output logic          io_ptw_invalidate,              // PTW控制下级模块是否需要刷新

  // CSR
  input logic [1:0]   csr_priv_lvl_i,                   // 当前特权级
  input logic         csr_en_translation_i,             // 是否启用地址翻译,若关闭则使用物理直通

  input logic [31:0]  csr_satp_i,                       // SATP寄存器
  input logic         csr_flush_i,                      // 页表刷新
  input logic [63:0]  csr_status_i,                     // mstatus

  // 性能计数器
  output logic io_core_pmu_itlb_access,
  output logic io_core_pmu_itlb_miss,
  output logic io_core_pmu_itlb_miss_cycle,
  output logic io_core_pmu_ptw_hit,
  output logic io_core_pmu_ptw_miss,
  output logic io_core_pmu_ptw_mem_req,

);
/**************************************************/
/* --                iTLB                      -- */
/**************************************************/

//iCache
cache_tlb_comm_t icache_itlb_comm;
tlb_cache_comm_t itlb_icache_comm;
logic [26:0] itlb_icache_resp_ppn_27bits; // 27 bit ppn truncation

assign icache_itlb_comm.req.valid = icache_treq_i.valid;
assign icache_itlb_comm.req.asid = '0;
assign icache_itlb_comm.req.vpn = icache_treq_i.vpn;
assign icache_itlb_comm.req.passthrough = 1'b0;
assign icache_itlb_comm.req.instruction = 1'b1;
assign icache_itlb_comm.req.store = '0;

assign icache_tresp_o.miss = itlb_icache_comm.resp.miss;
assign icache_tresp_o.ppn = itlb_icache_resp_ppn_27bits;
assign icache_tresp_o.xcpt = itlb_icache_comm.resp.xcpt;

//PTW
tlb_ptw_comm_t itlb_ptw_comm;
ptw_tlb_comm_t ptw_itlb_comm; 

//PMU
assign io_core_pmu_itlb_miss_cycle = itlb_icache_comm.resp.miss && !itlb_icache_comm.tlb_ready;

tlb_wrapper __itlb__(
    .clk_i                      (clk_i), 
    .rstn_i                     (rstn_i),
    // iCache
        // Input
    .mem_treq_i_valid           (icache_itlb_comm.req.valid),
    .mem_treq_i_asid            (icache_itlb_comm.req.asid),
    .mem_treq_i_vpn             (icache_itlb_comm.req.vpn),
    .mem_treq_i_passthrough     (icache_itlb_comm.req.passthrough),
    .mem_treq_i_instruction     (icache_itlb_comm.req.instruction),
    .mem_treq_i_store           (icache_itlb_comm.req.store),
        // Output
    .mem_req_ready_o            (itlb_icache_comm.tlb_ready),
    .tlb_tresp_o_miss           (itlb_icache_comm.resp.miss),
    .tlb_tresp_o_ppn            (itlb_icache_resp_ppn_27bits),
    .tlb_tresp_o_xcpt__if       (itlb_icache_comm.resp.xcpt.fetch),
    .tlb_tresp_o_xcpt_ld        (itlb_icache_comm.resp.xcpt.load),
    .tlb_tresp_o_xcpt_st        (itlb_icache_comm.resp.xcpt.store),
    .tlb_tresp_o_hit_idx        (itlb_icache_comm.resp.hit_idx),
    // PTW connection
        // Input
    .ptw_req_ready_i            (ptw_itlb_comm.ptw_ready),
    .ptw_invalidate_i           (ptw_itlb_comm.invalidate_tlb),
    .ptw_resp_i_valid           (ptw_itlb_comm.resp.valid),
    .ptw_resp_i_error           (ptw_itlb_comm.resp.error),
    .ptw_resp_i_pte_ppn         (ptw_itlb_comm.resp.pte.ppn),
    .ptw_resp_i_pte_rfs         (ptw_itlb_comm.resp.pte.rfs),
    .ptw_resp_i_pte_d           (ptw_itlb_comm.resp.pte.d),
    .ptw_resp_i_pte_a           (ptw_itlb_comm.resp.pte.a),
    .ptw_resp_i_pte_g           (ptw_itlb_comm.resp.pte.g),
    .ptw_resp_i_pte_u           (ptw_itlb_comm.resp.pte.u),
    .ptw_resp_i_pte_x           (ptw_itlb_comm.resp.pte.x),
    .ptw_resp_i_pte_w           (ptw_itlb_comm.resp.pte.w),
    .ptw_resp_i_pte_r           (ptw_itlb_comm.resp.pte.r),
    .ptw_resp_i_pte_v           (ptw_itlb_comm.resp.pte.v),
    .ptw_resp_i_level           (ptw_itlb_comm.resp.level),
    .ptw_status_i_sd            (ptw_itlb_comm.ptw_status.sd),
    .ptw_status_i_zero5         (ptw_itlb_comm.ptw_status.zero5),
    .ptw_status_i_sxl           (ptw_itlb_comm.ptw_status.sxl),
    .ptw_status_i_uxl           (ptw_itlb_comm.ptw_status.uxl),
    .ptw_status_i_zero4         (ptw_itlb_comm.ptw_status.zero4),
    .ptw_status_i_tsr           (ptw_itlb_comm.ptw_status.tsr),
    .ptw_status_i_tw            (ptw_itlb_comm.ptw_status.tw),
    .ptw_status_i_tvm           (ptw_itlb_comm.ptw_status.tvm),
    .ptw_status_i_mxr           (ptw_itlb_comm.ptw_status.mxr),
    .ptw_status_i_sum           (ptw_itlb_comm.ptw_status.sum),
    .ptw_status_i_mprv          (ptw_itlb_comm.ptw_status.mprv),
    .ptw_status_i_xs            (ptw_itlb_comm.ptw_status.xs),
    .ptw_status_i_fs            (ptw_itlb_comm.ptw_status.fs),
    .ptw_status_i_mpp           (ptw_itlb_comm.ptw_status.mpp),
    .ptw_status_i_zero3         (ptw_itlb_comm.ptw_status.zero3),
    .ptw_status_i_spp           (ptw_itlb_comm.ptw_status.spp),
    .ptw_status_i_mpie          (ptw_itlb_comm.ptw_status.mpie),
    .ptw_status_i_zero2         (ptw_itlb_comm.ptw_status.zero2),
    .ptw_status_i_spie          (ptw_itlb_comm.ptw_status.spie),
    .ptw_status_i_upie          (ptw_itlb_comm.ptw_status.upie),
    .ptw_status_i_mie           (ptw_itlb_comm.ptw_status.mie),
    .ptw_status_i_zero1         (ptw_itlb_comm.ptw_status.zero1),
    .ptw_status_i_sie           (ptw_itlb_comm.ptw_status.sie),
    .ptw_status_i_uie           (ptw_itlb_comm.ptw_status.uie),
        // Output
    .ptw_req_o_valid            (itlb_ptw_comm.req.valid),
    .ptw_req_o_addr             (itlb_ptw_comm.req.vpn),
    .ptw_req_o_prv              (itlb_ptw_comm.req.prv),
    .ptw_req_o_store            (itlb_ptw_comm.req.store),
    .ptw_req_o_fetch            (itlb_ptw_comm.req.fetch),
    // CSRs
        // Input
    .csr_priv_lvl_i             (csr_priv_lvl_i),
    .csr_en_translation_i       (csr_en_translation_i),
    // PMU
        // Output
    .pmu_tlb_access_o           (io_core_pmu_itlb_access),
    .pmu_tlb_miss_o             (io_core_pmu_itlb_miss)
);

/**************************************************/
/* --                PTW                       -- */
/**************************************************/

// dTLB-PTW signals
tlb_ptw_comm_t dtlb_ptw_comm;
assign dtlb_ptw_comm.req.valid  = io_dtlb_ptw_req_valid; 
assign dtlb_ptw_comm.req.vpn    = io_dtlb_ptw_req_bits_addr; 
assign dtlb_ptw_comm.req.prv    = io_dtlb_ptw_req_bits_prv; 
assign dtlb_ptw_comm.req.store  = io_dtlb_ptw_req_bits_store; 
assign dtlb_ptw_comm.req.fetch  = '0;

ptw_tlb_comm_t ptw_dtlb_comm;
assign io_dtlb_ptw_req_ready            = ptw_dtlb_comm.ptw_ready;
assign io_dtlb_ptw_resp_valid           = ptw_dtlb_comm.resp.valid;
assign io_dtlb_ptw_resp_bits_error      = ptw_dtlb_comm.resp.error;
assign io_dtlb_ptw_resp_bits_pte_ppn    = ptw_dtlb_comm.resp.pte.ppn;
assign io_dtlb_ptw_resp_bits_pte_u      = ptw_dtlb_comm.resp.pte.u;
assign io_dtlb_ptw_resp_bits_pte_x      = ptw_dtlb_comm.resp.pte.x;
assign io_dtlb_ptw_resp_bits_pte_w      = ptw_dtlb_comm.resp.pte.w;
assign io_dtlb_ptw_resp_bits_pte_r      = ptw_dtlb_comm.resp.pte.r;
assign io_dtlb_ptw_resp_bits_pte_v      = ptw_dtlb_comm.resp.pte.v;
assign io_dtlb_ptw_resp_bits_pte_d      = ptw_dtlb_comm.resp.pte.d;
assign io_dtlb_ptw_resp_bits_level      = ptw_dtlb_comm.resp.level;
assign io_dtlb_ptw_status_mxr           = ptw_dtlb_comm.ptw_status.mxr;
assign io_dtlb_ptw_status_sum           = ptw_dtlb_comm.ptw_status.sum;
assign io_dtlb_ptw_invalidate           = ptw_dtlb_comm.invalidate_tlb;

// PTW-dMEM signals
ptw_dmem_comm_t ptw_dmem_comm;
assign io_ptw_mem_req_valid             = ptw_dmem_comm.req.valid;
assign io_ptw_mem_req_bits_addr         = ptw_dmem_comm.req.addr;
assign io_ptw_mem_req_bits_cmd          = ptw_dmem_comm.req.cmd;
assign io_ptw_mem_req_bits_data         = ptw_dmem_comm.req.data;
assign io_ptw_mem_req_bits_kill         = ptw_dmem_comm.req.kill;
assign io_ptw_mem_req_bits_phys         = 1'b1;
assign io_ptw_mem_req_bits_typ          = 4'b0011;

assign io_core_pmu_ptw_mem_req = ptw_dmem_comm.req.valid && io_ptw_mem_req_ready;

dmem_ptw_comm_t dmem_ptw_comm;
assign dmem_ptw_comm.dmem_ready         = io_ptw_mem_req_ready;
assign dmem_ptw_comm.resp.valid         = io_ptw_mem_resp_valid;
assign dmem_ptw_comm.resp.addr          = '0;
assign dmem_ptw_comm.resp.tag_addr      = '0;
assign dmem_ptw_comm.resp.cmd           = '0;
assign dmem_ptw_comm.resp.typ           = '0;
assign dmem_ptw_comm.resp.data          = io_ptw_mem_resp_bits_data;
assign dmem_ptw_comm.resp.nack          = io_ptw_mem_resp_bits_nack;
assign dmem_ptw_comm.resp.replay        = '0; 
assign dmem_ptw_comm.resp.has_data      = '0; 
assign dmem_ptw_comm.resp.data_subw     = '0; 
assign dmem_ptw_comm.resp.store_data    = '0; 
assign dmem_ptw_comm.resp.rnvalid       = '0; 
assign dmem_ptw_comm.resp.rnext         = '0; 
assign dmem_ptw_comm.resp.xcpt_ma_ld    = '0; 
assign dmem_ptw_comm.resp.xcpt_ma_st    = '0; 
assign dmem_ptw_comm.resp.xcpt_pf_ld    = '0; 
assign dmem_ptw_comm.resp.xcpt_pf_st    = '0; 
assign dmem_ptw_comm.resp.ordered       = '0; 

//CSR
csr_ptw_comm_t csr_ptw_comm;
assign csr_ptw_comm.satp = {32'b0, csr_satp_i}; //The PTW obtains ALWAYS a satp of 64 bits
assign csr_ptw_comm.flush = csr_flush_i;
assign csr_ptw_comm.mstatus = csr_status_i;

assign io_ptw_invalidate = ptw_itlb_comm.invalidate_tlb;

//iCache
assign icache_tresp_o.ptw_v = ptw_itlb_comm.resp.valid;

ptw __ptw__ (
    .clk_i(clk_i),
    .rstn_i(rstn_i),

    // iTLB request-response
    .itlb_ptw_comm_i(itlb_ptw_comm), 
    .ptw_itlb_comm_o(ptw_itlb_comm),

    // dTLB request-response
    .dtlb_ptw_comm_i(dtlb_ptw_comm),
    .ptw_dtlb_comm_o(ptw_dtlb_comm),

    // dmem request-response
    .dmem_ptw_comm_i(dmem_ptw_comm),
    .ptw_dmem_comm_o(ptw_dmem_comm),

    // csr interface
    .csr_ptw_comm_i(csr_ptw_comm),

    // pmu interface
    .pmu_ptw_hit_o(io_core_pmu_ptw_hit),
    .pmu_ptw_miss_o(io_core_pmu_ptw_miss)
);
endmodule