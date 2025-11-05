module sram #(
    int unsigned DATA_WIDTH = 64,
    int unsigned NUM_WORDS  = 1024
)(
    input  logic                          clk_i,

    input  logic                          req_i,
    input  logic                          we_i,
    input  logic [$clog2(NUM_WORDS)-1:0]  addr_i,
    input  logic [DATA_WIDTH-1:0]         wdata_i,
    input  logic [DATA_WIDTH-1:0]         be_i,
    output logic [DATA_WIDTH-1:0]         rdata_o
);
    localparam ADDR_WIDTH = $clog2(NUM_WORDS);

    logic [DATA_WIDTH-1:0] ram [NUM_WORDS-1:0];
    logic [ADDR_WIDTH-1:0] raddr_q;

    always_ff @(posedge clk_i) begin
        if (req_i) begin
            if (!we_i)
                raddr_q <= addr_i;
            else
            for (int i = 0; i < DATA_WIDTH; i++)
                if (be_i[i]) ram[addr_i][i] <= wdata_i[i];
        end
    end

    assign rdata_o = ram[raddr_q];

endmodule