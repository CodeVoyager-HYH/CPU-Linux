module check_raw (
    input   logic clk_i,
    input   logic rst_ni,

    input   logic                                [4:0]    rs_i,// 待发射的源寄存器编号
    input   logic [config_pkg::NR_SB_ENTRIES-1:0][4:0]    rd_i,// 所有 scoreboard 里正在执行（已发射未完成）指令的目标寄存器编号。
    input   logic [config_pkg::NR_SB_ENTRIES-1:0]         still_issued_i,
    input   logic [$clog2(config_pkg::NR_SB_ENTRIES)-1:0] issue_pointer_i, // 待发射数据在scoreboard的指针位置
    output  logic [$clog2(config_pkg::NR_SB_ENTRIES)-1:0] idx_o, // 输出有数据冲突的下标
    output  logic valid_o
);

  logic [config_pkg::NR_SB_ENTRIES-1:0] same_rd_as_rs;

  logic [config_pkg::NR_SB_ENTRIES-1:0] same_rd_as_rs_before;
  logic [$clog2(config_pkg::NR_SB_ENTRIES)-1:0] last_before_idx;

  logic [config_pkg::NR_SB_ENTRIES-1:0] same_rd_as_rs_after;
  logic [$clog2(config_pkg::NR_SB_ENTRIES)-1:0] last_after_idx;

  logic                             rs_is_gpr0; 

  for (genvar i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin
    assign same_rd_as_rs[i]        = (rs_i == rd_i[i]) && still_issued_i[i];
    assign same_rd_as_rs_before[i] = (i < issue_pointer_i) && same_rd_as_rs[i];
    assign same_rd_as_rs_after[i]  = (i >= issue_pointer_i) && same_rd_as_rs[i];
  end

  always_comb begin
    last_before_idx = '0;
    last_after_idx  = '0;

    for (int unsigned i = 0; i < config_pkg::NR_SB_ENTRIES; i++) begin  // 寻找最近的数据冲突
      if (same_rd_as_rs_before[i]) begin
        last_before_idx = i;
      end
      if (same_rd_as_rs_after[i]) begin
        last_after_idx = i;
      end
    end
  end

  assign idx_o = |same_rd_as_rs_before ? last_before_idx : last_after_idx;

  assign rs_is_gpr0 = (rs_i == '0) ;
  assign valid_o = |same_rd_as_rs && !rs_is_gpr0;

endmodule
