// 目前想法，通过仲裁器判断需要优先哪一个执行，然后通过PTE cache判断是否命中
// 如果没有命中则执行正常的分页操作, 支持sv39

module ptw 
  import mmu_pkg::*;
#() 
(
  input logic clk_i,
  input logic rst_ni

  // iTLB 交互
  input   tlb_ptw_comm_t itlb_ptw_comm_i, 
  output  ptw_tlb_comm_t  ptw_itlb_comm_o,

  // dTLB 交互
  input   tlb_ptw_comm_t  dtlb_ptw_comm_i,
  output  ptw_tlb_comm_t  ptw_dtlb_comm_o,

  // 与内存交互
  input   dmem_ptw_comm_t dmem_ptw_comm_i,
  output  ptw_dmem_comm_t ptw_dmem_comm_o,

  // csr 交互
  input   csr_ptw_comm_t  csr_ptw_comm_i,  // satp,flush,mstatus

  // 性能计数器
  output logic            pmu_ptw_hit_o,
  output logic            pmu_ptw_miss_o
);


  // FSM 
  typedef enum logic [2:0] {
    S_READY,    // 空闲，等待TLB请求
    S_REQ,      // 生成并发送访存请求
    S_WAIT,     // 等待内存返回PTE
    S_DONE,     // 解析页表完成，返回给TLB
    S_ERROR     // 页表非法、访问错误等异常
  } ptw_state;
  ptw_state current_state, next_state;

  localparam [4:0] M_XRD = 5'b00000;
  localparam [3:0] MT_D = 4'b0011;

  logic unsigned [$clog2(LEVELS)-1:0] count_d, count_q;
  logic unsigned [$clog2(LEVELS):0] count;

  ptw_tlb_comm_t ptw_tlb_comm; 
  tlb_ptw_comm_t tlb_ptw_comm; 

  logic ptw_ready;
  tlb_ptw_req_t r_req;
  pte_t r_pte;
  pte_t pte;
  pte_t pte_wdata;

  logic [PAGE_LVL_BITS-1:0] vpn_req [LEVELS-1:0];
  logic [PAGE_LVL_BITS-1:0] vpn_idx;
  logic [SIZE_VADDR:0] pte_addr;
  logic invalid_pte;
  logic valid_pte_lvl [LEVELS-1:0];
  logic is_pte_leaf, is_pte_table;
  logic is_pte_ur, is_pte_uw, is_pte_ux;
  logic is_pte_sr, is_pte_sw, is_pte_sx;

  logic [1:0] prv_req;
  logic perm_ok;

  logic resp_err, resp_val;
  logic [63:0] r_resp_ppn;
  logic [PPN_SIZE-1:0] resp_ppn_lvl [LEVELS-1:0];
  logic [PPN_SIZE-1:0] resp_ppn;

  logic pte_cache_hit;
  logic [PPN_SIZE-1:0] pte_cache_data;

  //=================
  // 仲裁器
  //=================
  ptw_tlb_comm_t ptw_tlb_comm; 
  tlb_ptw_comm_t tlb_ptw_comm; 
  ptw_arb i_ptw_arb (
    .clk_i,
    .rst_ni,

    .itlb_ptw_comm_i  (itlb_ptw_comm_i),
    .dtlb_ptw_comm_i  (dtlb_ptw_comm_i),
    .ptw_itlb_comm_o  (ptw_itlb_comm_o),
    .ptw_dtlb_comm_o  (ptw_dtlb_comm_o),

    .ptw_tlb_comm_i   (ptw_tlb_comm),
    .tlb_ptw_comm_o   (tlb_ptw_comm)
  );

  //==================
  // 虚拟地址计算
  //==================
  genvar lvl;
  generate
      for (lvl = 0; lvl < LEVELS; lvl++) begin    // 计算虚拟地址
          logic [VPN_SIZE-1:0] aux_vpn_req;
          assign aux_vpn_req = (r_req.vpn >> ((LEVELS-lvl-1)*PAGE_LVL_BITS));
          assign vpn_req[lvl] = aux_vpn_req[PAGE_LVL_BITS-1:0];
      end
  endgenerate
  assign vpn_idx = vpn_req[count_q];

  genvar c;
  generate
      for (c = 0; c < (LEVELS-1); c++) begin  // 用来判断是叶子节点还是中间表项
          always_comb begin
              if (pte.r || pte.w || pte.x) begin
                  valid_pte_lvl[c] = (pte.ppn[((LEVELS-c-1)*PAGE_LVL_BITS)-1:0] == '0) ? dmem_ptw_comm_i.resp.data[0] : 1'b0; 
              end else begin
                  valid_pte_lvl[c] = dmem_ptw_comm_i.resp.data[0];
              end
          end
      end
  endgenerate
  assign valid_pte_lvl[LEVELS-1] = dmem_ptw_comm_i.resp.data[0];
  assign pte.v = valid_pte_lvl[count_q];

  assign invalid_pte = (((dmem_ptw_comm_i.resp.data >> (PPN_SIZE+10)) != '0) ||
                        ((is_pte_table & pte.v & (pte.d || pte.a || pte.u)))) ? 1'b1 : 1'b0; //Make sure that N, PBMT and Reserved are 0

  assign is_pte_table = pte.v && !pte.x && !pte.w && !pte.r;  // 指向中间页表
  assign is_pte_leaf = pte.v && (pte.x || pte.w || pte.r);    // 叶子节点

  //==================
  // RISC-V  页表权限
  //==================
  assign is_pte_ur = is_pte_leaf && pte.u && pte.r;
  assign is_pte_uw = is_pte_ur && pte.w;
  assign is_pte_ux = pte.v && pte.x && pte.u;
  assign is_pte_sr = is_pte_leaf && pte.r && !pte.u;
  assign is_pte_sw = is_pte_sr && pte.w;
  assign is_pte_sx = pte.v && pte.x && !pte.u;

  // 计算下一级pte物理地址
  logic [63:0] aux_pte_addr;
  assign aux_pte_addr = {{(64-(PPN_SIZE+PAGE_LVL_BITS+$clog2(riscv_pkg::XLEN/8))){1'b0}}, {r_pte.ppn, vpn_idx, {{($clog2(riscv_pkg::XLEN/8))}{1'b0}}}};
  assign pte_addr = aux_pte_addr[SIZE_VADDR:0] ; // Sv39: (r_pte.ppn << 12) + (vpn_idx << 3)

  // PTW Ready
  assign ptw_ready = (current_state == S_READY);

  // Catch Request from TLB(Arb) & PTE response from dmem
  always_ff @(posedge clk_i, negedge rstn_i) begin
      if (!rstn_i) begin
          r_req <= '0;
          r_pte <= '0;
      end else begin
          if ((current_state == S_WAIT) && dmem_ptw_comm_i.resp.valid) begin
              r_pte <= pte;
          end else if ((current_state == S_REQ) && pte_cache_hit && (count_q < $unsigned(LEVELS-1))) begin
              r_pte.ppn <= pte_cache_data; 
          end else if (ptw_ready & tlb_ptw_comm.req.valid) begin
              r_req <= tlb_ptw_comm.req;
              r_pte.ppn <= csr_ptw_comm_i.satp[PPN_SIZE-1:0];
          end
      end
  end


  //================
  // PTW Cache
  //================
  ptw_ptecache_entry_t [PTW_CACHE_SIZE-1:0] ptecache_entry;
  logic access_hit;
  logic full_cache;
  logic unsigned [$clog2(PTW_CACHE_SIZE)-1:0] hit_idx;              // 命中下标
  logic unsigned [$clog2(PTW_CACHE_SIZE)-1:0] plru_eviction_idx;    // 替换下标
  logic unsigned [$clog2(PTW_CACHE_SIZE)-1:0] priorityEncoder_idx;  // Cache未满时的写入下标
  logic [PTW_CACHE_SIZE-1:0] valid_vector;
  logic [PTW_CACHE_SIZE-1:0] hit_vector;

  assign full_cache =& valid_vector; //And Reduction
  assign pte_cache_hit =| hit_vector; //Or Reduction

  pseudoLRU #(    // 最近替换算法
    .ENTRIES(PTW_CACHE_SIZE)
  ) ptw_PLRU (
    .clk_i,
    .rst_ni,
    .access_hit_i       (access_hit),
    .access_idx_i       (hit_idx),
    .replacement_idx_o  (plru_eviction_idx)
  );

  always_comb begin
    for (int i = 0; i < PTW_CACHE_SIZE; i++) begin
      hit_vector[i] = ((ptecache_entry[i].tags == pte_addr) && ptecache_entry[i].valid (ptecache_entry[i].asid == csr_ptw_comm_i.satp[59:44])) ? 1'b1 : 1'b0;
      valid_vector[i] = ptecache_entry[i].valid;
    end
  end

  logic found;
  always_comb begin
    hit_idx = '0;
    pte_cache_data = '0;
    found = 1'b0; // Control variable
    for (int i = 0; (i < PTW_CACHE_SIZE) && (!found); i++) begin
      if (hit_vector[i]) begin
        hit_idx = $unsigned(trunc_ptw_cache_size($unsigned(i)));
        pte_cache_data = ptecache_entry[i].data;
        found = 1'b1;
      end
    end
  end

  logic found2;
  always_comb begin
    priorityEncoder_idx = '0;
    found2 = 1'b0;
    for (int i = 0; (i < PTW_CACHE_SIZE) && (!found2); i++) begin
      if (!valid_vector[i]) begin
        priorityEncoder_idx = trunc_ptw_cache_size($unsigned(i));
        found2 = 1'b1;
      end
    end
  end

  // Cache 更新
  always_ff @(posedge clk or negedge rst_ni) begin
    if(!rst_ni) begin
      for(int i = 0; i < PTW_CACHE_SIZE; i++) begin
        ptecache_entry[i] <= '0;
        access_hit        <= 1'b0;
      end
    end
    else begin
      access_hit <= 1'b0;
      // Cache写入
      if (dmem_ptw_comm_i.resp.valid && is_pte_table && !pte_cache_hit) begin // 传回的数据有效+指向下一级页表+当前这个页表项不在cache中
        if (full_cache) begin // Cache 已满，使用LRU替换算法
          ptecache_entry[plru_eviction_idx].valid <= 1'b1;
          ptecache_entry[plru_eviction_idx].tags  <= pte_addr;
          ptecache_entry[plru_eviction_idx].data  <= pte.ppn;
          ptecache_entry[plru_eviction_idx].asid  <= csr_ptw_comm_i.satp[59:44];
        end
        else begin  // 未满
          ptecache_entry[priorityEncoder_idx].valid <= 1'b1;
          ptecache_entry[priorityEncoder_idx].tags  <= pte_addr;
          ptecache_entry[priorityEncoder_idx].data  <= pte.ppn;
          ptecache_entry[priorityEncoder_idx].asid  <= csr_ptw_comm_i.satp[59:44];
        end
      end
    end
  end

  // 页表项的访问权限检查逻辑
  assign prv_req = r_req.prv; // prv_req = 当前请求的特权级 1=S 0=U

  always_comb begin
    if (prv_req[0]) begin // S模式
          if (csr_ptw_comm_i.mstatus.sum) begin // S模式是否可以访问用户态
            if (r_req.fetch) perm_ok = is_pte_sx || is_pte_ux;
            else begin
                if (r_req.store) perm_ok = is_pte_sw || is_pte_uw;
                else if (csr_ptw_comm_i.mstatus.mxr) perm_ok = is_pte_sr || is_pte_ur || is_pte_ux || is_pte_sx;
                else perm_ok = is_pte_sr || is_pte_ur;
            end
        end else begin
            if (r_req.fetch) perm_ok = is_pte_sx;
            else begin
                if (r_req.store) perm_ok = is_pte_sw;
                else if (csr_ptw_comm_i.mstatus.mxr) perm_ok = is_pte_sr || is_pte_sx;
                else perm_ok = is_pte_sr;
            end
        end
    end else begin // U模式
        if (r_req.fetch) perm_ok = is_pte_ux;
        else begin
            if (r_req.store) perm_ok = is_pte_uw;
            else if (csr_ptw_comm_i.mstatus.mxr) perm_ok = is_pte_ur || is_pte_ux;
            else perm_ok = is_pte_ur;
        end
    end
  end

  // PTW向内存发送请求
  always_comb begin
    pte_wdata = '0;
    pte_wdata.a = 1'b1;
  end

  assign ptw_dmem_comm_o.req.phys = 1'b1;
  assign ptw_dmem_comm_o.req.cmd  = M_XRD;
  assign ptw_dmem_comm_o.req.typ  = MT_D;
  assign ptw_dmem_comm_o.req.addr = pte_addr;
  assign ptw_dmem_comm_o.req.kill = 1'b0;
  assign ptw_dmem_comm_o.req.data = { {(64-$bits(pte_wdata)){1'b0}},
                                    pte_wdata.ppn, 
                                    pte_wdata.rfs, 
                                    pte_wdata.d,
                                    pte_wdata.a,
                                    pte_wdata.g,
                                    pte_wdata.u,
                                    pte_wdata.x,
                                    pte_wdata.w,
                                    pte_wdata.r,
                                    pte_wdata.v
                                    };

  // TLB 回复
  assign resp_err = (current_state == S_ERROR);
  assign resp_val = (current_state == S_DONE) || resp_err;

  assign r_resp_ppn = {{(64-(SIZE_VADDR-11)){1'b0}}, pte_addr[SIZE_VADDR:12]}; // pte_addr >> 12
  genvar j;
  generate
      for (j = 0; j < (LEVELS-1); j++) begin
          logic [63:0] aux_resp_ppn_lvl;
          assign aux_resp_ppn_lvl = {{(64-$bits(r_resp_ppn[63:(LEVELS-j-1)*PAGE_LVL_BITS])-$bits(r_req.vpn[PAGE_LVL_BITS*(LEVELS-j-1)-1:0])){1'b0}}, 
                                      r_resp_ppn[63:(LEVELS-j-1)*PAGE_LVL_BITS], 
                                      r_req.vpn[PAGE_LVL_BITS*(LEVELS-j-1)-1:0]};
          assign resp_ppn_lvl[j] = aux_resp_ppn_lvl[PPN_SIZE-1:0];
      end
  endgenerate
  assign resp_ppn_lvl[LEVELS-1] = r_resp_ppn[PPN_SIZE-1:0];
  assign resp_ppn = resp_ppn_lvl[count_q];

  // TLB送往仲裁器
  assign ptw_tlb_comm.resp.valid = resp_val;
  assign ptw_tlb_comm.resp.error = resp_err;
  assign ptw_tlb_comm.resp.level = count_q;
  assign ptw_tlb_comm.resp.pte.ppn = resp_ppn;
  assign ptw_tlb_comm.resp.pte.rfs = r_pte.rfs;
  assign ptw_tlb_comm.resp.pte.d = r_pte.d;
  assign ptw_tlb_comm.resp.pte.a = r_pte.a;
  assign ptw_tlb_comm.resp.pte.g = r_pte.g;
  assign ptw_tlb_comm.resp.pte.u = r_pte.u;
  assign ptw_tlb_comm.resp.pte.x = r_pte.x;
  assign ptw_tlb_comm.resp.pte.w = r_pte.w;
  assign ptw_tlb_comm.resp.pte.r = r_pte.r;
  assign ptw_tlb_comm.resp.pte.v = r_pte.v;
  assign ptw_tlb_comm.ptw_ready = ptw_ready;
  assign ptw_tlb_comm.ptw_status = csr_ptw_comm_i.mstatus;
  assign ptw_tlb_comm.invalidate_tlb = csr_ptw_comm_i.flush;

  always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        current_state <= S_READY;
        count_q <= '0;
    end
    else begin
        current_state <= next_state;
        count_q <= count_d;
    end
  end

  always_comb begin
    count_d = count_q;
    count = count_q + 1'b1;
    pmu_ptw_hit_o = 1'b0;
    pmu_ptw_miss_o = 1'b0;
    ptw_dmem_comm_o.req.valid = 1'b0;
    next_state = current_state;
    case (current_state)
        S_READY : begin
            count_d = '0;
            if (tlb_ptw_comm.req.valid) next_state = S_REQ;
            else next_state = S_READY;
        end
        S_REQ : begin
            ptw_dmem_comm_o.req.valid = 1'b1;
            if (pte_cache_hit && (count_q < $unsigned(LEVELS-1))) begin
                ptw_dmem_comm_o.req.valid = 1'b0;
                pmu_ptw_hit_o = 1'b1;
                count_d = count[1:0];
                next_state = S_REQ;
            end else if (dmem_ptw_comm_i.dmem_ready) begin
                next_state = S_WAIT;
            end else begin
                next_state = S_REQ;
            end
        end
        S_WAIT : begin
            if (dmem_ptw_comm_i.resp.nack) begin
                next_state = S_REQ;
            end else if (dmem_ptw_comm_i.resp.valid) begin
                if (invalid_pte) begin
                    next_state = S_ERROR;
                end else if (is_pte_table && (count_q < $unsigned(LEVELS-1))) begin
                    count_d = count[1:0];
                    pmu_ptw_miss_o = 1'b1;
                    next_state = S_REQ;
                end else if (is_pte_leaf) begin
                    next_state = S_DONE;
                end 
                else begin
                    next_state = S_ERROR;
                end
            end
            else begin 
                next_state = S_WAIT;
            end
        end
        S_DONE : begin
            next_state = S_READY;
        end
        S_ERROR : begin
            next_state = S_READY;
        end
    endcase
  end

endmodule