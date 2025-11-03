`include "define.v"
module memory(
	input wire clk,
	input wire rst,
	input wire  [31:0]	regM_i_valE,
	input wire  [31:0]	regM_i_valB,
	input wire  [3:0]	regM_i_mem_rw,
	output wire [31:0]	memory_o_valM
);

import "DPI-C" function void dpi_mem_write(input int addr, input int data, int len);
import "DPI-C" function int  dpi_mem_read (input int addr  , input int len);

wire mem_no_rw    	= (regM_i_mem_rw == `mem_no_rw);
wire rv32_lb  		= (regM_i_mem_rw == `mem_rw_lb);
wire rv32_lh  		= (regM_i_mem_rw == `mem_rw_lh);
wire rv32_lw  		= (regM_i_mem_rw == `mem_rw_lw);
wire rv32_lbu 		= (regM_i_mem_rw == `mem_rw_lbu);
wire rv32_lhu 		= (regM_i_mem_rw == `mem_rw_lhu);
wire rv32_load 		= rv32_lb | rv32_lh | rv32_lw | rv32_lbu | rv32_lhu;



reg [31:0] MEM_o_TMP;
assign memory_o_valM  = (rv32_lb) ? {{24{MEM_o_TMP[7] }}, MEM_o_TMP[7:0]} 	:
                    	(rv32_lh) ? {{16{MEM_o_TMP[15]}}, MEM_o_TMP[15:0]}	:
						(rv32_lw) ? MEM_o_TMP 							 	: 
						(rv32_lbu)? {24'd0 , MEM_o_TMP[7:0]} 			  	:
						(rv32_lhu)? {16'd0, MEM_o_TMP[15:0]} 				: MEM_o_TMP;
always @(*) begin
	if(mem_no_rw) begin
		MEM_o_TMP = 32'd0;
	end
	else if(rv32_load)  begin
		MEM_o_TMP = dpi_mem_read(regM_i_valE, 4);
	end
	else begin
		MEM_o_TMP = 32'd0;
	end
end

//S型指令
wire rv32_sb  = (regM_i_mem_rw == `mem_rw_sb);
wire rv32_sh  = (regM_i_mem_rw == `mem_rw_sh);
wire rv32_sw  = (regM_i_mem_rw == `mem_rw_sw);
wire [31	:0] data = regM_i_valB;
wire [31: 0] addr = regM_i_valE;

always @(posedge clk) begin
	if(rv32_sb) begin
		dpi_mem_write(addr, data, 1);
	end
	else if(rv32_sh) begin
		dpi_mem_write(addr, data, 2);		
	end
	else if(rv32_sw) begin
		dpi_mem_write(addr, data, 4);				
	end
end
endmodule //moduleName

