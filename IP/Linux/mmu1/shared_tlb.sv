module shared_tlb #(
  parameters
) (
  input   logic clk_n,
  input   logic rst_ni,
  input   logic flush_i,

  input   logic [ASID_WIDTH-1:0]  dtlb_asid_i,
  input   logic [ASID_WIDTH-1:0]  itlb_asid_i,
  input   logic                   s_st_enbl_i,
  input   logic                   s_ld_st_enbl_i,

  // 用于判断是哪一个tlb未命中
  input   logic                   dtlb_access_i,
  input   logic                   dtlb_hit_i,
  input   logic [VLEN-1:0]        dtlb_va ddr_i,

  input   logic                   itlb_access_i,
  input   logic                   itlb_hit_i,
  input   logic [VLEN-1:0]        itlb_vaddr_i,

  input   logic                   shared_tlb_miss_i,

  // 更新信号，用于把共享tlb的内容更新到对应的tlb中
  output  tlb_update_cva6_t       itlb_update_o,
  output  tlb_update_cva6_t       dtlb_update_o,
  output  logic                   itlb_miss_o,
  output  logic                   dtlb_miss_o,

  output  logic                   shared_tlb_access_o,
  output  logic                   shared_tlb_hit_o,
  output  logic [VLEN-1:0]        shared_tlb_vaddr_o,
  output  logic                   itlb_req_o,
  // share tlb更新信号
  input   tlb_update_cva6_t       shared_tlb_update_i
);
  
  typedef struct packed {
    logic [ASID_WIDTH-1:0] asid;
    logic [PtLevels-1:0][(VpnLen/PtLevels)-1:0] vpn;
    logic [PtLevels-2:0] is_page;
  } shared_tag_t;

  assign shared_tlb_access_o = shared_tlb_access_q;
  assign shared_tlb_hit_o = shared_tlb_hit_d;
  assign shared_tlb_vaddr_o = shared_tlb_vaddr_q;
  assign itlb_req_o = itlb_req_q;
  assign v_st_enbl = { s_st_enbl_i,  s_ld_st_enbl_i};

  generate  // 匹配
    for(genvar i = 0; i < SHARED_TLB_WAY; i++) begin // 遍历所有路
      for(genvar x = 0; x < PtLevels; x++) begin // 遍历所有页表等级
        assign page_match[i][x] = (x==0) ? 1 : 
                                          (shared_tag_rd[i].is_page[PtLevels-1-x]);
        assign vpn_match[i][x]  = (vpn_q[x] == shared_tag_rd[i].vpn[x]);
        assign level_match[i][x] = &vpn_match[i][PtLevels-1:x] && page_match[i][x];
      end
    end
  endgenerate

  generate
    // 遍历所有页表级别，更新当前VPN,VPN是9位，低12位是偏移量
    for (genvar w = 0; w < PtLevels; w++) begin
      assign vpn_d[w] = 
          // 若ITLB访问且未命中，用ITLB的虚拟地址更新VPN
          ((|v_st_enbl[1]) && itlb_access_i && ~itlb_hit_i && ~dtlb_access_i) ? 
          itlb_vaddr_i[12+((VpnLen/PtLevels)*(w+1))-1:12+((VpnLen/PtLevels)*w)] : 
          // 若DTLB访问且未命中，用DTLB的虚拟地址更新VPN
          (((|v_st_enbl[0]) && dtlb_access_i && ~dtlb_hit_i) ? 
          dtlb_vaddr_i[12+((VpnLen/PtLevels)*(w+1))-1:12+((VpnLen/PtLevels)*w)] : 
          vpn_q[w]);  // 否则保持当前VPN
    end
  endgenerate

/////////////////////////////////

