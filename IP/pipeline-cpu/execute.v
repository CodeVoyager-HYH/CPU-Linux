`include "define.v"
module execute(
	//execute计算需要用到的信号
    input wire [31:0] 	regE_i_valA,
    input wire [31:0] 	regE_i_valB,
    input wire [31:0] 	regE_i_imm ,
	input wire [31:0]	regE_i_pc, 

    input wire [1:0]	regE_i_alu_valA_sel,
    input wire [1:0]	regE_i_alu_valB_sel,
    input wire [3:0] 	regE_i_alu_func_sel,
	input wire  		regE_i_need_jump,
	input wire          regE_i_is_jalr,

	input wire  [31:0]	regE_i_pre_pc,
	output wire [31:0]	execute_o_pre_pc,
    output wire [31:0] 	execute_o_valE,
	output wire 		execute_o_need_jump
);
//如果执行阶段，判断出两者的rd

wire [31:0] alu_valA			= 	(regE_i_alu_valA_sel == `alu_valA_sel_valA) ?  regE_i_valA : 
									(regE_i_alu_valA_sel == `alu_valA_sel_pc  )	?  regE_i_pc   : 
									(regE_i_alu_valA_sel == `alu_valA_sel_zero) ?  32'd0 	   : regE_i_valA;

wire [31:0] alu_valB			= 	(regE_i_alu_valB_sel == `alu_valB_sel_valB) ?  regE_i_valB : 
									(regE_i_alu_valB_sel == `alu_valB_sel_imm)  ?  regE_i_imm  : regE_i_valB;


assign execute_o_valE 			=	(regE_i_alu_func_sel == `alu_func_add 		)   ?  alu_valA + alu_valB							:
									(regE_i_alu_func_sel == `alu_func_sub 		)   ?  alu_valA - alu_valB							:
									(regE_i_alu_func_sel == `alu_func_sll 		)   ?  alu_valA << alu_valB[4:0] 					:
									(regE_i_alu_func_sel == `alu_func_slt  		)   ?  ($signed(alu_valA)   < $signed(alu_valB))   ? 32'd1 : 32'd0	:
									(regE_i_alu_func_sel == `alu_func_sltu		)   ?  ($unsigned(alu_valA) < $unsigned(alu_valB)) ? 32'd1 : 32'd0	:
									(regE_i_alu_func_sel == `alu_func_xor		)   ?  {alu_valA[31:0]	^ alu_valB[31:0]}						  	:
									(regE_i_alu_func_sel == `alu_func_srl		) 	?  {$unsigned(alu_valA) >>  alu_valB[4:0]}		:
									(regE_i_alu_func_sel == `alu_func_sra		)  	?  {$signed(alu_valA)   >>> alu_valB[4:0]}  	:
									(regE_i_alu_func_sel == `alu_func_or 		)  	?  alu_valA | alu_valB							:
									(regE_i_alu_func_sel == `alu_func_and 		)  	?  alu_valA & alu_valB							: 32'd0;

assign execute_o_need_jump = regE_i_need_jump;
assign execute_o_pre_pc = regE_i_is_jalr   ? (execute_o_valE  & ~1) :
						  regE_i_need_jump ?  execute_o_valE     	: regE_i_pre_pc;

endmodule