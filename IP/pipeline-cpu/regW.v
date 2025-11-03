`include "define.v"
module regW(
    input wire clk,
    input wire rst,
    //regM直接传过来的信号
    input wire          regM_i_wb_reg_wen,
    input wire [4:0]    regM_i_wb_rd,
    input wire [1:0]    regM_i_wb_valD_sel,
    input wire [31:0]   regM_i_valE,
    

    //
    input wire [31:0]   memory_i_valM,

    //commit
    input wire  [31:0]  regM_i_pc,
    input wire  [31:0]  regM_i_instr,
    input wire          regM_i_commit,  
    input wire [31:0]   regM_i_pre_pc,

    output reg          regW_o_wb_reg_wen,
    output reg [4:0]    regW_o_wb_rd,
    output reg [1:0]    regW_o_wb_valD_sel,
    output reg [31:0]   regW_o_valE,
    output reg [31:0]   regW_o_valM,
    //commit
    output reg [31:0]   regW_o_pc,
    output reg [31:0]   regW_o_instr,
    output reg          regW_o_commit,
    output reg [31:0]   regW_o_pre_pc
);
always @(posedge clk)begin
    if(rst) begin
        regW_o_wb_reg_wen   <= `reg_wen_no_w;
        regW_o_wb_rd        <=  5'd0;
        regW_o_wb_valD_sel  <= `wb_valD_sel_valE;
        regW_o_valE         <=  32'd0;
        regW_o_pc           <= 32'd0;
        regW_o_commit       <= 1'd0;
        regW_o_valM         <= 32'd0;
    end
    else begin
        regW_o_wb_reg_wen   <= regM_i_wb_reg_wen;
        regW_o_wb_rd        <= regM_i_wb_rd;
        regW_o_wb_valD_sel  <= regM_i_wb_valD_sel;
        regW_o_valE         <= regM_i_valE;
        regW_o_valM         <= memory_i_valM;
        //commit
        regW_o_pc           <= regM_i_pc;
        regW_o_instr        <= regM_i_instr;
        regW_o_commit       <= regM_i_commit;
        regW_o_pre_pc       <= regM_i_pre_pc;
    end
end

endmodule