always_comb begin : itlb_dtlb_miss
    itlb_miss_o         = 1'b0;
    dtlb_miss_o         = 1'b0;

    tag_rd_en           = '0;
    pte_rd_en           = '0;

    itlb_req_d          = 1'b0;
    dtlb_req_d          = 1'b0;

    tlb_update_asid_d   = tlb_update_asid_q;
    tlb_update_vmid_d   = tlb_update_vmid_q;

    shared_tlb_access_d = '0;
    shared_tlb_vaddr_d  = shared_tlb_vaddr_q;

    tag_rd_addr         = '0;
    pte_rd_addr         = '0;
    i_req_d             = i_req_q;

    // ITLB 未命中
    if ((v_st_enbl[1]) & itlb_access_i & ~itlb_hit_i & ~dtlb_access_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = itlb_vaddr_i[12+:$clog2(SharedTlbDepth)];
      pte_rd_en           = '1;
      pte_rd_addr         = itlb_vaddr_i[12+:$clog2(SharedTlbDepth)];

      itlb_miss_o         = shared_tlb_miss_i;
      itlb_req_d          = 1'b1;
      tlb_update_asid_d   = itlb_asid_i;

      shared_tlb_access_d = '1;
      shared_tlb_vaddr_d  = itlb_vaddr_i;
      i_req_d             = 1;

    end else if ((v_st_enbl[0]) & dtlb_access_i & ~dtlb_hit_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = dtlb_vaddr_i[12+:$clog2(SharedTlbDepth)];
      pte_rd_en           = '1;
      pte_rd_addr         = dtlb_vaddr_i[12+:$clog2(SharedTlbDepth)];

      dtlb_miss_o         = shared_tlb_miss_i;
      dtlb_req_d          = 1'b1;
      tlb_update_asid_d   = dtlb_asid_i;
      tlb_update_vmid_d   = lu_vmid_i;

      shared_tlb_access_d = '1;
      shared_tlb_vaddr_d  = dtlb_vaddr_i;
      i_req_d             = 0;
    end
  end  

  always_comb begin : tag_comparison
    shared_tlb_hit_d = 1'b0;
    dtlb_update_o    = '0;
    itlb_update_o    = '0;

    for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
        match_asid[i] = (((tlb_update_asid_q == shared_tag_rd[i].asid) || pte[i][0].g) && v_st_enbl[i_req_q][0]) || !v_st_enbl[i_req_q][0];
        match_stage[i] = shared_tag_rd[i].v_st_enbl == v_st_enbl[i_req_q];

        if (shared_tag_valid[i] && match_asid[i] && match_vmid[i] && match_stage[i]) begin
          if (|level_match[i]) begin
            shared_tlb_hit_d = 1'b1;
            if (itlb_req_q) begin
              itlb_update_o.valid = 1'b1;
              itlb_update_o.vpn = itlb_vpn_q;
              itlb_update_o.is_page = shared_tag_rd[i].is_page;
              itlb_update_o.content = pte[i][0];
              itlb_update_o.v_st_enbl = shared_tag_rd[i].v_st_enbl;
              itlb_update_o.asid = tlb_update_asid_q;
            end else if (dtlb_req_q) begin
              dtlb_update_o.valid = 1'b1;
              dtlb_update_o.vpn = dtlb_vpn_q;
              dtlb_update_o.is_page = shared_tag_rd[i].is_page;
              dtlb_update_o.content = pte[i][0];
              dtlb_update_o.v_st_enbl = shared_tag_rd[i].v_st_enbl;
              dtlb_update_o.asid = tlb_update_asid_q;
            end
          end
        end
      end
    
  end  

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      itlb_vpn_q <= '0;
      dtlb_vpn_q <= '0;
      tlb_update_asid_q <= '{default: 0};
      shared_tlb_access_q <= '0;
      shared_tlb_vaddr_q <= '0;
      shared_tag_valid_q <= '0;
      vpn_q <= 0;
      itlb_req_q <= '0;
      dtlb_req_q <= '0;
      i_req_q <= 0;
      shared_tag_valid <= '0;
    end else begin
      itlb_vpn_q <= itlb_vaddr_i[SV-1:12];
      dtlb_vpn_q <= dtlb_vaddr_i[SV-1:12];
      tlb_update_asid_q <= tlb_update_asid_d;
      shared_tlb_access_q <= shared_tlb_access_d;
      shared_tlb_vaddr_q <= shared_tlb_vaddr_d;
      shared_tag_valid_q <= shared_tag_valid_d;
      vpn_q <= vpn_d;
      itlb_req_q <= itlb_req_d;
      dtlb_req_q <= dtlb_req_d;
      i_req_q <= i_req_d;
      shared_tag_valid <= shared_tag_valid_q[tag_rd_addr];

    end
  end

  // ------------------
  // Update and Flush
  // ------------------
  always_comb begin : update_flush
    shared_tag_valid_d = shared_tag_valid_q;
    tag_wr_en = '0;
    pte_wr_en = '0;

    if (flush_i) begin
      shared_tag_valid_d = '0;
    end else if (shared_tlb_update_i.valid) begin
      for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
        if (repl_way_oh_d[i]) begin // 替换独热码
          shared_tag_valid_d[shared_tlb_update_i.vpn[$clog2(SharedTlbDepth)-1:0]][i] = 1'b1;
          tag_wr_en[i] = 1'b1;
          pte_wr_en[i] = 1'b1;
        end
      end
    end
  end  //update_flush

  assign shared_tag_wr.asid = shared_tlb_update_i.asid;
  assign shared_tag_wr.vmid = shared_tlb_update_i.vmid;
  assign shared_tag_wr.is_page = shared_tlb_update_i.is_page;
  assign shared_tag_wr.v_st_enbl = v_st_enbl[i_req_q];

  genvar z;
  generate
    for (z = 0; z < PtLevels; z++) begin : gen_shared_tag
      assign shared_tag_wr.vpn[z] = shared_tlb_update_i.vpn[((VpnLen/PtLevels)*(z+1))-1:((VpnLen/PtLevels)*z)];
    end

  endgenerate


  assign tag_wr_addr = shared_tlb_update_i.vpn[$clog2(SharedTlbDepth)-1:0];
  assign tag_wr_data = shared_tag_wr;

  assign pte_wr_addr = shared_tlb_update_i.vpn[$clog2(SharedTlbDepth)-1:0];

  assign pte_wr_data[0] = shared_tlb_update_i.content[XLEN-1:0];
  assign pte_wr_data[1] = shared_tlb_update_i.g_content[XLEN-1:0];

  logic [SHARED_TLB_WAYS-1:0] out;
  assign out[repl_way] = 1'b1;

  assign way_valid = shared_tag_valid_q[shared_tlb_update_i.vpn[$clog2(SharedTlbDepth)-1:0]];
  assign repl_way = (all_ways_valid) ? rnd_way : inv_way;
  assign update_lfsr = shared_tlb_update_i.valid & all_ways_valid;
  assign repl_way_oh_d = (shared_tlb_update_i.valid) ? out : '0;

  lzc #(
      .WIDTH(SHARED_TLB_WAYS)
  ) i_lzc (
      .in_i   (~way_valid),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  lfsr #(
      .LfsrWidth(8),
      .OutWidth ($clog2(SHARED_TLB_WAYS))
  ) i_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );

  ///////////////////////////////////////////////////////
  // memory arrays and regs
  ///////////////////////////////////////////////////////

  assign tag_req  = tag_wr_en | tag_rd_en;
  assign tag_we   = tag_wr_en;
  assign tag_addr = tag_wr_en ? tag_wr_addr : tag_rd_addr;

  assign pte_req  = pte_wr_en | pte_rd_en;
  assign pte_we   = pte_wr_en;
  assign pte_addr = pte_wr_en ? pte_wr_addr : pte_rd_addr;

  for (genvar i = 0; i < SHARED_TLB_WAYS; i++) begin : gen_sram

      // Tag RAM
      sram #(
          .DATA_WIDTH($bits(shared_tag_t)),
          .NUM_WORDS (SharedTlbDepth)
      ) tag_sram (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .req_i  (tag_req[i]),
          .we_i   (tag_we[i]),
          .addr_i (tag_addr),
          .wuser_i('0),
          .wdata_i(tag_wr_data),
          .be_i   ('1),
          .ruser_o(),
          .rdata_o(tag_rd_data[i])
      );

      assign shared_tag_rd[i] = shared_tag_t'(tag_rd_data[i]);

        // PTE RAM
        sram #(
            .DATA_WIDTH(XLEN),
            .NUM_WORDS (SharedTlbDepth)
        ) pte_sram (
            .clk_i  (clk_i),
            .rst_ni (rst_ni),
            .req_i  (pte_req[i]),
            .we_i   (pte_we[i]),
            .addr_i (pte_addr),
            .wuser_i('0),
            .wdata_i(pte_wr_data[a]),
            .be_i   ('1),
            .ruser_o(),
            .rdata_o(pte_rd_data[i][a])
        );
        assign pte[i][a] = pte_cva6_t'(pte_rd_data[i][a]);

  end
endmodule