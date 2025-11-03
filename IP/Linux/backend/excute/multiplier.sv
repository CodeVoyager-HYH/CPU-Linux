module moduleName 
  import config_pkg::*;
#(
  parameter type fu_op = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic mult_valid_i,

  input logic [$clog2(NR_SB_ENTRIES)-1:0] issue_pointer_i, 
  input logic [$clog2(NR_SB_ENTRIES)-1:0] issue_pointer_o,

  input fu_op operation_i,  // 表示输入的指令

  input logic operand_a_i,
  input logic operand_b_i,  

  output logic  [XLEN-1:0] result_o,
  output logic             mult_valid_o
);

  // 表示是否使用有符号数
  logic sign_a;
  logic sign_b;

  always_comb begin
    sign_a = 1'b0;
    sign_b = 1'b0;

    if(operand_a == MULH) begin
      sign_a = 1'b1;
      sign_b = 1'b1;
    end 
    else if(operation_i == MULHSU) begin
      sign_a = 1'b1;
    end
    else begin
      sign_a = 1'b0;
      sign_b = 1'b0;
    end
  end

  // 乘法执行
  logic mult_valid, mult_valid_q;
  fu_op operator_d, operator_q;
  logic [XLEN*2-1:0] mult_result_d, mult_result_q;
  
  assign mult_result_d = $signed(
                            {operand_a_i[XLEN-1] & sign_a, operand_a_i}
                        ) * $signed(
                            {operand_b_i[XLEN-1] & sign_b, operand_b_i}
                        );

  // 结果选择
  always_comb begin
    unique case (operator_q)
      MULH, MULHU, MULHSU: result_o = mult_result_q[XLEN*2-1:XLEN];
      MULW               : result_o = sext32to64(mult_result_q[31:0]);
      // TODO:可以去加B扩展指令集
    endcase
    default: begin
      result_o = mult_result_q[XLEN-1:0];  // including MUL
    end
  end

  // 输出
  logic
  assign mult_valid_o = mult_valid_q;
  assign mult_valid   = mult_valid_i && (operation_i inside {MUL, MULH, MULHU, MULHSU, MULW, CLMUL, CLMULH, CLMULR});

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mult_valid_q  <= '0;
      operator_q    <= MUL;
      mult_valid_q  <= '0;
    end
    else begin
      issue_pointer_o <= issue_pointer_i;
      mult_valid_q    <= mult_valid;
      operator_q      <= operator_d;
      mult_valid_q    <= mult_result_d;
    end
  end
endmodule