module pmp 
  import config_pkg::*;
  import mmu_pkg::*;
#()
( 

  input logic     [PLEN-1:0]                    addr_i,       // 访问物理地址
  input pmp_access_t                            access_type_i,// 访问类型（读/写/执行）
  input priv_lvl_t                              priv_lvl_i,   // 当前特权级

  input logic     [NrPMPEntries-1:0][PLEN-3:0]  conf_addr_i,  // PMP地址配置
  input pmpcfg_t  [NrPMPEntries-1:0]            conf_i,       // PMP配置

  output logic                                  allow_o       // 访问是否被允许
);
  logic [NrPMPEntries-1: 0] match;
  for (genvar i = 0; i < NrPMPEntries; i++) begin
    logic [PLEN-3:0] conf_addr_prev;

    assign conf_addr_prev = (i == 0) ? '0 : conf_addr_i[i-1]; // 特殊情况，当PMP表项的第0个表项且字段为TOR，则表示0

    pmp_entry i_pmp_entry (
      .addr_i          (addr_i),
      .conf_addr_i     (conf_addr_i[i]),
      .conf_addr_prev_i(conf_addr_prev),
      .conf_addr_mode_i(conf_i[i].addr_mode),
      .match_o         (match[i])
    );
  end

  always_comb begin 
    int i;

    allow_o = 1'b1;
    for (i = 0; i < NrPMPEntries; i++) begin
      // 不是M模式和条目被锁定
      if (priv_lvl_i != :PRIV_LVL_M || conf_i[i].locked) begin
        if(match[i]) begin   // 权限判断：访问类型是否在条目允许的范围内
          if ((access_type_i & conf_i[i].access_type) != access_type_i) allow_o = 1'b0;
          else allow_o = 1;
          break;
        end
      end
    end

    if(i == NrPMPEntries) begin
      if (priv_lvl_i == riscv::PRIV_LVL_M) 
        allow_o = 1'b1;
      else 
        allow_o = 0;
    end
  end
endmodule 