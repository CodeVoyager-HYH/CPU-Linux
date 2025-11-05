module tlb 
  import config_pkg::*;
  import mmu_pkg::*;
#(  
  parameter type pte_cva6_t = logic,
  parameter type tlb_update_cva6_t = logic,
  parameter int unsigned TLB_ENTRIES = 4
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // 更新信息
  input   tlb_update_cva6_t       update_i,
  input   logic [ASID_WIDTH-1:0]  asid_to_be_flushed_i,   // 待刷新的ASID
  input   logic [VLEN-1:0]        vaddr_to_be_flushed_i,  // 待刷新的虚拟地址

  // 地址查找接口
  input   logic                   lu_access_i,            // 查找请求有效
  input   logic [ASID_WIDTH-1:0]  lu_asid_i,              // 查找的ASID（地址空间ID）
  input   logic [VLEN-1:0]        lu_vaddr_i,             // 待查找的虚拟地址
  output  pte_cva6_t              lu_content_o,           // 查找到的S/VS-stage PTE
  output  logic [PtLevels-2:0]    lu_is_page_o,           // 查找到的页大小（如4K/2M）
  output  logic                   lu_hit_o                // 查找命中标志
);
  
  // TLB条目标签结构（存储匹配所需的关键信息）
  struct packed {
    logic [ASID_WIDTH-1:0] asid;  // 地址空间ID（区分不同进程）
    // 虚拟页号（VPN）：每级页表对应一段VPN（如Sv39的VPN2、VPN1、VPN0）
    logic [PtLevels-1:0][(VpnLen/PtLevels)-1:0] vpn;
    logic [PtLevels-2:0] is_page;  // 页大小标志（如[0]→1G，[1]→2M，区分不同级别页）
    logic valid;  // 条目有效标志
  } [TLB_ENTRIES-1:0] tags_q, tags_n;  // tags_q：当前标签寄存器；tags_n：下一状态

  struct packed {
    pte_cva6_t pte;   // S-stage页表项（包含物理页号、权限等）
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

        // VPN匹配逻辑：查找的虚拟地址与TLB条目的VPN是否一致
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
    lu_g_content_o = '{default: 0};
    lu_is_page_o   = '{default: 0};
    match_asid     = '{default: 0};
    match_vmid     = RVH ? '{default: 0} : '{default: 1};
    match_stage    = '{default: 0};
    g_content      = '{default: 0};
    lu_gpaddr_o    = '{default: 0};

    // 遍历所有TLB条目，判断是否命中
    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      // ASID匹配：查找的ASID与条目ASID一致，或条目是全局映射（PTE.g=1，忽略ASID）
      match_asid[i] = ((lu_asid_i == tags_q[i].asid || content_q[i].pte.g) && s_st_enbl_i) || !s_st_enbl_i;

      // 虚拟化模式下，VMID匹配：查找的VMID与条目VMID一致，或未使能G-stage
      if (RVH) begin
        match_vmid[i] = (lu_vmid_i == tags_q[i].vmid && g_st_enbl_i) || !g_st_enbl_i;
      end

      // 转换阶段匹配：当前转换上下文（v_i、G/S使能）与条目标记的一致
      match_stage[i] = tags_q[i].v_st_enbl[HYP_EXT*2:0] == v_st_enbl[HYP_EXT*2:0];

      // 命中条件：条目有效 + ASID匹配 + VMID匹配 + 阶段匹配 + 存在某级页表匹配
      if (tags_q[i].valid && match_asid[i] && match_vmid[i] && match_stage[i] && |level_match[i]) begin
        lu_is_page_o = is_page_o[i];  // 输出页大小
        lu_content_o = content_q[i].pte;  // 输出S/VS-stage PTE
        lu_hit_o     = 1'b1;  // 标记命中
        lu_hit[i]    = 1'b1;  // 标记该条目命中

        // 计算guest物理地址（GPA）：S-stage转换结果
        if (RVH) begin
          if (s_st_enbl_i) begin
            // 常规页（4K）：PTE的PPN + 虚拟地址页内偏移（12位）
            lu_gpaddr_o = {content_q[i].pte.ppn[(GPPNW-1):0], lu_vaddr_i[11:0]};
            // 2M超级页：补充VPN0到GPA（因PPN已对齐到2M，低21位由VPN0和偏移组成）
            if (tags_q[i].is_page[1][0])
              lu_gpaddr_o[12+VpnLen/PtLevels-1:12] = lu_vaddr_i[12+VpnLen/PtLevels-1:12];
            // 1G超级页：补充VPN1和VPN0到GPA
            if (tags_q[i].is_page[0][0])
              lu_gpaddr_o[12+2*VpnLen/PtLevels-1:12] = lu_vaddr_i[12+2*(VpnLen/PtLevels)-1:12];
          end else begin
            // 未使能S-stage：虚拟地址直接作为GPA
            lu_gpaddr_o = GPLEN'(lu_vaddr_i[(XLEN == 32?VLEN:GPLEN)-1:0]);
          end

          // G-stage转换（若使能）：将GPA转换为HPA（Hypervisor物理地址）
          if (g_st_enbl_i) begin
            lu_g_content_o = content_q[i].gpte;  // 输出G-stage PTE
            // 2M超级页：补充GPA的VPN0到G-stage PPN
            if (tags_q[i].is_page[1][HYP_EXT])
              lu_g_content_o.ppn[(VpnLen/PtLevels)-1:0] = lu_gpaddr_o[12+(VpnLen/PtLevels)-1:12];
            // 1G超级页：补充GPA的VPN1和VPN0到G-stage PPN
            if (tags_q[i].is_page[0][HYP_EXT])
              lu_g_content_o.ppn[2*(VpnLen/PtLevels)-1:0] = lu_gpaddr_o[12+2*(VpnLen/PtLevels)-1:12];
          end
        end
      end
    end
  end

    // 刷新辅助信号：待刷新的地址/ID是否为0（用于判断全局刷新）
  logic asid_to_be_flushed_is0;
  logic vaddr_to_be_flushed_is0;

  assign asid_to_be_flushed_is0   = ~(|asid_to_be_flushed_i);  // ASID=0（全局刷新）

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
        else if (asid_to_be_flushed_is0 && (|vaddr_level_match[i][0] ) && (~vaddr_to_be_flushed_is0))
          tags_n[i].valid = 1'b0;
         // 按ASID和虚拟地址刷新（如SFENCE.VMA vaddr asid，非全局映射）
        else if ((!content_q[i].pte.g) && (|vaddr_level_match[i][0]) && (asid_to_be_flushed_i == tags_q[i].asid ) && (!vaddr_to_be_flushed_is0) && (!asid_to_be_flushed_is0))
          tags_n[i].valid = 1'b0;
        // 按ASID刷新所有地址（如SFENCE.VMA 0 asid，非全局映射）
        else if ((!content_q[i].pte.g) && (vaddr_to_be_flushed_is0) && (asid_to_be_flushed_i  == tags_q[i].asid ) && (!asid_to_be_flushed_is0))
          tags_n[i].valid = 1'b0;
      end else if (update_i.valid & replace_en[i] & !lu_hit_o) begin  // 处理TLB更新（来自PTW）
        // 写入新标签：ASID、VMID、VPN、页大小、转换阶段、有效标志
        tags_n[i] = {
          update_i.asid,
          update_i.vmid,
          ((PtLevels) * (VpnLen / PtLevels))'(update_i.vpn),
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

endmodule