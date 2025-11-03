module btb (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_bp_i,
  input logic [config_pkg::VLEN-1:0] vpc_i,
  input btb_update_t btb_update_i,

  output btb_prediction_t  [1:0] btb_prediction_o
);
  logic [BTB_LOG_NR_ROWS-1:0] btb_index0,btb_index1, btb_update_pc;             // 行索引的下标和更新时的行索引
  logic [ROW_INDEX_BITS-1:0]  btb_update_row_index, btb_row_index0,btb_row_index1;  // 更新时候的行内索引
  
  bp_prediction_t [1:0]btb_prediction;  // BTB预测地址，供后续判断预测输出使用
  bp_prediction_t
        btb_d[BTB_NR_ROWS-1:0][1:0];
        btb_q[BTB_NR_ROWS-1:0][1:0];

  assign btb_index            = vpc_i           [BTB_PREDICTION_BITS-1:BTB_ROW_ADDR_BITS+BTB_OFFSET];   // 从当前PC（vpc_i）中提取位，计算查询索引（用于读取BTB）
  assign btb_row_index        = vpc_i           [BTB_ROW_ADDR_BITS+BTB_OFFSET-1:BTB_OFFSET];       
  assign btb_update_pc        = btb_update_i.pc [BTB_PREDICTION_BITS-1:BTB_ROW_ADDR_BITS+BTB_OFFSET];   // 从更新PC中提取位，计算更新索引（用于写入BTB）
  assign btb_update_row_index = btb_update_i.pc [BTB_ROW_ADDR_BITS+BTB_OFFSET-1:BTB_OFFSET];            // 计算行内索引（每行2个条目，用1位区分第0个或第1个）

  for (genvar i = 0; i < 2; i++) begin : gen_btb_output
    assign btb_prediction_o     = btb_q           [btb_index][btb_row_index];
  end
  // 更新数据
  always_comb begin : update_branch_predict
      btb_d = btb_q;
      if (btb_update_i.valid) begin
        btb_d [btb_update_pc][btb_update_row_index].pred_add  = btb_update_i.target_address;
        btb_d [btb_update_pc][btb_update_row_index].valid     = 1'b1;
      end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      for (int i = 0; i < BTB_NR_ROWS; i++) btb_q[i] <= '{default: 0};
    end
    else begin
      btb_q <= btb_d;
    end
  end 

endmodule