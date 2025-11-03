// 指令队列
// 主要功能就是弥补前后端的速度差，也可以当成两级流水线中间暂停的部分
// 这里面主要就是FIFO队列
// 主要变量有两个下标：输入下标，输出下标
// 还有一个分支跳转指令的掩码，用于更改下标
// 有两个FIFO 一个是保存指令，一个保存地址

module instr_queue
  import config_pkg::*;
#(
    parameter type fetch_entry_t = logic
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic [1:0] valid_i,                                  // 指示输入是可以使用的
    input logic [1:0][31:0] instr_i,
    input logic [1:0][config_pkg::VLEN-1:0] addr_i,                
    input logic backend_ready_i,                                // 表示后端已经准备就绪
    input config_pkg::cf_t [1:0] cf_type_i,                     // 表示跳转类型
    input logic [1:0][config_pkg::VLEN-1:0] predict_address_i,  // 预测地址                  

    output logic ready_o,                                       // 表示可以传入指令队列                 
    output logic [1:0] consumed_o,                              // 指令是否被成功消费 相当于只要

    //重放
    output logic replay_o,                                      // 重放指示               
    output logic [config_pkg::VLEN-1:0] replay_addr_o,          // 重放地址    

    output fetch_entry_t  fetch_entry_o,                        // 输入到后端的信息
    output logic fetch_entry_valid_o                            // 输入后端信息是否有效
);

  // FIFO 接口
  fetch_entry_t fifo_data_in0,fifo_data_in1, fifo_data_out;
  logic fifo_push0,fifo_push1,fifo_pop;
  logic fifo_full, fifo_empty, usage;

  // 状态
  logic [1:0] consumed_q, consumed_n;

  // ---------------------------
  // FIFO 实例化
  // ---------------------------
  fifo #(
    .DATA_WIDTH($bits(fetch_entry_t)),
    .DEPTH(8),
    .dtype(fetch_entry_t)
  ) i_fifo (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .flush_i (flush_i),

    .data_i0 (fifo_data_in0),
    .push_i0 (fifo_push0),

    .data_i1 (fifo_data_in1),
    .push_i1 (fifo_push1),

    .data_o  (fifo_data_out),
    .pop_i   (fifo_pop),

    .full_o  (fifo_full),
    .empty_o (fifo_empty),
    .usage_o (usage)
  );

  // ---------------------------
  // 组合逻辑
  // ---------------------------
  always_comb begin
    // 默认
    consumed_n          = '0;
    fifo_push0          = '0;
    fifo_push1          = '0;
    fifo_pop            = '0;
    ready_o             = ~fifo_full;  
    replay_o            = '0;
    replay_addr_o       = '0;
    fetch_entry_valid_o = '0;
    fetch_entry_o       = '0;

    // ---------------------------
    // 写入 FIFO
    // ---------------------------
    if (!fifo_full) begin //fifo 未满写入
      if(valid_i[0]) begin            //写入第一条指令
        fifo_data_in0.address      = addr_i[0];
        fifo_data_in0.instruction  = instr_i[0];
        fifo_data_in0.branch_predict.cf = cf_type_i[0];
        fifo_data_in0.branch_predict.predict_address = predict_address_i[0];
        fifo_push0 = 1'b1;
        consumed_n[0] = 1'b1;
      end
      if(valid_i[1] & usage)begin     //写入第二条指令，且队列空余需要大于等于2
        fifo_data_in1.address      = addr_i[1];
        fifo_data_in1.instruction  = instr_i[1];
        fifo_data_in1.branch_predict.cf = cf_type_i[1];
        fifo_data_in1.branch_predict.predict_address = predict_address_i[1];
        fifo_push1 = 1'b1;
        consumed_n[1] = 1'b1;
      end
      if(valid_i[1] & !usage) begin  // 重放只可能是第二条指令没地方存入
        replay_o                = 1'b1;
        replay_addr_o           = addr_i[1];
      end
    end else if (valid_i[0] == 1'b1) begin
      // FIFO 满了，触发重放
      replay_o      = 1'b1;
      replay_addr_o = addr_i[0];
    end

    // ---------------------------
    // 读出 FIFO
    // ---------------------------
    if (!fifo_empty && backend_ready_i) begin
      fetch_entry_o       = fifo_data_out;
      fetch_entry_valid_o = 1'b1;
      fifo_pop             = 1'b1;
    end
  end

  // ---------------------------
  // 时序逻辑
  // ---------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      consumed_q     <= '0;
    end else begin
      consumed_q     <= consumed_n;
    end
  end

  // ---------------------------
  // 输出已消耗指令
  // ---------------------------
  assign consumed_o = {fifo_push1,fifo_push0};

endmodule
