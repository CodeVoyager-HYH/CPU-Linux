`include "define.v"
module decode(
	input wire clk,
	input wire rst,
	input  wire [31:0]  regD_i_instr,

	//写回阶段
	input wire  [31:0]	regW_i_valE,
	input wire  [31:0]	regW_i_valM,
	input wire 	[1:0]	regW_i_wb_valD_sel,
	input wire 	[4:0]	regW_i_wb_rd,
	input wire 			regW_i_wb_reg_wen,
	input wire  [31:0]  regW_i_pc,
	//访存阶段数据前递
	input  wire	[31:0]	regM_i_valE,
	input  wire [31:0]	memory_i_valM,
	input  wire [1:0]	regM_i_wb_valD_sel,
	input  wire [4:0] 	regM_i_wb_rd,
	input  wire 		regM_i_wb_reg_wen,

	//执行阶段数据前递
	input  wire 		regE_i_wb_reg_wen,
	input  wire [4:0]	regE_i_wb_rd,
	input  wire [31:0]	execute_i_valE,


	//write_back
	input wire 		  	write_back_i_wb_reg_wen,
	input wire [4:0] 	write_back_i_wb_rd,
	input wire [31:0] 	write_back_i_wb_valD,

	//execute	
    output wire [31:0] 	decode_o_valA,
    output wire [31:0] 	decode_o_valB,
    output wire [31:0] 	decode_o_imm,
	output wire [1:0]  	decode_o_alu_valA_sel,
	output wire [1:0] 	decode_o_alu_valB_sel,
	output wire [3:0] 	decode_o_alu_func_sel,

	//memory
	output wire [3:0]  	decode_o_mem_rw,
	//write_back
    output wire        	decode_o_wb_reg_wen,
	output wire [4:0]  	decode_o_wb_rd,
	output wire [1:0]  	decode_o_wb_valD_sel,
	output wire [4:0]	decode_o_rs1,
	output wire [4:0]	decode_o_rs2,

	output wire 		decode_o_need_jump,
	output wire 		decode_o_is_jalr
);


//---------------------------------------------decode框架---start-----------------------------------------
wire [31:0]rv32I_instr 			= regD_i_instr;
wire [6:0] rv32I_opcode			= rv32I_instr[6:0]; 
wire [4:0] rv32I_rd     		= rv32I_instr[11:7];
wire [2:0] rv32I_func3  		= rv32I_instr[14:12];
wire [4:0] rv32I_rs1    		= rv32I_instr[19:15];
wire [4:0] rv32I_rs2    		= rv32I_instr[24:20];
wire [6:0] rv32I_func7  		= rv32I_instr[31:25];

//------------------------opcode&TYPE----------------------------------------------------------
wire opcode_I_Logic_Operator 	= (rv32I_opcode == 7'b0010011);
wire opcode_I_LOAD  			= (rv32I_opcode == 7'b0000011);
wire opcode_I_CSR   			= (rv32I_opcode == 7'b1110011);
wire opcode_I_JALR  			= (rv32I_opcode == 7'b1100111);

wire opcode_R_TYPE  			= (rv32I_opcode == 7'b0110011);
wire opcode_B_TYPE  			= (rv32I_opcode == 7'b1100011);
wire opcode_S_TYPE  			= (rv32I_opcode == 7'b0100011);
wire opcode_J_TYPE  			= (rv32I_opcode == 7'b1101111);

wire opcode_U_lui   			= (rv32I_opcode == 7'b0110111);
wire opcode_U_auipc 			= (rv32I_opcode == 7'b0010111);
wire opcode_U_TYPE 			 	= opcode_U_lui | opcode_U_auipc;


wire rv32I_I_Logic_Operator     =   opcode_I_Logic_Operator;
wire rv32I_I_LOAD				= 	opcode_I_LOAD;
wire rv32I_I_JALR               =   opcode_I_JALR;
wire rv32I_I_CSR				= 	opcode_I_CSR;

wire rv32I_I_TYPE  	 		    = 	opcode_I_TYPE;
wire rv32I_S_TYPE    		    = 	opcode_S_TYPE;
wire rv32I_R_TYPE       	    = 	opcode_R_TYPE;
wire rv32I_B_TYPE    		    = 	opcode_B_TYPE;
wire rv32I_J_TYPE  			    = 	opcode_J_TYPE;
wire rv32I_U_TYPE   		    = 	opcode_U_TYPE;
//------------------func3----------------------------------------------------------------
wire func3_000                  = (rv32I_func3 == 3'b000);
wire func3_001                  = (rv32I_func3 == 3'b001);
wire func3_010                  = (rv32I_func3 == 3'b010);
wire func3_011                  = (rv32I_func3 == 3'b011);
wire func3_100                  = (rv32I_func3 == 3'b100);
wire func3_101                  = (rv32I_func3 == 3'b101);
wire func3_110                  = (rv32I_func3 == 3'b110);
wire func3_111                  = (rv32I_func3 == 3'b111);

//R_TYPE
wire func3_R_add_sub            = func3_000;
wire func3_R_sll                = func3_001;
wire func3_R_slt                = func3_010;
wire func3_R_sltu               = func3_011;
wire func3_R_xor                = func3_100;
wire func3_R_srl_sra            = func3_101;
wire func3_R_or                 = func3_110;
wire func3_R_and                = func3_111;
//B_type
wire func3_B_beq                = func3_000;
wire func3_B_bne                = func3_001;
wire func3_B_blt                = func3_100;
wire func3_B_bge                = func3_101;
wire func3_B_bltu               = func3_110;
wire func3_B_bgeu               = func3_111;
//I_type
wire func3_I_addi               = func3_000;
wire func3_I_slli               = func3_001;
wire func3_I_slti               = func3_010;
wire func3_I_sltiu              = func3_011;
wire func3_I_xori               = func3_100;
wire func3_I_srli_srai          = func3_101;
wire func3_I_ori                = func3_110;
wire func3_I_andi               = func3_111;

wire func3_I_lb                 = func3_000;
wire func3_I_lh                 = func3_001;
wire func3_I_lw                 = func3_010;
wire func3_I_lbu                = func3_100;
wire func3_I_lhu                = func3_101;

wire func3_I_csrrw              = func3_001;
wire func3_I_csrrs              = func3_010;

//S_type
wire func3_S_sb             	= func3_000;
wire func3_S_sh             	= func3_001;
wire func3_S_sw             	= func3_010;


//-----------------------------------func7-------------------------------
wire func7_0000000              = (rv32I_func7 == 7'b0000000);
wire func7_0100000              = (rv32I_func7 == 7'b0100000);
wire func7_sra                  = func7_0100000;
wire func7_srai                 = func7_0100000;
wire func7_srl                  = func7_0000000;
wire func7_srli                 = func7_0000000;
wire func7_add                  = func7_0000000;
wire func7_sub                  = func7_0100000;


//-----------------------------------rv32I-instr-----------------------------------
//U_TYPE
wire rv32I_U_lui    			= (opcode_U_lui);
wire rv32I_U_auipc  			= (opcode_U_auipc);

//I_TYPE
wire rv32I_I_addi  				= (rv32I_I_Logic_Operator & func3_I_addi                    );
wire rv32I_I_slli  				= (rv32I_I_Logic_Operator & func3_I_slli                    );
wire rv32I_I_slti 				= (rv32I_I_Logic_Operator & func3_I_slti                    );
wire rv32I_I_sltiu 				= (rv32I_I_Logic_Operator & func3_I_sltiu                   ); 
wire rv32I_I_xori  				= (rv32I_I_Logic_Operator & func3_I_xori                    );
wire rv32I_I_srli  				= (rv32I_I_Logic_Operator & func3_I_srli_srai & func7_srli  );
wire rv32I_I_srai  				= (rv32I_I_Logic_Operator & func3_I_srli_srai & func7_srai  ); 
wire rv32I_I_ori   				= (rv32I_I_Logic_Operator & func3_I_ori                     );
wire rv32I_I_andi  				= (rv32I_I_Logic_Operator & func3_I_andi                    );

wire rv32I_I_lb    				= (rv32I_I_LOAD & func3_I_lb);
wire rv32I_I_lh    				= (rv32I_I_LOAD & func3_I_lh);
wire rv32I_I_lw    				= (rv32I_I_LOAD & func3_I_lw);
wire rv32I_I_lbu   				= (rv32I_I_LOAD & func3_I_lbu);
wire rv32I_I_lhu   				= (rv32I_I_LOAD & func3_I_lhu);

wire rv32I_I_jalr  				= (rv32I_I_JALR);

//wire rv32I_ecall	    		= (rv32I_instr == 32'h00000073);
//wire rv32I_mret  	    		= (rv32I_instr == 32'h30200073);
//wire rv32I_I_csrrw 			= (rv32I_I_TYPE & func3_I_csrrw); //I型指令
//wire rv32I_I_csrrs 			= (rv32I_I_TYPE & func3_I_csrrw); //I型指令


//R_TYPE
wire rv32I_R_add    			= (rv32I_R_TYPE & func3_R_add_sub & func7_add   );
wire rv32I_R_sub    			= (rv32I_R_TYPE & func3_R_add_sub & func7_sub   ); 
wire rv32I_R_sll    			= (rv32I_R_TYPE & func3_R_sll 	                );
wire rv32I_R_slt    			= (rv32I_R_TYPE & func3_R_slt 		            );
wire rv32I_R_sltu   			= (rv32I_R_TYPE & func3_R_sltu 	                );
wire rv32I_R_xor    			= (rv32I_R_TYPE & func3_R_xor 	 		        );
wire rv32I_R_srl    			= (rv32I_R_TYPE & func3_R_srl_sra & func7_srl   );
wire rv32I_R_sra    			= (rv32I_R_TYPE & func3_R_srl_sra & func7_sra   ); 
wire rv32I_R_or     			= (rv32I_R_TYPE & func3_R_or		            );
wire rv32I_R_and    			= (rv32I_R_TYPE & func3_R_and 	 	            );

//B_TYPE
wire rv32I_B_beq   				= (rv32I_B_TYPE & func3_B_beq);
wire rv32I_B_bne   				= (rv32I_B_TYPE & func3_B_bne);
wire rv32I_B_blt   				= (rv32I_B_TYPE & func3_B_blt);
wire rv32I_B_bge  				= (rv32I_B_TYPE & func3_B_bge);
wire rv32I_B_bltu  				= (rv32I_B_TYPE & func3_B_bltu);
wire rv32I_B_bgeu  				= (rv32I_B_TYPE & func3_B_bgeu);
//S_TYPE
wire rv32I_S_sb    				= (rv32I_S_TYPE & func3_S_sb);
wire rv32I_S_sh    				= (rv32I_S_TYPE & func3_S_sh);
wire rv32I_S_sw    				= (rv32I_S_TYPE & func3_S_sw);
//J_TYPE
wire rv32I_J_jal   				= (rv32I_J_TYPE);

//--------------------------------------imm--------------------------------
wire [31:0] imm_U_TYPE 			=  { rv32I_instr[31:12] , 12'd0};
wire [31:0] imm_I_TYPE 			=  { {20{rv32I_instr[31]}}, rv32I_instr[31:20]} ;
wire [31:0] imm_I_SHAMT 		=  { 27'd0,rv32I_instr[24:20]};
wire [31:0] imm_S_TYPE 			=  { {20{rv32I_instr[31]}}, rv32I_instr[31:25], rv32I_instr[11:7]} ;
wire [31:0] imm_R_TYPE			=  	 32'd0;
wire [31:0] imm_B_TYPE 			=  {{{{20{rv32I_instr[31]}},  rv32I_instr[31], rv32I_instr[7], rv32I_instr[30:25],  rv32I_instr[11:8] }  << 1'b1}};
wire [31:0] imm_J_TYPE 			=  {{{ 12{rv32I_instr[31]}},  rv32I_instr[31], rv32I_instr[19:12], rv32I_instr[20], rv32I_instr[30:21]}  << 1'b1 };
//-------------------------------------------------decode框架---end-----------------------------------------------------

wire opcode_I_Logic_Operator 	= (rv32I_opcode == 7'b0010011);
wire opcode_I_LOAD  			= (rv32I_opcode == 7'b0000011);
wire opcode_I_CSR   			= (rv32I_opcode == 7'b1110011);
wire opcode_I_JALR  			= (rv32I_opcode == 7'b1100111);
wire opcode_I_TYPE  			=  opcode_I_Logic_Operator | opcode_I_LOAD | opcode_I_CSR | opcode_I_JALR;
wire opcode_R_TYPE  			= (rv32I_opcode == 7'b0110011);
wire opcode_B_TYPE  			= (rv32I_opcode == 7'b1100011);
wire opcode_S_TYPE  			= (rv32I_opcode == 7'b0100011);
wire opcode_J_TYPE  			= (rv32I_opcode == 7'b1101111);
wire opcode_U_TYPE				= (rv32I_U_lui | rv32I_U_auipc);




//------------------------------译码阶段和寄存器文件有关的信号------------------------------
//通过rs1和rs1在寄存器文件中取出的valA, valB,
//auipc的valA是pc，lui的valA是0

//execute阶段
//valA,valB,imm,alu_valA_sel, alu_valB_sel, alu_func
wire [31:0] regfile_o_valA;
wire [31:0] regfile_o_valB;
regfile u_regfile(
	.clk(clk),
	.rst(rst),
    .write_back_i_wb_reg_wen 	(write_back_i_wb_reg_wen  	),
    .write_back_i_wb_rd      	(write_back_i_wb_rd       	),
    .write_back_i_wb_valD    	(write_back_i_wb_valD     	),
    .decode_i_rs1            	(rv32I_rs1             	  	),
    .decode_i_rs2            	(rv32I_rs2            	 	),
    .regfile_o_valA          	(regfile_o_valA           	),
    .regfile_o_valB          	(regfile_o_valB           	)
);
//U_TYPE不需要rs1和rs2
//j不需要rs1和rs2


// lw x1,0,x0 //R[x1] = mem[R[x0] + 0] 
// sw 

//Itype需要rs1，不需要rs2
assign decode_o_rs1 = (opcode_U_TYPE | opcode_J_TYPE) ? 5'd0 :
   					  (opcode_I_TYPE | opcode_B_TYPE | opcode_S_TYPE | opcode_R_TYPE) ? rv32I_rs1  : 5'd0;

assign decode_o_rs2 = (opcode_I_TYPE | opcode_U_TYPE | opcode_J_TYPE) ? 5'd0:
					  (opcode_B_TYPE | opcode_S_TYPE | opcode_R_TYPE) ? rv32I_rs2 : 5'd0;


assign 	decode_o_valA =  (decode_o_rs1  == regE_i_wb_rd && regE_i_wb_rd != 5'd0 &&  regE_i_wb_reg_wen) ? execute_i_valE : 
						 (decode_o_rs1  == regM_i_wb_rd && regM_i_wb_rd != 5'd0 &&  regM_i_wb_reg_wen && regM_i_wb_valD_sel == `wb_valD_sel_valM) ? memory_i_valM 		: 
						 (decode_o_rs1  == regM_i_wb_rd && regM_i_wb_rd != 5'd0 &&  regM_i_wb_reg_wen && regM_i_wb_valD_sel == `wb_valD_sel_valE) ? regM_i_valE 		: 
						 (decode_o_rs1  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 &&  regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valE) ? regW_i_valE  		: 
						 (decode_o_rs1  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 &&  regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valM) ? regW_i_valM  		: 
						 (decode_o_rs1  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 &&  regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valP) ? regW_i_pc + 32'd4   : regfile_o_valA; 


assign  decode_o_valB =  (decode_o_rs2  == regE_i_wb_rd && regE_i_wb_rd != 5'd0 && regE_i_wb_reg_wen) ? execute_i_valE : 
						 (decode_o_rs2  == regM_i_wb_rd && regM_i_wb_rd != 5'd0 && regM_i_wb_reg_wen && regM_i_wb_valD_sel == `wb_valD_sel_valM) ? memory_i_valM : 
						 (decode_o_rs2  == regM_i_wb_rd && regM_i_wb_rd != 5'd0 && regM_i_wb_reg_wen && regM_i_wb_valD_sel == `wb_valD_sel_valE) ? regM_i_valE  :
						 (decode_o_rs2  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 && regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valE) ? regW_i_valE  : 
						 (decode_o_rs2  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 && regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valM) ? regW_i_valM  : 
						 (decode_o_rs2  == regW_i_wb_rd && regW_i_wb_rd != 5'd0 &&  regW_i_wb_reg_wen && regW_i_wb_valD_sel == `wb_valD_sel_valP) ? regW_i_pc + 32'd4   : regfile_o_valB; 



assign decode_o_imm     		= 	(rv32I_R_TYPE) ? imm_R_TYPE	:
									(rv32I_U_TYPE) ? imm_U_TYPE	: 
 						 		  	(rv32I_I_TYPE) ? (rv32I_I_slli | rv32I_I_srli | rv32I_I_srai) ?   imm_I_SHAMT : imm_I_TYPE :
                         		  	(rv32I_S_TYPE) ? imm_S_TYPE	: 
	 					  			(rv32I_B_TYPE) ? imm_B_TYPE	:
						  			(rv32I_J_TYPE) ? imm_J_TYPE	:  32'd0;


assign  decode_o_alu_valA_sel   =   (rv32I_I_TYPE | rv32I_R_TYPE  | rv32I_S_TYPE ) ?  `alu_valA_sel_valA  : 
					  	            (rv32I_J_TYPE | rv32I_B_TYPE  | rv32I_U_auipc) ?  `alu_valA_sel_pc    : 
                                    (rv32I_U_lui)                                  ?  `alu_valA_sel_zero  : `alu_valA_sel_zero;              
assign  decode_o_alu_valB_sel   =   (rv32I_R_TYPE) ? `alu_valB_sel_valB:
				  		    	    (rv32I_I_TYPE | rv32I_S_TYPE | rv32I_B_TYPE | rv32I_U_TYPE | rv32I_J_TYPE) ? `alu_valB_sel_imm : `alu_valB_sel_valB;

assign  decode_o_alu_func_sel   = 	(rv32I_R_add  | rv32I_I_addi  )  ? `alu_func_add:
								    (rv32I_R_sub               	  )  ? `alu_func_sub:
								    (rv32I_R_sll  | rv32I_I_slli  )  ? `alu_func_sll:
								    (rv32I_R_slt  | rv32I_I_slti  )  ? `alu_func_slt:
							 	    (rv32I_R_sltu | rv32I_I_sltiu )  ? `alu_func_sltu:
								    (rv32I_R_xor  | rv32I_I_xori  )  ? `alu_func_xor:
									(rv32I_R_srl  | rv32I_I_srli  )  ? `alu_func_srl:
							   		(rv32I_R_sra  | rv32I_I_srai  )  ? `alu_func_sra:
								    (rv32I_R_or   | rv32I_I_ori   )  ? `alu_func_or  :
							    	(rv32I_R_and  | rv32I_I_andi  )  ? `alu_func_and : `alu_func_add;
//memory阶段
//确定一个指令是否需要读写内存
assign decode_o_mem_rw =    		(rv32I_instr == 32'h0000a023) ? `mem_no_rw : 
									(rv32I_I_lb) ? `mem_rw_lb  :
						    		(rv32I_I_lbu)? `mem_rw_lbu :
						    		(rv32I_I_lh) ? `mem_rw_lh  :
						    		(rv32I_I_lhu)? `mem_rw_lhu :
						   			(rv32I_I_lw) ? `mem_rw_lw  :
						    		(rv32I_S_sb) ? `mem_rw_sb  :
						    		(rv32I_S_sh) ? `mem_rw_sh  :
						    		(rv32I_S_sw) ? `mem_rw_sw  : `mem_no_rw;

//write_back阶段
//write_back阶段需要知道一个指令是否需要写寄存器即decode_o_reg_wen
//需要知道写哪个寄存器rd, 
//需要知道写的数据，数据到最后面才会出来
//
assign  decode_o_wb_reg_wen 	= 	(rv32I_I_TYPE | rv32I_R_TYPE | rv32I_U_TYPE | rv32I_J_TYPE) ? `reg_wen_w : `reg_wen_no_w;
assign 	decode_o_wb_rd   		= 	rv32I_rd;
assign  decode_o_wb_valD_sel 	=   (rv32I_R_TYPE | rv32I_I_Logic_Operator | rv32I_U_TYPE)   	? `wb_valD_sel_valE :
		    					 	(rv32I_I_LOAD)                  						    ? `wb_valD_sel_valM :
									(rv32I_I_jalr   | rv32I_J_TYPE)               			    ? `wb_valD_sel_valP : `wb_valD_sel_valM;


assign decode_o_need_jump = (rv32I_B_beq && ($signed(decode_o_valA) == $signed(decode_o_valB)))  ? 1'b1:
							(rv32I_B_bne && ($signed(decode_o_valA) != $signed(decode_o_valB)))  ? 1'b1:
							(rv32I_B_blt && ($signed(decode_o_valA) < $signed( decode_o_valB)))  ? 1'b1:
							(rv32I_B_bge && ($signed(decode_o_valA) >= $signed(decode_o_valB)))  ? 1'b1:
							(rv32I_B_bltu && ($unsigned(decode_o_valA) < $unsigned(decode_o_valB)))  ? 1'b1:
							(rv32I_B_bgeu && ($unsigned(decode_o_valA) >= $unsigned(decode_o_valB))) ? 1'b1:
							(rv32I_J_jal | rv32I_I_jalr) ? 1'b1 : 1'b0;
assign decode_o_is_jalr = rv32I_I_jalr;				

endmodule

	// assign decode_o_wb_sel  	=
	// assign decode_o_br_un  		=   (rv32I_B_bltu | rv32I_B_bgeu) 			? 1'b1 : 1'b0;
	// assign decode_o_pc_sel 		=	(rv32I_B_beq  &  BR_JMP_i_br_eq)   		? `pc_sel_valE :
	// 							  	(rv32I_B_bne  & (~BR_JMP_i_br_eq)) 		? `pc_sel_valE :
	// 							  	(rv32I_B_blt  &  BR_JMP_i_br_lt)   		? `pc_sel_valE :
	// 							  	(rv32I_B_bge  & (~BR_JMP_i_br_lt)) 		? `pc_sel_valE :
	// 							  	(rv32I_B_bltu &   BR_JMP_i_br_lt ) 		? `pc_sel_valE :
	// 							  	(rv32I_B_bgeu & (~BR_JMP_i_br_lt))  	? `pc_sel_valE :
	// 							  	(rv32I_jal 	  | rv32I_jalr)         	? `pc_sel_valE : 
	// 						  	  	(rv32I_ecall  | rv32I_mret)   	    	? `pc_sel_CSR_valP : `pc_sel_valP;


