`include "define.v"
module regD(
	input wire         					clk,
	input wire               			rst,
	input  wire             	ctrl_i_regD_bubble,
	input  wire 				ctrl_i_regD_stall,
	input wire 		[31:0]		fetch_i_instr,
	input wire 		[31:0]		regF_i_pc,
	input wire      [31:0]		fetch_i_pre_pc,
	input wire 					fetch_i_commit,

	output reg 		[31:0]		regD_o_instr,
	output reg 		[31:0]		regD_o_pc,
	output reg  	[31:0]		regD_o_pre_pc,
	output reg 					regD_o_commit
);


always @(posedge clk) begin
	if(rst || ctrl_i_regD_bubble) begin
		regD_o_instr  <= `nop_instr;
		regD_o_commit <= `nop_commit;
		regD_o_pc     <= `nop_pc;
		regD_o_pre_pc <= `nop_pre_pc;
	end
	else if(~ctrl_i_regD_stall) begin
		regD_o_instr  <= fetch_i_instr;
		regD_o_commit <= fetch_i_commit;
		regD_o_pc     <= regF_i_pc;
		regD_o_pre_pc <= fetch_i_pre_pc;
	end
end
endmodule