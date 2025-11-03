module regF(
    input wire clk,
    input wire rst,
    input wire          ctrl_i_regF_stall,
    input  wire [31:0] select_pc_o_pc,
    output reg  [31:0] regF_o_pc
);
always @(posedge clk) begin
    if(rst) begin
        regF_o_pc     <= 32'h80000000;
    end
    else if(~ctrl_i_regF_stall)begin
        regF_o_pc     <= select_pc_o_pc;
    end
end
endmodule
