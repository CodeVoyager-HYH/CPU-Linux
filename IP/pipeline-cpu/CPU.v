module CPU(
    input wire clk,
    input wire rst,

    output wire [31:0]          cur_pc,
    output                      commit,
    output wire [31:0]          commit_pc,
    output wire [31:0]          commit_pre_pc
);
// output declaration of module select_pc
wire [31:0] select_pc_o_pc;

select_pc u_select_pc(
    .fetch_i_pre_pc      	(fetch_o_pre_pc       ),    
    .execute_i_valE      	(execute_o_valE       ),
    .execute_i_need_jump 	(execute_o_need_jump  ),
    .select_pc_o_pc      	(select_pc_o_pc       )
);




// output declaration of module regF
// output declaration of module regF
reg [31:0] regF_o_pc;

regF u_regF(
    .clk               	(clk                ),
    .rst               	(rst                ),
    .ctrl_i_regF_stall 	(ctrl_o_regF_stall  ),
    .select_pc_o_pc    	(select_pc_o_pc     ),
    .regF_o_pc         	(regF_o_pc          )
);

// output declaration of module fetch
wire [31:0] fetch_o_pre_pc;
wire [31:0] fetch_o_instr;
wire fetch_o_commit;

fetch u_fetch(
    .regF_i_pc      	(regF_o_pc       ),
    .fetch_o_pre_pc 	(fetch_o_pre_pc  ),
    .fetch_o_instr  	(fetch_o_instr   ),
    .fetch_o_commit 	(fetch_o_commit  )
);

// output declaration of module regD
wire [31:0] regD_o_pc;
wire [31:0] regD_o_pre_pc;
wire        regD_o_commit;
wire [31:0] regD_o_instr;

regD u_regD(
    .clk            	(clk             ),
    .rst            	(rst             ),
    .ctrl_i_regD_bubble(ctrl_o_regD_bubble),
    .ctrl_i_regD_stall  (ctrl_o_regD_stall),
    .regF_i_pc      	(regF_o_pc       ),
    .fetch_i_instr      (fetch_o_instr),
    .fetch_i_pre_pc 	(fetch_o_pre_pc  ),
    .fetch_i_commit 	(fetch_o_commit  ),
    .regD_o_pc      	(regD_o_pc       ),
    .regD_o_pre_pc  	(regD_o_pre_pc   ),
    .regD_o_commit  	(regD_o_commit   ),
    .regD_o_instr       (regD_o_instr)
);


// output declaration of module decode
wire [31:0] decode_o_valA;
wire [31:0] decode_o_valB;
wire [31:0] decode_o_imm;
wire [1:0] decode_o_alu_valA_sel;
wire [1:0] decode_o_alu_valB_sel;
wire [3:0] decode_o_alu_func_sel;
wire [3:0] decode_o_mem_rw;
wire decode_o_wb_reg_wen;
wire [4:0] decode_o_wb_rd;
wire [1:0] decode_o_wb_valD_sel;
wire decode_o_need_jump;
wire [4:0]  decode_o_rs1;
wire [4:0]  decode_o_rs2;

