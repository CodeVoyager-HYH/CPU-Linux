module divider
  import config_pkg::*;
#(
    parameter WIDTH = 64,
    parameter STABLE_HANDSHAKE = 0            
) (
    input logic clk_i,
    input logic rst_ni,
    input logic [$clog2(NR_SB_ENTRIES)-1:0] id_i, 
    input logic [WIDTH-1:0] op_a_i,
    input logic [WIDTH-1:0] op_b_i,
    input logic [1:0] opcode_i,  // 0: udiv, 2: urem, 1: div, 3: rem
    input logic in_vld_i,
    output logic in_rdy_o,
    input logic flush_i,
    output logic out_vld_o,
    input logic out_rdy_i,
    // Serdiv transaction ID - Mult
    output logic [$clog2(NR_SB_ENTRIES)-1:0] id_o,
    // Serdiv result - Mult
    output logic [WIDTH-1:0] res_o
);

  /////////////////////////////////////
  // signal declarations
  /////////////////////////////////////

  enum logic [1:0] {
    IDLE,
    DIVIDE,
    FINISH
  }
      state_d, state_q;

  logic [WIDTH-1:0] res_q, res_d;
  logic [WIDTH-1:0] op_a_q, op_a_d;
  logic [WIDTH-1:0] op_b_q, op_b_d;
  logic op_a_sign, op_b_sign;
  logic op_b_zero, op_b_zero_q, op_b_zero_d;
  logic op_b_neg_one, op_b_neg_one_q, op_b_neg_one_d;

  logic [TRANS_ID_BITS-1:0] id_q, id_d;

  logic rem_sel_d, rem_sel_q;
  logic comp_inv_d, comp_inv_q;
  logic res_inv_d, res_inv_q;

  logic [WIDTH-1:0] add_mux;
  logic [WIDTH-1:0] add_out;
  logic [WIDTH-1:0] add_tmp;
  logic [WIDTH-1:0] b_mux;
  logic [WIDTH-1:0] out_mux;

  logic [$clog2(WIDTH)-1:0] cnt_q, cnt_d;
  logic cnt_zero;

  logic [WIDTH-1:0] lzc_a_input, lzc_b_input, op_b;
  logic [$clog2(WIDTH)-1:0] lzc_a_result, lzc_b_result;
  logic [$clog2(WIDTH+1)-1:0] shift_a;
  logic [  $clog2(WIDTH+1):0] div_shift;

  logic a_reg_en, b_reg_en, res_reg_en, ab_comp, pm_sel, load_en;
  logic lzc_a_no_one, lzc_b_no_one;
  logic div_res_zero_d, div_res_zero_q;


  /////////////////////////////////////
  // align the input operands
  // for faster division
  /////////////////////////////////////

  assign op_a_sign    = op_a_i[$high(op_a_i)];
  assign op_b_sign    = op_b_i[$high(op_b_i)];
  assign op_b_zero    = lzc_b_no_one & ~op_b_sign;
  assign op_b_neg_one = lzc_b_no_one & op_b_sign;

  assign lzc_a_input  = (opcode_i[0] & op_a_sign) ? {~op_a_i[$high(op_a_i)-1:0], 1'b1} : op_a_i;
  assign lzc_b_input  = (opcode_i[0] & op_b_sign) ? ~op_b_i : op_b_i;

  lzc #(
      .MODE (1),     // count leading zeros
      .WIDTH(WIDTH)
  ) i_lzc_a (
      .in_i   (lzc_a_input),
      .cnt_o  (lzc_a_result),
      .empty_o(lzc_a_no_one)
  );

  lzc #(
      .MODE (1),     // count leading zeros
      .WIDTH(WIDTH)
  ) i_lzc_b (
      .in_i   (lzc_b_input),
      .cnt_o  (lzc_b_result),
      .empty_o(lzc_b_no_one)
  );

  assign shift_a = (lzc_a_no_one) ? WIDTH : {1'b0, lzc_a_result};
  assign div_shift = {1'b0, lzc_b_result} - shift_a;

  assign op_b = op_b_i <<< div_shift;

  assign div_res_zero_d = (load_en) ? div_shift[$high(div_shift)] : div_res_zero_q;

  /////////////////////////////////////
  // Datapath
  /////////////////////////////////////

  assign pm_sel = load_en & ~(opcode_i[0] & (op_a_sign ^ op_b_sign));

  assign add_mux = (load_en) ? op_a_i : op_b_q;

  assign b_mux = (load_en) ? op_b : {comp_inv_q, (op_b_q[$high(op_b_q):1])};

  assign out_mux     = (rem_sel_q) ? (op_b_neg_one_q ? '0 : op_a_q) : (op_b_zero_q ? '1 : (op_b_neg_one_q ? op_a_q : res_q));

  assign res_o = (res_inv_q) ? -$signed(out_mux) : out_mux;

  assign ab_comp     = ((op_a_q == op_b_q) | ((op_a_q > op_b_q) ^ comp_inv_q)) & ((|op_a_q) | op_b_zero_q);

  assign add_tmp = (load_en) ? 0 : op_a_q;
  assign add_out = (pm_sel) ? add_tmp + add_mux : add_tmp - $signed(add_mux);

  /////////////////////////////////////
  // FSM, counter
  /////////////////////////////////////

  assign cnt_zero = (cnt_q == 0);
  assign cnt_d = (load_en) ? div_shift[$clog2(WIDTH)-1:0] : (~cnt_zero) ? cnt_q - 1 : cnt_q;

  always_comb begin : p_fsm
    // default
    state_d    = state_q;
    in_rdy_o   = 1'b0;
    out_vld_o  = 1'b0;
    load_en    = 1'b0;
    a_reg_en   = 1'b0;
    b_reg_en   = 1'b0;
    res_reg_en = 1'b0;

    unique case (state_q)
      IDLE: begin
        in_rdy_o = 1'b1;

        if (in_vld_i) begin
          in_rdy_o = (STABLE_HANDSHAKE) ? 1'b1 : 1'b0;
          a_reg_en = 1'b1;
          b_reg_en = 1'b1;
          load_en  = 1'b1;
          state_d  = DIVIDE;
        end
      end
      DIVIDE: begin
        if (~(div_res_zero_q | op_b_zero_q | op_b_neg_one_q)) begin
          a_reg_en   = ab_comp;
          b_reg_en   = 1'b1;
          res_reg_en = 1'b1;
        end
        if (div_res_zero_q | op_b_zero_q | op_b_neg_one_q) begin
          out_vld_o = 1'b1;
          state_d   = FINISH;
          if (out_rdy_i) begin
            state_d = IDLE;
          end
        end else if (cnt_zero) begin
          state_d = FINISH;
        end
      end
      FINISH: begin
        out_vld_o = 1'b1;

        if (out_rdy_i) begin
          state_d = IDLE;
        end
      end
      default: state_d = IDLE;
    endcase

    if (flush_i) begin
      a_reg_en = 1'b0;
      b_reg_en = 1'b0;
      load_en  = 1'b0;
      state_d  = IDLE;
    end
  end

  /////////////////////////////////////
  // regs, flags
  /////////////////////////////////////

  assign rem_sel_d = (load_en) ? opcode_i[1] : rem_sel_q;
  assign comp_inv_d = (load_en) ? opcode_i[0] & op_b_sign : comp_inv_q;
  assign op_b_zero_d = (load_en) ? op_b_zero : op_b_zero_q;
  assign op_b_neg_one_d = (load_en) ? op_b_neg_one : op_b_neg_one_q;
  assign res_inv_d       = (load_en) ? (~op_b_zero | opcode_i[1]) & opcode_i[0] & (op_a_sign ^ op_b_sign ^ op_b_neg_one) : res_inv_q;

  assign id_d = (load_en) ? id_i : id_q;
  assign id_o = id_q;

  assign op_a_d = (a_reg_en) ? add_out : op_a_q;
  assign op_b_d = (b_reg_en) ? b_mux : op_b_q;
  assign res_d = (load_en) ? '0 : (res_reg_en) ? {res_q[$high(res_q)-1:0], ab_comp} : res_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (~rst_ni) begin
      state_q        <= IDLE;
      op_a_q         <= '0;
      op_b_q         <= '0;
      res_q          <= '0;
      cnt_q          <= '0;
      id_q           <= '0;
      rem_sel_q      <= 1'b0;
      comp_inv_q     <= 1'b0;
      res_inv_q      <= 1'b0;
      op_b_zero_q    <= 1'b0;
      op_b_neg_one_q <= 1'b0;
      div_res_zero_q <= 1'b0;
    end else begin
      state_q        <= state_d;
      op_a_q         <= op_a_d;
      op_b_q         <= op_b_d;
      res_q          <= res_d;
      cnt_q          <= cnt_d;
      id_q           <= id_d;
      rem_sel_q      <= rem_sel_d;
      comp_inv_q     <= comp_inv_d;
      res_inv_q      <= res_inv_d;
      op_b_zero_q    <= op_b_zero_d;
      op_b_neg_one_q <= op_b_neg_one_d;
      div_res_zero_q <= div_res_zero_d;
    end
  end

endmodule
