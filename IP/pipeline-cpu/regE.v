`include "define.v"
module regE(
    input  wire clk,
    input  wire rst,
    input  wire             ctrl_i_regE_bubble,
    input  wire [31:0]      decode_i_valA,
    input  wire [31:0]      decode_i_valB,
    input  wire [31:0]      decode_i_imm,
    input  wire [1:0]       decode_i_alu_valA_sel,
    input  wire [1:0]       decode_i_alu_valB_sel,
    input  wire [3:0]       decode_i_alu_func_sel,
    input  wire [3:0]       decode_i_mem_rw,
    input  wire             decode_i_wb_reg_wen,
    input  wire [4:0]       decode_i_wb_rd,
    input  wire [1:0]       decode_i_wb_valD_sel,
    input  wire             decode_i_need_jump,
    input  wire             decode_i_is_jalr,
    

    //commit
    input  wire [31:0]      regD_i_instr,
    input  wire [31:0]      regD_i_pc,
    input  wire             regD_i_commit,
    input  wire [31:0]      regD_i_pre_pc,

    //execute
    output reg [31:0]       regE_o_valA,
    output reg [31:0]       regE_o_valB,
    output reg [31:0]       regE_o_imm,
	output reg [1:0]        regE_o_alu_valA_sel,
	output reg [1:0]        regE_o_alu_valB_sel,
	output reg [3:0]        regE_o_alu_func_sel,
	//memory
	output reg [3:0]        regE_o_mem_rw,
	//write_back
    output reg              regE_o_wb_reg_wen,
	output reg [4:0]        regE_o_wb_rd,
	output reg [1:0]        regE_o_wb_valD_sel,
    output reg              regE_o_need_jump,
    //commit
    output reg    [31:0]    regE_o_pc,
    output reg              regE_o_commit,
    output reg    [31:0]    regE_o_instr,
    output reg    [31:0]    regE_o_pre_pc,
    output reg              regE_o_is_jalr
);
always @(posedge clk) begin
    if(rst || ctrl_i_regE_bubble) begin
        //execute
        regE_o_valA         <= 32'd0;
        regE_o_valB         <= 32'd0;
        regE_o_imm          <= 32'd0;
        regE_o_alu_valA_sel <= `alu_valA_sel_valA;
        regE_o_alu_valB_sel <= `alu_valB_sel_valB;
        regE_o_alu_func_sel <= `alu_func_add;
        //memory
        regE_o_need_jump    <= 1'b0;
        regE_o_mem_rw       <= `mem_no_rw;
        //write_back
        regE_o_wb_reg_wen   <= `reg_wen_no_w;
        regE_o_wb_rd        <= 5'd0;
        regE_o_wb_valD_sel  <= `wb_valD_sel_valE;     

        //commit for simulator
        regE_o_pc           <= 32'd0; 
        regE_o_commit       <= 1'd0;  
        regE_o_pre_pc       <= 32'd0;
        regE_o_is_jalr      <= 1'b0;
    end
    else begin
        //execute
        regE_o_valA         <= decode_i_valA;
        regE_o_valB         <= decode_i_valB;
        regE_o_imm          <= decode_i_imm;
        regE_o_alu_valA_sel <= decode_i_alu_valA_sel;
        regE_o_alu_valB_sel <= decode_i_alu_valB_sel;
        regE_o_alu_func_sel <= decode_i_alu_func_sel;
        //memory
        regE_o_mem_rw       <= decode_i_mem_rw;
        //write_back
        regE_o_wb_reg_wen   <= decode_i_wb_reg_wen;
        regE_o_wb_rd        <= decode_i_wb_rd;
        regE_o_wb_valD_sel  <= decode_i_wb_valD_sel;

        regE_o_need_jump    <= decode_i_need_jump;
        regE_o_is_jalr      <= decode_i_is_jalr;

        //commit for simulator
        regE_o_instr        <= regD_i_instr;
        regE_o_pc           <= regD_i_pc;  
        regE_o_commit       <= regD_i_commit;
        regE_o_pre_pc       <= regD_i_pre_pc;
    end
end

endmodule
