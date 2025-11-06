module moduleName 
  import config_pkg::*;
#(
  parameter type fu_data_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  input fu_data_t fu_data_i,
  input  logic                                 mult_valid_i,
  output logic     [$clog2(NR_SB_ENTRIES)-1:0] result_o,
  output logic                                 mult_valid_o,
  output logic                                 mult_ready_o,
  output logic     [$clog2(NR_SB_ENTRIES)-1:0] mult_trans_id_o
);
  logic mul_valid;
  logic div_valid;
  logic div_ready_i;  // receiver of division result is able to accept the result
  logic [$clog2(NR_SB_ENTRIES)-1:0] mul_trans_id;
  logic [$clog2(NR_SB_ENTRIES)-1:0] div_trans_id;
  logic [XLEN-1:0] mul_result;
  logic [XLEN-1:0] div_result;
  //================================
  // 操作类型选择(判断指令是乘法还是触发)
  //================================
  logic div_valid_op;
  logic mul_valid_op;

  assign mul_valid_op = ~flush_i && mult_valid_i && (fu_data_i.operation inside { MUL, MULH, MULHU, MULHSU, MULW, CLMUL, CLMULH, CLMULR });
  assign div_valid_op = ~flush_i && mult_valid_i && (fu_data_i.operation inside { DIV, DIVU, DIVW, DIVUW, REM, REMU, REMW, REMUW }); 

  //=============================
  // 输出仲裁
  //=============================
  assign div_ready_i      = (mul_valid) ? 1'b0 : 1'b1;
  assign mult_trans_id_o  = (mul_valid) ? mul_trans_id : div_trans_id;
  assign result_o         = (mul_valid) ? mul_result : div_result;
  assign mult_valid_o     = div_valid | mul_valid;

  //===========================================
  // 乘法器 
  // 它是一个简单的流水线乘法器：
  //     无需握手 (ready)，每个周期都能接受新操作；
  //     输出结果延迟一个周期；
  //     输出 mul_valid 表示结果有效
  //===========================================
  multiplier i_multiplier (
      .clk_i,
      .rst_ni,
      .trans_id_i     (fu_data_i.trans_id),
      .operation_i    (fu_data_i.operation),
      .operand_a_i    (fu_data_i.operand_a),
      .operand_b_i    (fu_data_i.operand_b),
      .result_o       (mul_result),
      .mult_valid_i   (mul_valid_op),
      .mult_valid_o   (mul_valid),
      .mult_trans_id_o(mul_trans_id)
  );

  //===========================
  // 除法器
  //  输入阶段：
  //   当 in_vld_i && in_rdy_o == 1 -> 输入握手成功（接收新除法任务）
  //  输出阶段：
  //   当 out_vld_o && out_rdy_i == 1 -> 输出握手成功（结果被接收）
  //===========================
  logic [XLEN-1:0]
      operand_b,
      operand_a;  
  logic [XLEN-1:0] result;  
  logic            div_signed; 
  logic            rem;  
  logic word_op_d, word_op_q;  

  assign div_signed = fu_data_i.operation inside {DIV, DIVW, REM, REMW};
  assign rem        = fu_data_i.operation inside {REM, REMU, REMW, REMUW};

  always_comb begin
    operand_a = '0;
    operand_b = '0;
    word_op_d = word_op_q;

    if (mult_valid_i && fu_data_i.operation inside {DIV, DIVU, DIVW, DIVUW, REM, REMU, REMW, REMUW}) begin
      if (fu_data_i.operation == DIVW || fu_data_i.operation == DIVUW || fu_data_i.operation == REMW || fu_data_i.operation == REMUW) begin
        if (div_signed) begin
          operand_a = sext32to64(fu_data_i.operand_a[31:0]);
          operand_b = sext32to64(fu_data_i.operand_b[31:0]);
        end else begin
          operand_a = fu_data_i.operand_a[31:0];
          operand_b = fu_data_i.operand_b[31:0];
        end

        word_op_d = 1'b1;
      end else begin
        operand_a = fu_data_i.operand_a;
        operand_b = fu_data_i.operand_b;
        word_op_d = 1'b0;
      end
    end
  end

  serdiv #(
      .WIDTH  (XLEN)
  ) i_div (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .id_i     (fu_data_i.pointer),
      .op_a_i   (operand_a),
      .op_b_i   (operand_b),
      .opcode_i ({rem, div_signed}),   // 00: udiv, 10: urem, 01: div, 11: rem
      .in_vld_i (div_valid_op),
      .in_rdy_o (mult_ready_o),
      .flush_i  (flush_i),
      .out_vld_o(div_valid),
      .out_rdy_i(div_ready_i),
      .id_o     (div_trans_id),
      .res_o    (result)
  );

  assign div_result = (word_op_q) ? sext32to64(result) : result;

  // ---------------------
  // Registers
  // ---------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      word_op_q <= '0;
    end else begin
      word_op_q <= word_op_d;
    end
  end
endmodule