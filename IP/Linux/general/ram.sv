module ram #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter DATA_DEPTH = 1024,
    parameter type dtype = logic;
) (
    input  logic clk_i,

    input  logic WrEn_i,
    input  logic [ADDR_WIDTH-1:0] WrAddr_i,
    input  dtype [DATA_WIDTH-1:0] WrData_i,

    input  logic [ADDR_WIDTH]     RdAddr_i,
    output dtype [DATA_WIDTH]     RdDdata_o
);

    dtype [DATA_WIDTH-1:0] mem [DATA_DEPTH-1:0]= '{default:0};

    assign RdDdata_o = mem[RdAddr_i];

    always_ff @(posedge clk_i) begin
        if(WrEn_i) begin
            mem[WrAddr_i] <= WrData_i;
        end
    end

endmodule