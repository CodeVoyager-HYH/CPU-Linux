module pseudoLRU #(
    parameter int unsigned ENTRIES = 8
)(
    input logic clk_i,
    input logic rst_ni,

    input logic access_hit_i, 
    input logic [$clog2(ENTRIES)-1:0] access_idx_i,
    output logic [$clog2(ENTRIES)-1:0] replacement_idx_o
);

logic [ENTRIES-1:0] access_array;
logic found;
logic found2;

logic [ENTRIES-1:0] replace_en;

function logic [$clog2(ENTRIES)-1:0] cast_integer(input [31:0] iter);
    cast_integer = iter[$clog2(ENTRIES)-1:0];
endfunction

always_comb begin
    access_array = '0; 
    found = 0;
    for (int unsigned i = 0; (i < ENTRIES) && (!found); i++) begin
        if (i == access_idx_i) begin
            access_array[i] = 1'b1;
            found = 1;
        end
    end
end

logic [2*(ENTRIES-1)-1:0] plru_tree_q, plru_tree_d;
always_comb begin : plru_replacement
    plru_tree_d = plru_tree_q;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
        automatic int unsigned idx_base = 0;
        automatic int unsigned shift = 0;
        automatic logic [31:0] new_index = '0;
        if (access_array[i] & access_hit_i) begin
            for (int unsigned lvl = 0; lvl < $unsigned($clog2(ENTRIES)); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                shift = $unsigned($clog2(ENTRIES)) - lvl;
                new_index =  ~((i >> (shift-1)) & 32'b1);
                plru_tree_d[idx_base + (i >> shift)] = new_index[0];
            end
        end
    end
    for (int unsigned i = 0; i < ENTRIES; i += 1) begin
        automatic logic en = 1'b1;
        automatic logic [31:0] new_index2 = '0;
        automatic int unsigned idx_base, shift;
        for (int unsigned lvl = 0; lvl < $unsigned($clog2(ENTRIES)); lvl++) begin
            idx_base = $unsigned((2**lvl)-1);
            shift = $unsigned($clog2(ENTRIES)) - lvl;

            new_index2 =  (i >> (shift-1)) & 32'b1;
            if (new_index2[0]) begin
                en &= plru_tree_q[idx_base + (i>>shift)];
            end else begin
                en &= ~plru_tree_q[idx_base + (i>>shift)];
            end
        end
        replace_en[i] = en;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        plru_tree_q <= '0;
    end else begin
        plru_tree_q <= plru_tree_d;
    end
end

always_comb begin
    replacement_idx_o = '0; 
    found2 = 1'b0;
    for (int unsigned iter = 0; (iter < $unsigned(ENTRIES)) && (!found2); iter++) begin
        if (replace_en[iter] == 1'b1) begin
            replacement_idx_o = cast_integer(iter);
            found2 = 1'b1;
        end
    end
end


endmodule