wire decode_o_is_jalr;
decode u_decode(
    .clk                     	(clk                      ),
    .rst                     	(rst                      ),
    .regD_i_instr            	(regD_o_instr             ),
    .regE_i_wb_reg_wen          (regE_o_wb_reg_wen),
	.regE_i_wb_rd               (regE_o_wb_rd),
	.execute_i_valE             (execute_o_valE),
	.regW_i_valE(regW_o_valE),
	.regW_i_valM(regW_o_valM),
	.regW_i_wb_valD_sel(regW_o_wb_valD_sel),
	.regW_i_wb_rd(regW_o_wb_rd),
	.regW_i_wb_reg_wen(regW_o_wb_reg_wen),
    .regW_i_pc  (regW_o_pc),
	//访存阶段数据前递
	.regM_i_valE(regM_o_valE),
	.memory_i_valM(memory_o_valM),
	.regM_i_wb_valD_sel(regM_o_wb_valD_sel),
	.regM_i_wb_rd(regM_o_wb_rd),
	.regM_i_wb_reg_wen(regM_o_wb_reg_wen),

    .write_back_i_wb_reg_wen 	(write_back_o_wb_reg_wen  ),
    .write_back_i_wb_rd      	(write_back_o_wb_rd       ),
    .write_back_i_wb_valD    	(write_back_o_wb_valD     ),
    .decode_o_valA           	(decode_o_valA            ),
    .decode_o_valB           	(decode_o_valB            ),
    .decode_o_imm            	(decode_o_imm             ),
    .decode_o_alu_valA_sel   	(decode_o_alu_valA_sel    ),
    .decode_o_alu_valB_sel   	(decode_o_alu_valB_sel    ),
    .decode_o_alu_func_sel   	(decode_o_alu_func_sel    ),
    .decode_o_mem_rw         	(decode_o_mem_rw          ),
    .decode_o_wb_reg_wen     	(decode_o_wb_reg_wen      ),
    .decode_o_wb_rd          	(decode_o_wb_rd           ),
    .decode_o_wb_valD_sel    	(decode_o_wb_valD_sel     ),
    .decode_o_need_jump      	(decode_o_need_jump       ),
    .decode_o_is_jalr           (decode_o_is_jalr),
    .decode_o_rs1       (decode_o_rs1),
    .decode_o_rs2( decode_o_rs2)
);

// output declaration of module regE
wire [31:0] regE_o_valA;
wire [31:0] regE_o_valB;
wire [31:0] regE_o_imm;
wire [1:0] regE_o_alu_valA_sel;
wire [1:0] regE_o_alu_valB_sel;
wire [3:0] regE_o_alu_func_sel;
wire [3:0] regE_o_mem_rw;
wire regE_o_wb_reg_wen;
wire [4:0] regE_o_wb_rd;
wire [1:0] regE_o_wb_valD_sel;
wire regE_o_need_jump;
wire [31:0] regE_o_pc;
wire regE_o_commit;
wire [31:0] regE_o_instr;
wire [31:0] regE_o_pre_pc;
wire        regE_o_is_jalr;
regE u_regE(
    .clk                   	(clk                    ),
    .rst                   	(rst                    ),
    .ctrl_i_regE_bubble    	(ctrl_o_regE_bubble     ),
    .decode_i_valA         	(decode_o_valA          ),
    .decode_i_valB         	(decode_o_valB          ),
    .decode_i_imm          	(decode_o_imm           ),
    .decode_i_alu_valA_sel 	(decode_o_alu_valA_sel  ),
    .decode_i_alu_valB_sel 	(decode_o_alu_valB_sel  ),
    .decode_i_is_jalr       (decode_o_is_jalr),
    .decode_i_alu_func_sel 	(decode_o_alu_func_sel  ),
    .decode_i_mem_rw       	(decode_o_mem_rw        ),
    .decode_i_wb_reg_wen   	(decode_o_wb_reg_wen    ),
    .decode_i_wb_rd        	(decode_o_wb_rd         ),
    .decode_i_wb_valD_sel  	(decode_o_wb_valD_sel   ),
    .decode_i_need_jump    	(decode_o_need_jump     ),
    .regD_i_instr          	(regD_o_instr           ),
    .regD_i_pc             	(regD_o_pc              ),
    .regD_i_commit         	(regD_o_commit          ),
    .regD_i_pre_pc         	(regD_o_pre_pc          ),
    .regE_o_valA           	(regE_o_valA            ),
    .regE_o_valB           	(regE_o_valB            ),
    .regE_o_imm            	(regE_o_imm             ),
    .regE_o_alu_valA_sel   	(regE_o_alu_valA_sel    ),
    .regE_o_alu_valB_sel   	(regE_o_alu_valB_sel    ),
    .regE_o_alu_func_sel   	(regE_o_alu_func_sel    ),
    .regE_o_is_jalr         (regE_o_is_jalr),
    .regE_o_mem_rw         	(regE_o_mem_rw          ),
    .regE_o_wb_reg_wen     	(regE_o_wb_reg_wen      ),
    .regE_o_wb_rd          	(regE_o_wb_rd           ),
    .regE_o_wb_valD_sel    	(regE_o_wb_valD_sel     ),
    .regE_o_need_jump      	(regE_o_need_jump       ),
    .regE_o_pc             	(regE_o_pc              ),
    .regE_o_commit         	(regE_o_commit          ),
    .regE_o_instr          	(regE_o_instr           ),
    .regE_o_pre_pc         	(regE_o_pre_pc          )
);


