module alu 
  import riscv_pkg::*;
#(
  parameter type fu_data_t = logic
  ) (
  input  fu_data_t                    fu_data_i,

  output logic [config_pkg::XLEN-1:0] result_o,         // ALU的计算结果，用于修改目标寄存器
  output logic                        alu_branch_res_o  // ALU比较运算用于分支跳转
);
  logic [config_pkg::XLEN-1:0] result;
  logic [config_pkg::XLEN-1:0] operand_a;
  logic [config_pkg::XLEN-1:0] operand_b;
  logic                        alu_branch_res;
  logic [config_pkg::XLEN-1:0] add_result;
  logic [config_pkg::XLEN-1:0] slliw_result;
  logic [config_pkg::XLEN-1:0] sraiw_result;
  logic [config_pkg::XLEN-1:0] srliw_result;
  logic [config_pkg::XLEN-1:0] subw_result;

  assign operand_a  = fu_data_i.operand_a;
  assign operand_b  = fu_data_i.operand_b;
  assign add_result = operand_a + operand_b;
  assign slliw_result = operand_a << operand_b[5:0];
  assign sraiw_result = $signed(operand_a) >>> operand_b[5:0];
  assign srliw_result = operand_a >> operand_b[4:0];
  assign subw_result  = operand_a - operand_b;

  always_comb begin
    unique case (fu_data_i.operation)
      //Lui(因为rs1直接指向了x0所以可以相加使用), Auipc,
      ADD : result = add_result; 

      //=========================
      // 控制流指令
      //=========================
      EQ  : alu_branch_res = (operand_a == operand_b);  // Beq
      NE  : alu_branch_res = (operand_a != operand_b);  // Bne
      LTS : alu_branch_res = ($signed(operand_a) < $signed(operand_b));     // Blt
      GES : alu_branch_res = ($signed(operand_a) >= $signed(operand_b));    // Bge
      LTU : alu_branch_res = ($unsigned(operand_a) <= $unsigned(operand_b));// Bltu
      GEU : alu_branch_res = ($unsigned(operand_a) >= $unsigned(operand_b));// Bgeu

      //=========================
      // 访存指令 在LSU计算 159行 sb sh sew sd
      //=========================

      // --------------------------------
      // Reg-Immediate Operations
      // --------------------------------
      SLTS: result = ($signed(operand_a) < $signed(operand_b));
      SLTU: result = ($unsigned(operand_a) < $unsigned(operand_b));
      XORL: result = (operand_a ^ operand_b);
      ORL : result = (operand_a | operand_b);
      ANDL: result = (operand_a & operand_b);
      SLL : result = slliw_result;
      SRL : result = (operand_a >> operand_b[5:0]);
      SRA : result = $unsigned(sraiw_result);

      // --------------------------
      // Reg-Reg Operations
      // --------------------------
      SUB : result = (subw_result);
      ADDW: result = {32{adder_result[31]}, add_result[31:0]};
      SLLW: result = {32{slliw_result[31]}, slliw_result[31:0]};
      SRLW: result = {32{srliw_result[31]}, srliw_result[31:0]};
      SRAW: result = {32{sraiw_result[31]}, sraiw_result[31:0]};

      // --------------------------
      // 32bit Reg-Reg Operations
      // -------------------------
      SUBW:result = {32{subw_result[31]}, subw_result[31:0]};
      
      default: begin
        result = '0;
        alu_branch_res = '0;
      end
    endcase
  end

  assign result_o       = result;
  assign alu_branch_res = alu_branch_res_o;
endmodule