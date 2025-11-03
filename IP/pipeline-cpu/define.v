`define alu_valA_sel_valA   2'd0
`define alu_valA_sel_pc     2'd1
`define alu_valA_sel_zero   2'd2

`define alu_valB_sel_valB   2'd0
`define alu_valB_sel_imm    2'd1
`define alu_valB_sel_zero   2'd2

`define alu_func_add        4'd0
`define alu_func_sub        4'd1
`define alu_func_sll        4'd2
`define alu_func_slt        4'd3
`define alu_func_sltu       4'd4
`define alu_func_xor        4'd5
`define alu_func_srl        4'd6
`define alu_func_sra        4'd7
`define alu_func_or         4'd8
`define alu_func_and        4'd9
`define alu_func_jalr       4'd10

`define mem_rw_lb		    4'd0      
`define mem_rw_lbu		    4'd1
`define mem_rw_lh		    4'd2
`define mem_rw_lhu		    4'd3
`define mem_rw_lw		    4'd4
`define mem_rw_sb		    4'd5
`define mem_rw_sh		    4'd6
`define mem_rw_sw		    4'd7
`define mem_no_rw		    4'd8

`define reg_wen_w           1'd1
`define reg_wen_no_w	    1'd0

`define wb_valD_sel_valE    2'd0
`define wb_valD_sel_valM    2'd1
`define wb_valD_sel_valP    2'd2


//最开始的nop指令
`define nop_instr 32'h00000013
`define nop_commit 1'b0
`define nop_pc    32'd0
`define nop_pre_pc 32'd0