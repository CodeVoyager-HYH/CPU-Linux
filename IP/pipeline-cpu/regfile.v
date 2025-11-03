module regfile(
    input wire clk,
    input wire rst,
    input wire         write_back_i_wb_reg_wen,
	input wire [4:0]   write_back_i_wb_rd,
	input wire [31:0]  write_back_i_wb_valD,

    input  wire [4:0]  decode_i_rs1,
    input  wire [4:0]  decode_i_rs2,
    output wire [31:0] regfile_o_valA,
    output wire [31:0] regfile_o_valB
);
reg [31:0] regfile[31:0];
import "DPI-C" function void dpi_read_regfile(input logic [31 : 0] a []);

initial begin
	dpi_read_regfile(regfile);
end
initial begin
    integer i;
    for (i = 0; i < 32; i = i + 1) begin
        regfile[i] = i;
    end
    regfile[20] = 32'h80000000;
end


assign regfile_o_valA = decode_i_rs1 == 5'd0 ? 32'd0 : regfile[decode_i_rs1];
assign regfile_o_valB = decode_i_rs2 == 5'd0 ? 32'd0 : regfile[decode_i_rs2];

always @(posedge clk) begin
    if(rst) begin
        regfile[0]  <= 32'd0;
    end
    else if(write_back_i_wb_reg_wen && write_back_i_wb_rd != 5'd0) begin
        regfile[write_back_i_wb_rd] <= write_back_i_wb_valD;
    end
end




endmodule