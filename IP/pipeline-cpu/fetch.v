module fetch(
	input wire  [31:0] regF_i_pc,

//	output wire [31:0] fetch_o_valP,
	output wire [31:0] fetch_o_pre_pc,
	output wire [31:0] fetch_o_instr,
	output wire  	   fetch_o_commit
);
import "DPI-C" function int  dpi_mem_read 	(input int addr  , input int len);

//assign fetch_o_valP   = regF_i_pc + 32'd4; //valP永远为pc+4
assign fetch_o_pre_pc = regF_i_pc + 32'd4; //分支预测
assign fetch_o_instr  = dpi_mem_read(regF_i_pc, 4);
assign fetch_o_commit = 1;
endmodule