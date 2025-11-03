module btb #(
    parameter type btb_update_t = logic,      // 来自 EX 阶段的更新数据类型
    parameter type btb_prediction_t = logic,  // 发送给 IF 阶段的预测数据类型
    
    parameter int VLEN             = 64,      // PC 的位宽
    parameter int BTB_NR_ROWS      = 128,     // BTB 的行数 (组数)
    parameter int BTB_LOG_NR_ROWS  = 7,       // log2(BTB_NR_ROWS)
    parameter int BTB_WAYS         = 2,       // 组相联的度数 (Way, 您的代码中是 2)
    parameter int BTB_OFFSET       = 2        // PC 的低位偏移 (对于 32-bit 指令，通常为 2)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_bp_i,
    input  logic [VLEN-1:0] vpc_i,
    input  btb_update_t btb_update_i,
    output btb_prediction_t btb_prediction_o
);

    // --------------------------
    // 索引和 Tag 位宽计算
    // --------------------------
    localparam BTB_INDEX_START_BIT = BTB_OFFSET;
    localparam BTB_INDEX_END_BIT   = BTB_OFFSET + BTB_LOG_NR_ROWS - 1;
    localparam BTB_TAG_BITS        = VLEN - BTB_OFFSET - BTB_LOG_NR_ROWS;

    // --------------------------
    // BTB 存储结构定义 (包含 Tag 和 LRU 位)
    // --------------------------
    typedef struct packed {
        logic [BTB_TAG_BITS-1:0] tag;          // PC 的高位标签
        logic [VLEN-1:0]         pred_add;     // 预测的目标地址
        logic                    valid;        // 有效位
    } btb_entry_t;

    // 存储体：[行索引][Way 索引]
    btb_entry_t btb_q[BTB_NR_ROWS-1:0][BTB_WAYS-1:0],
                btb_d[BTB_NR_ROWS-1:0][BTB_WAYS-1:0];

    // LRU 状态：每行一个 LRU 位 (2-way 只需要 1 bit)
    logic [BTB_NR_ROWS-1:0] lru_q, lru_d;

    // --------------------------
    // 索引和 Tag 信号
    // --------------------------
    // 您的原始代码只使用了 PC 的一部分，现在我们使用计算出的位宽来提取索引
    logic [BTB_LOG_NR_ROWS-1:0] btb_index;
    logic [BTB_TAG_BITS-1:0]    vpc_tag;
    
    // 更新索引和 Tag
    logic [BTB_LOG_NR_ROWS-1:0] btb_update_index;
    logic [BTB_TAG_BITS-1:0]    btb_update_tag;

    // --------------------------
    // 索引和 Tag 计算 (使用更规范的位范围)
    // --------------------------
    // 组索引 (Row Index): PC 的中间位
    assign btb_index        = vpc_i[BTB_INDEX_END_BIT : BTB_INDEX_START_BIT];
    assign btb_update_index = btb_update_i.pc[BTB_INDEX_END_BIT : BTB_INDEX_START_BIT];

    // Tag: PC 的高位
    assign vpc_tag        = vpc_i[VLEN-1 : BTB_INDEX_END_BIT + 1];
    assign btb_update_tag = btb_update_i.pc[VLEN-1 : BTB_INDEX_END_BIT + 1];

    // --------------------------
    // 预测输出逻辑 (查询和 Tag 匹配)
    // --------------------------
    always_comb begin : prediction_output
        btb_prediction_t result;
        logic            way0_hit, way1_hit;
        logic            hit;

        // Way 0 命中判断：有效 AND Tag 匹配
        way0_hit = btb_q[btb_index][0].valid && (btb_q[btb_index][0].tag == vpc_tag);
        // Way 1 命中判断：有效 AND Tag 匹配
        way1_hit = btb_q[btb_index][1].valid && (btb_q[btb_index][1].tag == vpc_tag);

        hit = way0_hit | way1_hit;
        
        if (hit) begin
            // 命中：选择命中的 Way 的目标地址
            if (way0_hit) begin
                result.target_address = btb_q[btb_index][0].pred_add;
            end else begin // 只有 Way 1 命中了
                result.target_address = btb_q[btb_index][1].pred_add;
            end
            result.hit = 1'b1;
        end else begin
            // 未命中：输出无效预测
            result.target_address = '0;
            result.hit = 1'b0;
        end

        btb_prediction_o = result;
    end

    // --------------------------
    // 更新逻辑 (组合逻辑：写入新条目和 LRU)
    // --------------------------
    always_comb begin
        btb_d = btb_q;
        lru_d = lru_q;

        if (btb_update_i.valid) begin
            // 1. 检查是否有 Way 已命中 (避免重复写入并更新 LRU)
            logic way0_hit, way1_hit;
            way0_hit = btb_q[btb_update_index][0].valid && (btb_q[btb_update_index][0].tag == btb_update_tag);
            way1_hit = btb_q[btb_update_index][1].valid && (btb_q[btb_update_index][1].tag == btb_update_tag);

            // 2. 决定写入的 Way
            int write_way;
            if (way0_hit) begin
                write_way = 0;          // Way 0 命中，更新 Way 0
                lru_d[btb_update_index] = 1'b1; // Way 0 被使用，Way 1 变 LRU
            end else if (way1_hit) begin
                write_way = 1;          // Way 1 命中，更新 Way 1
                lru_d[btb_update_index] = 1'b0; // Way 1 被使用，Way 0 变 LRU
            end else begin
                // 都不命中 (Miss)，选择 LRU Way 进行替换
                write_way = lru_q[btb_update_index];
                // 替换后，更新 LRU 位：切换到另一个 Way
                lru_d[btb_update_index] = ~lru_q[btb_update_index];
            end

            // 3. 写入新数据 (Tag, Target Address, Valid)
            btb_d[btb_update_index][write_way].tag      = btb_update_tag;
            btb_d[btb_update_index][write_way].pred_add = btb_update_i.target_address;
            btb_d[btb_update_index][write_way].valid    = 1'b1;
        end
    end

    // --------------------------
    // 时序逻辑
    // --------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || flush_bp_i) begin
            // 复位/Flush 时清空
            for (int i = 0; i < BTB_NR_ROWS; i++) begin
                for (int j = 0; j < BTB_WAYS; j++) begin
                    btb_q[i][j].valid <= 1'b0;
                    btb_q[i][j].tag   <= '0;
                end
                lru_q[i] <= 1'b0; // 初始化 LRU
            end
        end else begin
            btb_q <= btb_d;
            lru_q <= lru_d;
        end
    end

endmodule