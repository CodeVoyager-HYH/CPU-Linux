module bht #(
    parameter type bht_update_t = logic,      // 来自 EX 阶段的更新数据类型
    parameter type bht_prediction_t = logic,  // 发送给 IF 阶段的预测数据类型
    
    // BHT 配置参数 (使用 CVA6 风格的命名)
    parameter int VLEN = 64,                  // PC 的位宽 (通常为 64 或 32)
    parameter int BHT_NR_ENTRIES = 512,       // BHT 总条目数
    parameter int BHT_LOG_NR_ENTRIES = 9,     // log2(BHT_NR_ENTRIES)
    parameter int BHT_OFFSET = 2              // PC 的低位偏移 (对于 32-bit 指令，通常为 2)
) (
    input  logic clk_i,
    input  logic rst_ni,
    // 来自控制器的 Flush 信号 (例如分支预测错误或异常)
    input  logic flush_bp_i,
    // 查询 PC (通常来自 PC Gen/IF 阶段)
    input  logic [VLEN-1:0] vpc_i,
    // 来自 Commit/EX 阶段的更新数据
    input  bht_update_t bht_update_i,

    // 预测输出 (发送给 IF 阶段)
    output bht_prediction_t bht_prediction_o
);

    // BHT 索引和 Tag 位宽的计算
    // BHT 索引使用 PC 的中间位
    localparam BHT_INDEX_START_BIT = BHT_OFFSET;
    localparam BHT_INDEX_END_BIT   = BHT_OFFSET + BHT_LOG_NR_ENTRIES - 1;
    // BHT Tag 使用 PC 的剩余高位
    localparam BHT_TAG_BITS = VLEN - BHT_OFFSET - BHT_LOG_NR_ENTRIES;

    // --------------------------
    // BHT 存储结构定义 (包含 Tag)
    // --------------------------
    typedef struct packed {
        logic [BHT_TAG_BITS-1:0] tag;              // PC 的高位标签
        logic                    valid;            // 有效位
        logic [1:0]              saturation_counter; // 2-bit 饱和计数器
    } bht_entry_t;

    // BHT 存储体
    bht_entry_t bht_q[BHT_NR_ENTRIES-1:0],
                bht_d[BHT_NR_ENTRIES-1:0];

    // --------------------------
    // 索引信号
    // --------------------------
    logic [BHT_LOG_NR_ENTRIES-1:0] bht_index, bht_update_index;
    logic [BHT_TAG_BITS-1:0]       vpc_tag, bht_update_tag;
    logic [1:0]                    current_counter;

    // --------------------------
    // 索引和 Tag 计算
    // --------------------------
    // BHT 索引：PC 的中间位
    assign bht_index        = vpc_i[BHT_INDEX_END_BIT : BHT_INDEX_START_BIT];
    assign bht_update_index = bht_update_i.pc[BHT_INDEX_END_BIT : BHT_INDEX_START_BIT];

    // Tag：PC 的高位
    assign vpc_tag        = vpc_i[VLEN-1 : BHT_INDEX_END_BIT + 1];
    assign bht_update_tag = bht_update_i.pc[VLEN-1 : BHT_INDEX_END_BIT + 1];

    // --------------------------
    // 预测输出逻辑 (包含 Tag 匹配)
    // --------------------------
    always_comb begin : prediction_output
        bht_entry_t entry = bht_q[bht_index];
        // 预测命中：有效位为真 且 Tag 匹配
        logic bht_hit = entry.valid && (entry.tag == vpc_tag);

        if (bht_hit) begin
            // 预测结果：2-bit 计数器的 MSB (最高有效位) 为 1 预测 Taken (跳转)
            bht_prediction_o.valid = 1'b1;
            bht_prediction_o.taken = entry.saturation_counter[1];
        end else begin
            // 未命中或Tag不匹配：默认预测不跳转 (NT)
            bht_prediction_o.valid = 1'b0; // 或 1'b1, 取决于您的整体预测策略，这里设为0表示 BHT 未提供有效预测
            bht_prediction_o.taken = 1'b0;
        end
    end

    // --------------------------
    // 更新逻辑 (组合逻辑)
    // --------------------------
    always_comb begin
        bht_d = bht_q;  // 默认保持

        if (bht_update_i.valid) begin
            // 读取当前值
            current_counter = bht_q[bht_update_index].saturation_counter;

            // 预计算下一个计数器值
            logic [1:0] next_counter;
            case (current_counter)
                2'b00: next_counter = bht_update_i.taken ? 2'b01 : 2'b00;
                2'b01: next_counter = bht_update_i.taken ? 2'b10 : 2'b00;
                2'b10: next_counter = bht_update_i.taken ? 2'b11 : 2'b01;
                2'b11: next_counter = bht_update_i.taken ? 2'b11 : 2'b10;
                default: next_counter = current_counter; // 不应发生
            endcase

            // 写入 BHT (包括新的计数器、Tag 和有效位)
            bht_d[bht_update_index].saturation_counter = next_counter;
            bht_d[bht_update_index].tag                = bht_update_tag;
            bht_d[bht_update_index].valid              = 1'b1;
        end
    end

    // --------------------------
    // 时序逻辑
    // --------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || flush_bp_i) begin
            // 复位或 Flush 时，清空 BHT
            for (int i = 0; i < BHT_NR_ENTRIES; i++) begin
                // 设置初始状态为 10 (弱跳转), 有效位清零
                bht_q[i].valid              <= 1'b0;
                bht_q[i].saturation_counter <= 2'b10;
                bht_q[i].tag                <= '0;
            end
        end else begin
            // 正常工作，更新 BHT
            bht_q <= bht_d;
        end
    end

endmodule