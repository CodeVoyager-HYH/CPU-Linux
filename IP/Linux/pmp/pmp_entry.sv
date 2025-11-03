module pmp_entry 
  import config_pkg::*;
  import  mmu_pkg::*;
#(
  parameter int unsigned PLEN = 56,
  parameter int unsigned PMP_LEN = 54
) (
  input   logic [PLEN-1:0]    addr_i,
  input   logic [PLEN-1:0]    conf_addr_i,
  input   logic [PLEN-3:0]    conf_addr_prev_i, // 前一个pmp条目的地址配置，TOR模式使用
  input   pmp_addr_mode_t     conf_addr_mode_i, // 地址模式，分别是 OFF/TOR/NA4/NAPOT
  output  logic               match_o
);
  logic [PLEN-1:0] conf_addr_n;
  logic [$clog2(PLEN)-1:0] trail_ones;
  logic [PLEN-1:0] base;
  logic [PLEN-1:0] mask;
  int unsigned size;
  assign conf_addr_n = {2'b11, ~conf_addr_i};
  lzc #(
      .WIDTH(PLEN),
      .MODE (1'b0)
  ) i_lzc (
      .in_i   (conf_addr_n),
      .cnt_o  (trail_ones),
      .empty_o()
  );

  always_comb begin 
    case (conf_addr_mode_i)
      TOR : begin
        base = '0;
        mask = '0;
        size = '0;

        // TOR 模式的地址范围由前一个PMP表项的地址寄存器代表起始地址和当前PMP表项的地址寄存器代表起始地址共同决定
        if (addr_i >= ({2'b0, conf_addr_prev_i} << 2) && addr_i < ({2'b0, conf_addr_i} << 2)) begin  
          match_o = 1'b1;
        end else match_o = 1'b0;

        if (match_o == 0) begin
          assert (addr_i >= ({2'b0, conf_addr_i} << 2) || addr_i < ({2'b0, conf_addr_prev_i} << 2));  // 断言：不匹配时地址需在区间外
        end else begin
          assert (addr_i < ({2'b0, conf_addr_i} << 2) && addr_i >= ({2'b0, conf_addr_prev_i} << 2));  // 断言：匹配时地址需在区间内
        end

      // 2的幂次方对齐
      NAPOT: begin
        size = {{(32 - $clog2(PLEN)) {1'b0}}, trail_ones} + 3;  // 手册规范
        mask = '1 << size;
        base = ({2'b0, conf_addr_i} << 2) & mask;
        match_o = (addr_i & mask) == base ? 1'b1 : 1'b0;

        assert (size >= 2);
        if (conf_addr_mode_i == NAPOT) begin
          assert (size > 2);
          if (size < PLEN - 2) assert (conf_addr_i[size-3] == 0);
          for (int i = 0; i < PLEN - 2; i++) begin
            if (size > 3 && i <= size - 4) begin
              assert (conf_addr_i[i] == 1);  
            end
          end
        end

        if (size < PLEN - 1) begin
          if (base + 2 ** size > base) begin 
            if (match_o == 0) begin
              assert (addr_i >= base + 2 ** size || addr_i < base);
            end else begin
              assert (addr_i < base + 2 ** size && addr_i >= base);
            end
          end else begin
            if (match_o == 0) begin
              assert (addr_i - 2 ** size >= base || addr_i < base);
            end else begin
              assert (addr_i - 2 ** size < base && addr_i >= base);
            end
          end
        end
      end
      end 
      default: begin  // 主要是OFF
        match_o = 0;
        base = '0;
        mask = '0;
        size = '0;
      end
    endcase
  end
endmodule