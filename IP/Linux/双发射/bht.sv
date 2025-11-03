module bht (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_bp_i,
  input logic [config_pkg::VLEN-1:0] vpc_i,
  input bht_update_t bht_update_i,

  output bht_prediction_t [1:0] bht_prediction_o
);
  struct packed {
    logic       valid;
    logic [1:0] saturation_counter;
  }
      bht_d[BHT_NR_ROWS-1:0][1:0],
      bht_q[BHT_NR_ROWS-1:0][1:0];

  logic [BHT_LOG_NR_ROWS-1:0]    bht_index, bht_update_pc;
  logic [BTB_ROW_INDEX_BITS-1:0] bht_row_index,  bht_update_row_index;
  logic [1:0] saturation_counter;
  logic [31:0] bht_jump_pc;


  assign bht_index                = vpc_i           [BHT_PREDICTION_BITS-1:BHT_OFFSET+BHT_ROW_ADDR_BITS];
  assign bht_row_index            = vpc_i           [BHT_ROW_ADDR_BITS+BHT_OFFSET-1:BHT_OFFSET];
  assign bht_update_pc            = bht_update_i.pc [BHT_PREDICTION_BITS-1:BHT_OFFSET+BHT_ROW_ADDR_BITS];
  assign bht_update_row_index     = bht_update_i.pc [BHT_ROW_ADDR_BITS+BHT_OFFSET-1:BHT_OFFSET];

  assign bht_jump_pc             = vpc_i + imm_i;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_bht_output
      assign bht_prediction_o[i].valid = bht_q[index][i].valid;
      assign bht_prediction_o[i].taken = bht_q[index][i].saturation_counter[1] == 1'b1;
  end

  always_comb begin
    bht_d = bht_q;
    saturation_counter = bht_q[update_pc][update_row_index].saturation_counter;
    if (bht_update_i.valid) begin
      if (saturation_counter == 2'b11) begin  // 强跳转
          if(!bht_update_i.taken) begin
            bht_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
          end
        end
          
      if (saturation_counter == 2'b10) begin  // 弱跳转
          if(bht_update_i.taken) begin
            bht_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
          end
          if(!bht_update_i.taken) begin
            bht_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
          end
      end

      if (saturation_counter == 2'b01) begin  // 弱不跳转
        if(bht_update_i.taken) begin
            bht_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
        end
        if(!bht_update_i.taken) begin
            bht_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
        end
      end

      if (saturation_counter == 2'b00) begin  // 强不跳转
        if(bht_update_i.taken) begin
          bht_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
        end
      end

    bht_d[update_pc][update_row_index].valid = 1'b1;    
    end
  end                     

  always_comb @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      for(int i = 0; i < BHT_NR_ROWS; i++) begin
        for(int j = 0; j < 2; j++) begin
          bht_q[i][j].valid <= 1'b0;
          bht_q[i][j].saturation_counter <= 2'b10;
        end
      end
    end
    else begin
      bht_q <= bht_d;
    end
  end             

endmodule