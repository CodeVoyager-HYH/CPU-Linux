module tlb
  import config_pkg::*;  
  import mmu_pkg::*;
#(
    parameter type pte_cva6_t = logic,  // 页表项（PTE）类型
    parameter type tlb_update_cva6_t = logic,  // TLB更新信息类型
    parameter int unsigned TLB_ENTRIES = 4  // TLB条目数量（缓存的转换结果数量）
) (
    // 时钟与复位
    input   logic clk_i,  // 时钟信号
    input   logic rst_ni,  // 异步复位（低电平有效）
    
    // 刷新信号（使TLB条目失效）
    input   logic                   flush_i,  // 刷新常规转换（S-stage）
    input   logic                   s_st_enbl_i,  // S-stage转换使能
    
    // TLB更新接口（来自PTW，写入新的转换结果）
    input   tlb_update_cva6_t       update_i,
    
    // 地址查找接口（来自处理器核，查询虚拟地址对应的物理地址）
    input   logic                   lu_access_i,  // 查找请求有效
    input   logic [ASID_WIDTH-1:0]  lu_asid_i,  // 查找的ASID（地址空间ID）
    input   logic [VLEN-1:0]        lu_vaddr_i,  // 待查找的虚拟地址
    output  pte_cva6_t              lu_content_o,  // 查找到的S/VS-stage PTE
    input   logic [ASID_WIDTH-1:0]  asid_to_be_flushed_i,  // 待刷新的ASID
    input   logic [VLEN-1:0]        vaddr_to_be_flushed_i,  // 待刷新的虚拟地址
    output  logic [PtLevels-2:0]    lu_is_page_o,  // 查找到的页大小（如4K/2M）
    output  logic                   lu_hit_o  // 查找命中标志
);

  // TLB条目标签结构（存储匹配所需的关键信息）
  struct packed {
    logic [ASID_WIDTH-1:0] asid;  // 地址空间ID（区分不同进程）
    // 虚拟页号（VPN）：每级页表对应一段VPN（如Sv39的VPN2、VPN1、VPN0）
    logic [PtLevels-1:0][(VpnLen/PtLevels)-1:0] vpn;
    logic [PtLevels-2:0] is_page;  // 页大小标志（如[0]→1G，[1]→2M，区分不同级别页）
    logic v_st_enbl;
    logic valid;  // 条目有效标志
  } [TLB_ENTRIES-1:0] tags_q, tags_n;  // tags_q：当前标签寄存器；tags_n：下一状态

  // TLB条目内容结构（存储转换结果）
  struct packed {
    pte_cva6_t pte;   // S/VS-stage页表项（包含物理页号、权限等）
  } [TLB_ENTRIES-1:0] content_q, content_n;  // content_q：当前内容寄存器；content_n：下一状态

    // 匹配信号：用于判断查找地址与TLB条目是否匹配
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] vpn_match;  // VPN匹配（每级页表的VPN是否一致）
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] level_match;  // 级别匹配（某级页表及以上的VPN均匹配，且页大小符合）
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] vaddr_vpn_match;  // 待刷新地址的VPN匹配
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] vaddr_level_match;  // 待刷新地址的级别匹配
  logic [TLB_ENTRIES-1:0] lu_hit;  // 每个条目的命中标志（用于替换逻辑）
  logic [TLB_ENTRIES-1:0] replace_en;  // 替换使能（标记哪个条目将被新内容替换）
  logic [TLB_ENTRIES-1:0] match_asid;  // ASID匹配标志
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] page_match;  // 页大小匹配（条目支持的页大小是否覆盖查找需求）
  logic [TLB_ENTRIES-1:0][PtLevels-1:0] vpage_match;  // 待刷新地址的页大小匹配
  logic [TLB_ENTRIES-1:0][PtLevels-2:0] is_page_o;  // 输出的页大小标志
  logic [TLB_ENTRIES-1:0] match_stage;  // 转换阶段匹配（当前使能的阶段与条目标记的阶段一致）

    genvar i, x, z, w;
  generate
    // 遍历所有TLB条目（i：条目索引）
    for (i = 0; i < TLB_ENTRIES; i++) begin
      // 遍历所有页表级别（x：0→1G，1→2M，2→4K，依页表级数而定）
      for (x = 0; x < PtLevels; x++) begin
        // 检查待刷新的虚拟地址与TLB条目的VPN是否匹配（S-stage）
        assign vaddr_vpn_match[i][x] = vaddr_to_be_flushed_i[12+((VpnLen/PtLevels)*(x+1))-1:12+((VpnLen/PtLevels)*x)] == tags_q[i].vpn[x];
        
      end

      // 遍历所有页表级别，判断页大小是否匹配
      for (x = 0; x < PtLevels; x++) begin
        // 页大小匹配逻辑：条目支持的页大小是否能覆盖当前查找的需求
        // x=0→1G页，x=1→2M页，x=2→4K页（以3级页表为例）
        if (x == 0) begin
          assign page_match[i][x] = 1;  // 4K页是最小页，始终匹配
        end else begin
          // 非虚拟化或最高级页（如1G）：需S-stage和G-stage（若使能）的页大小均匹配
          assign page_match[i][x] = &(tags_q[i].is_page[PtLevels-1-x] );
        end

        // 常规VPN匹配：直接比较对应位段
        assign vpn_match[i][x] = lu_vaddr_i[12+((VpnLen/PtLevels)*(x+1))-1:12+((VpnLen/PtLevels)*x)] == tags_q[i].vpn[x];

        // 级别匹配：某级页表及以上的VPN均匹配，且页大小符合
        assign level_match[i][x] = &vpn_match[i][PtLevels-1:x] && page_match[i][x];

        // 待刷新地址的页大小匹配和级别匹配（用于刷新逻辑）
        assign vpage_match[i][x] = x == 0 ? 1 : tags_q[i].is_page[PtLevels-1-x];
        assign vaddr_level_match[i][x] = &vaddr_vpn_match[i][PtLevels-1:x] && vpage_match[i][x];
      end

      // 重组页大小输出（匹配外部接口格式）
      for (w = 0; w < PtLevels - 1; w++) begin
        assign is_page_o[i][w] = page_match[i][PtLevels-1-w];
      end
    end
  endgenerate

    always_comb begin : translation
    // 默认赋值（避免 latch）
    lu_hit         = '{default: 0};
    lu_hit_o       = 1'b0;
    lu_content_o   = '{default: 0};
    lu_is_page_o   = '{default: 0};
    match_asid     = '{default: 0};
    match_stage    = '{default: 0};

    // 遍历所有TLB条目，判断是否命中
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      // ASID匹配：查找的ASID与条目ASID一致，或条目是全局映射（PTE.g=1，忽略ASID）
      match_asid[i] = ((lu_asid_i == tags_q[i].asid || content_q[i].pte.g) && s_st_enbl_i) || !s_st_enbl_i;
      match_stage[i] = tags_q[i].v_st_enbl == 1;

      // 命中条件：条目有效 + ASID匹配 + 阶段匹配 + 存在某级页表匹配
      if (tags_q[i].valid && match_asid[i]  && match_stage[i] && |level_match[i]) begin
        lu_is_page_o = is_page_o[i];  // 输出页大小
        lu_content_o = content_q[i].pte;  // 输出S/VS-stage PTE
        lu_hit_o     = 1'b1;  // 标记命中
        lu_hit[i]    = 1'b1;  // 标记该条目命中
      end
    end
  end

    // 刷新辅助信号：待刷新的地址/ID是否为0（用于判断全局刷新）
  logic asid_to_be_flushed_is0;
  logic vaddr_to_be_flushed_is0;

  assign asid_to_be_flushed_is0   = ~(|asid_to_be_flushed_i);  // ASID=0（全局刷新）
  assign vaddr_to_be_flushed_is0  = ~(|vaddr_to_be_flushed_i);  // 虚拟地址=0（全局刷新）

  always_comb begin : update_flush
    tags_n    = tags_q;  // 默认保持当前标签
    content_n = content_q;  // 默认保持当前内容

    // 遍历所有TLB条目
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      // 处理常规刷新（S-stage）
      if (flush_i) begin
          // 全局刷新（ASID=0且虚拟地址=0，如SFENCE.VMA x0 x0）
          if (asid_to_be_flushed_is0 && vaddr_to_be_flushed_is0) tags_n[i].valid = 1'b0;
          // 按虚拟地址刷新所有ASID（如SFENCE.VMA vaddr x0）
          else if (asid_to_be_flushed_is0 && (|vaddr_level_match[i]) && (~vaddr_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // 按ASID和虚拟地址刷新（如SFENCE.VMA vaddr asid，非全局映射）
          else if ((!content_q[i].pte.g) && (|vaddr_level_match[i]) && (asid_to_be_flushed_i == tags_q[i].asid ) && (!vaddr_to_be_flushed_is0) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // 按ASID刷新所有地址（如SFENCE.VMA 0 asid，非全局映射）
          else if ((!content_q[i].pte.g) && (vaddr_to_be_flushed_is0) && (asid_to_be_flushed_i  == tags_q[i].asid ) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
      end else if (update_i.valid & replace_en[i] & !lu_hit_o) begin  // 处理TLB更新（来自PTW）
        // 写入新标签：ASID、VPN、页大小、转换阶段、有效标志
        tags_n[i] = {
          update_i.asid,
          ((PtLevels ) * (VpnLen / PtLevels))'(update_i.vpn),
          update_i.is_page,
          update_i.v_st_enbl,
          1'b1
        };
        // 写入新内容：PTE和G-stage PTE
        content_n[i].pte = update_i.content;
      end
    end
  end

    logic [2*(TLB_ENTRIES-1)-1:0] plru_tree_q, plru_tree_n;  // PLRU树（记录条目最近使用情况）

  always_comb begin : plru_replacement
    plru_tree_n = plru_tree_q;  // 默认保持当前PLRU树

    // 当条目命中时，更新PLRU树（标记为“最近使用”）
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      if (lu_hit[i] & lu_access_i) begin  // 该条目命中且有查找请求
        for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin  // 遍历PLRU树的层级
          automatic int unsigned idx_base = $unsigned((2 ** lvl) - 1);  // 层级基地址
          automatic int unsigned shift = $clog2(TLB_ENTRIES) - lvl;  // 位移量
          automatic int unsigned new_index = ~((i >> (shift - 1)) & 32'b1);  // 翻转当前位
          plru_tree_n[idx_base+(i>>shift)] = new_index[0];  // 更新PLRU树节点
        end
      end
    end

    // 解码PLRU树，选择“最久未使用”的条目进行替换
    for (int unsigned i = 0; i < TLB_ENTRIES; i += 1) begin
      automatic logic en = 1'b1;
      for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
        automatic int unsigned idx_base = $unsigned((2 ** lvl) - 1);
        automatic int unsigned shift = $clog2(TLB_ENTRIES) - lvl;
        automatic int unsigned new_index = (i >> (shift - 1)) & 32'b1;
        en &= (new_index[0] ? plru_tree_q[idx_base+(i>>shift)] : ~plru_tree_q[idx_base+(i>>shift)]);
      end
      replace_en[i] = en;  // 标记最久未使用的条目
    end
  end

    always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin  // 复位：所有寄存器清零
      tags_q      <= '{default: 0};
      content_q   <= '{default: 0};
      plru_tree_q <= '{default: 0};
    end else begin  // 时钟边沿更新寄存器
      tags_q      <= tags_n;
      content_q   <= content_n;
      plru_tree_q <= plru_tree_n;
    end
  end

endmodule