// output declaration of module execute
wire [31:0] execute_o_pre_pc;
wire [31:0] execute_o_valE;
wire execute_o_need_jump;
wire execute_o_is_jalr;

execute u_execute(
    .regE_i_valA         	(regE_o_valA          ),
    .regE_i_valB         	(regE_o_valB          ),
    .regE_i_imm          	(regE_o_imm           ),
    .regE_i_pc           	(regE_o_pc            ),
    .regE_i_alu_valA_sel 	(regE_o_alu_valA_sel  ),
    .regE_i_alu_valB_sel 	(regE_o_alu_valB_sel  ),
    .regE_i_alu_func_sel 	(regE_o_alu_func_sel  ),
    .regE_i_need_jump    	(regE_o_need_jump     ),
    .regE_i_is_jalr         (regE_o_is_jalr),
    .regE_i_pre_pc       	(regE_o_pre_pc        ),
    .execute_o_pre_pc    	(execute_o_pre_pc     ),
    .execute_o_valE      	(execute_o_valE       ),
    .execute_o_need_jump 	(execute_o_need_jump  )
);

// output declaration of module regM
wire [31:0] regM_o_valE;
wire [3:0] regM_o_mem_rw;
wire regM_o_wb_reg_wen;
wire [4:0] regM_o_wb_rd;
wire [1:0] regM_o_wb_valD_sel;
wire [31:0] regM_o_instr;
wire [31:0] regM_o_pc;
wire regM_o_commit;
wire [31:0] regM_o_pre_pc;
wire [31:0] regM_o_valB;
regM u_regM(
    .clk                	(clk                 ),
    .rst                	(rst                 ),
    .execute_i_valE     	(execute_o_valE      ),
    .execute_i_pre_pc   	(execute_o_pre_pc    ),
    .regE_i_mem_rw      	(regE_o_mem_rw       ),
    .regE_i_wb_reg_wen  	(regE_o_wb_reg_wen   ),
    .regE_i_wb_rd       	(regE_o_wb_rd        ),
    .regE_i_wb_valD_sel 	(regE_o_wb_valD_sel  ),
    .regE_i_instr       	(regE_o_instr        ),
    .regE_i_pc          	(regE_o_pc           ),
    .regE_i_commit      	(regE_o_commit       ),
    .regE_i_valB            (regE_o_valB),
    .regM_o_valE        	(regM_o_valE         ),
    .regM_o_mem_rw      	(regM_o_mem_rw       ),
    .regM_o_valB            (regM_o_valB),
    .regM_o_wb_reg_wen  	(regM_o_wb_reg_wen   ),
    .regM_o_wb_rd       	(regM_o_wb_rd        ),
    .regM_o_wb_valD_sel 	(regM_o_wb_valD_sel  ),
    .regM_o_instr       	(regM_o_instr        ),
    .regM_o_pc          	(regM_o_pc           ),
    .regM_o_commit      	(regM_o_commit       ),
    .regM_o_pre_pc      	(regM_o_pre_pc       )
);

// output declaration of module memory
wire [31:0] memory_o_valM;
memory u_memory(
    .rst(rst),
    .clk(clk),
    .regM_i_valE   	(regM_o_valE    ),
    .regM_i_valB     (regM_o_valB),
    .regM_i_mem_rw 	(regM_o_mem_rw  ),
    .memory_o_valM 	(memory_o_valM  )
);


