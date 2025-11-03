module instr_scan (
  input logic [31: 0] instr_i,

  //正常指令
  output logic rvi_return_o,         // 触发 RAS（返回地址栈）的 pop 操作。
  output logic rvi_call_o,           // 标记 “非压缩调用指令”，触发 RAS 的 push 操作。
  output logic rvi_branch_o,         // 标记 “非压缩条件分支指令”，触发 BHT（分支历史表）的预测逻辑。
  output logic rvi_jalr_o,           // 标记 “非压缩寄存器间接无条件跳转指令”，触发 BTB（分支目标缓冲器）的预测。
  output logic rvi_jump_o,           // 标记 “非压缩立即数无条件跳转指令”，直接用立即数计算目标地址，无需 BTB/BHT
  output logic [ config_pkg::VLEN-1:0] rvi_imm_o,// 提供 RVI 控制流指令的 “跳转偏移量”，用于计算目标地址。

  //压缩指令
  output logic rvc_return_o,
  output logic rvc_call_o,
  output logic rvc_branch_o,
  output logic rvc_jalr_o,
  output logic rvc_jump_o,
  output logic rvc_jr_o,              // 如果rvc_return_o = 1，使用RAS，反之使用BTB
  output logic [ config_pkg::VLEN-1:0] rvc_imm_o
);

// ===============
// 正常指令
// ===============
  logic   is_xret;
  assign is_xret = logic'(instr_i[31:30] == 2'b00) & logic'(instr_i[28:0] == 29'b10000001000000000000001110011);
  assign rvi_return_o = rvi_jalr_o  & ((instr_i[19:15] == 5'd1) | instr_i[19:15] == 5'd5)
                                    & (instr_i[19:15] != instr_i[11:7]);
  assign rvi_call_o   = (rvi_jalr_o | rvi_jump_o) & ((instr_i[11:7] == 5'd1) | instr_i[11:7] == 5'd5);                                  
  assign rvi_branch_o = (instr_i[6:0] == 7'b11_000_11);
  assign rvi_jalr_o   = (instr_i[6:0] == 7'b11_001_11);           // 
  assign rvi_jump_o   = (instr_i[6:0] == 7'b11_011_11) | is_xret; // 无条件跳转
  assign rvi_imm_o    = is_xret ? '0 : (instr_i[3]) ? 
                                          // UJ 型（JAL）：opcode[3] = 1（1101111的bit3=1）
                                          { {44{instr_i[31]}},  // 符号扩展44位（64-20=44）
                                            instr_i[19:12],    // 位19-12
                                            instr_i[20],       // 位20
                                            instr_i[30:21],    // 位30-21
                                            1'b0               // 左移1位（2字节对齐）
                                          } : 
                                          // SB 型（分支）：opcode[3] = 0（1100011的bit3=0）
                                          { {51{instr_i[31]}},  // 符号扩展52位（64-12=52）
                                            instr_i[31],       // 位31（符号位）
                                            instr_i[7],        // 位7
                                            instr_i[30:25],    // 位30-25
                                            instr_i[11:8],     // 位11-8
                                            1'b0               // 左移1位
                                          };

// ===============
// RVC  压缩指令
// ===============
  wire is_jal_r;
  assign is_jal_r     =     (instr_i[15:13] == 3'b100)
                          & (instr_i[6:2] == 5'b00000)
                          & (instr_i[1:0] == 2'b10);
  assign rvc_jr_o     =   is_jal_r & ~instr_i[12];
  assign rvc_jalr_o   =   is_jal_r & instr_i[12];
  assign rvc_call_o   =   rvc_jalr_o ;
  assign rvc_branch_o = ((instr_i[15:13] == 3'b110) | (instr_i[15:13] == 3'b111))
                          & (instr_i[1:0] == 2'b01);
  assign rvc_return_o = ((instr_i[11:7] == 5'd1) | (instr_i[11:7] == 5'd5)) & rvc_jr_o;
  assign rvc_imm_o    = (instr_i[14]) ? 
                          {{56{instr_i[12]}}, 
                            instr_i[6:5], 
                            instr_i[2], 
                            instr_i[11:10], 
                            instr_i[4:3], 
                            1'b0}: 
                          {{53{instr_i[12]}}, 
                            instr_i[8], 
                            instr_i[10:9], 
                            instr_i[6], 
                            instr_i[7], 
                            instr_i[2], 
                            instr_i[11], 
                            instr_i[5:3], 
                            1'b0};

  assign rvc_jump_o   = ((instr_i[15:13] == 3'b101) & (instr_i[1:0] == 2'b01)) ;


endmodule