// output declaration of module regW
wire regW_o_wb_reg_wen;
wire [4:0] regW_o_wb_rd;
wire [1:0] regW_o_wb_valD_sel;
wire [31:0] regW_o_valE;
wire [31:0] regW_o_pc;
wire [31:0] regW_o_instr;
wire regW_o_commit;
wire [31:0] regW_o_pre_pc;
wire [31:0] regW_o_valM;
regW u_regW(
    .clk                	(clk                 ),
    .rst                	(rst                 ),
    .regM_i_wb_reg_wen  	(regM_o_wb_reg_wen   ),
    .regM_i_wb_rd       	(regM_o_wb_rd        ),
    .regM_i_wb_valD_sel 	(regM_o_wb_valD_sel  ),
    .regM_i_valE        	(regM_o_valE         ),
    .regM_i_pc          	(regM_o_pc           ),
    .regM_i_instr       	(regM_o_instr        ),
    .regM_i_commit      	(regM_o_commit       ),
    .regM_i_pre_pc      	(regM_o_pre_pc       ),
    .memory_i_valM          (memory_o_valM),
    .regW_o_wb_reg_wen  	(regW_o_wb_reg_wen   ),
    .regW_o_wb_rd       	(regW_o_wb_rd        ),
    .regW_o_wb_valD_sel 	(regW_o_wb_valD_sel  ),
    .regW_o_valE        	(regW_o_valE         ),
    .regW_o_valM            (regW_o_valM),
    .regW_o_pc          	(regW_o_pc           ),
    .regW_o_instr       	(regW_o_instr        ),
    .regW_o_commit      	(regW_o_commit       ),
    .regW_o_pre_pc      	(regW_o_pre_pc       )
);
// output declaration of module write_back
wire write_back_o_wb_reg_wen;
wire [4:0] write_back_o_wb_rd;
wire [31:0] write_back_o_wb_valD;

write_back u_write_back(
    .regW_i_wb_reg_wen       	(regW_o_wb_reg_wen        ),
    .regW_i_wb_rd            	(regW_o_wb_rd             ),
    .regW_i_pc                  (regW_o_pc),
    .regW_i_wb_valD_sel      	(regW_o_wb_valD_sel       ),
    .regW_i_valM                (regW_o_valM),
    .regW_i_valE             	(regW_o_valE              ),
    .regW_i_instr               (regW_o_instr),
    .write_back_o_wb_reg_wen 	(write_back_o_wb_reg_wen  ),
    .write_back_o_wb_rd      	(write_back_o_wb_rd       ),
    .write_back_o_wb_valD    	(write_back_o_wb_valD     )
);

assign cur_pc = regF_o_pc;
assign commit = regW_o_commit;
assign commit_pc = regW_o_pc;
assign commit_pre_pc=regW_o_pre_pc;



// output declaration of module ctrl
wire ctrl_o_regF_stall;
wire ctrl_o_regD_stall;
wire ctrl_o_regE_stall;
wire ctrl_o_regM_stall;
wire ctrl_o_regW_stall;
wire ctrl_o_regF_bubble;
wire ctrl_o_regD_bubble;
wire ctrl_o_regE_bubble;
wire ctrl_o_regM_bubble;
wire ctrl_o_regW_bubble;

ctrl u_ctrl(
    .execute_i_need_jump 	(execute_o_need_jump  ),
    .decode_i_rs1        	(decode_o_rs1         ),
    .decode_i_rs2        	(decode_o_rs2         ),
    .regE_i_rd           	(regE_o_wb_rd            ),
    .regE_i_mem_rw       	(regE_o_mem_rw        ),
    .ctrl_o_regF_stall   	(ctrl_o_regF_stall    ),
    .ctrl_o_regD_stall   	(ctrl_o_regD_stall    ),
    .ctrl_o_regE_stall   	(ctrl_o_regE_stall    ),
    .ctrl_o_regM_stall   	(ctrl_o_regM_stall    ),
    .ctrl_o_regW_stall   	(ctrl_o_regW_stall    ),
    .ctrl_o_regF_bubble  	(ctrl_o_regF_bubble   ),
    .ctrl_o_regD_bubble  	(ctrl_o_regD_bubble   ),
    .ctrl_o_regE_bubble  	(ctrl_o_regE_bubble   ),
    .ctrl_o_regM_bubble  	(ctrl_o_regM_bubble   ),
    .ctrl_o_regW_bubble  	(ctrl_o_regW_bubble   )
);

CSR u_CSR(
	.clk(clk),
    .rst(rst)
);
endmodule
