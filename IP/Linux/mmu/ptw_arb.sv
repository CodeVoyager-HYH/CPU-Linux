module ptw_arb 
import mmu_pkg::*;
#(
)(
    input logic clk_i,
    input logic rst_ni,

    // iTLB & dTLB interfaces
    input tlb_ptw_comm_t itlb_ptw_comm_i,   // iTLB 发给PTW的请求
    input tlb_ptw_comm_t dtlb_ptw_comm_i,   // dTLB 发给PTW的请求
    output ptw_tlb_comm_t ptw_itlb_comm_o,  // PTW 发给 iTLB的相应请求
    output ptw_tlb_comm_t ptw_dtlb_comm_o,  // PTW 发给 dTLB的响应

    // PTW interface
    input ptw_tlb_comm_t ptw_tlb_comm_i,    // PTW发给仲裁器的响应
    output tlb_ptw_comm_t tlb_ptw_comm_o    // 仲裁器发给PTW的请求
);

logic is_req_waiting_d, is_req_waiting_q;
tlb_ptw_comm_t itlb_req_waiting_d, itlb_req_waiting_q;

typedef enum logic [1:0] {
    IDLE,           // 空闲
    SERVING_iTLB,   // 正在处理iTLB
    SERVING_dTLB    // 正在处理dTLB
} arbptw_state;

arbptw_state current_state, next_state;
always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
        current_state <= IDLE;
        is_req_waiting_q <= 1'b0;
        itlb_req_waiting_q <= '0;
    end
    else begin
        current_state <= next_state;
        is_req_waiting_q <= is_req_waiting_d;
        itlb_req_waiting_q <= itlb_req_waiting_d;
    end
end

always_comb begin
    // 初始化默认值，防止出现latch
    is_req_waiting_d = is_req_waiting_q;
    itlb_req_waiting_d = itlb_req_waiting_q;
    tlb_ptw_comm_o = '0;
    next_state = current_state;

    // 2. PTW→TLB的响应默认置0（未服务的TLB无响应）
    ptw_itlb_comm_o.resp.valid = 1'b0;
    ptw_itlb_comm_o.resp.error = 1'b0;
    ptw_itlb_comm_o.resp.pte = '0;
    ptw_itlb_comm_o.resp.level = '0;
    ptw_dtlb_comm_o.resp.valid = 1'b0;
    ptw_dtlb_comm_o.resp.error = 1'b0;
    ptw_dtlb_comm_o.resp.pte = '0;
    ptw_dtlb_comm_o.resp.level = '0;

    // 3. PTW就绪信号默认置0（仅IDLE状态允许新请求）
    ptw_itlb_comm_o.ptw_ready = 1'b0;
    ptw_dtlb_comm_o.ptw_ready = 1'b0;

    // 4. 透传PTW的全局信号（无需仲裁，所有TLB都需接收）
    ptw_itlb_comm_o.ptw_status = ptw_tlb_comm_i.ptw_status;
    ptw_dtlb_comm_o.ptw_status = ptw_tlb_comm_i.ptw_status;
    
    ptw_itlb_comm_o.invalidate_tlb = ptw_tlb_comm_i.invalidate_tlb;
    ptw_dtlb_comm_o.invalidate_tlb = ptw_tlb_comm_i.invalidate_tlb;

    case (current_state)
        IDLE : begin    // 空闲
            ptw_itlb_comm_o.resp = '0;          // resp表示对 PTW对TLB转换请求的响应
            ptw_dtlb_comm_o.resp = '0;          
            ptw_itlb_comm_o.ptw_ready = 1'b1;   // ptw_ready PTW 是否准备好接受新的转换请求
            ptw_dtlb_comm_o.ptw_ready = 1'b1;

            // 情况1 iTLB和dTLB同时请求(优先级 dTLB > iTLB)
            if (dtlb_ptw_comm_i.req.valid && itlb_ptw_comm_i.req.valid) begin
                is_req_waiting_d = 1'b1;                // 标记有等待请求（iTLB被抢占）
                itlb_req_waiting_d = itlb_ptw_comm_i;   // 缓存iTLB的请求
                tlb_ptw_comm_o = dtlb_ptw_comm_i;       // 向PTW转发dTLB的请求
                next_state = SERVING_dTLB;              // 切换到服务dTLB
            end else if (is_req_waiting_q) begin        // 子情况2：有等待的请求（之前被抢占的iTLB请求），解决iTLB请求
                ptw_itlb_comm_o.ptw_ready = 1'b0;
                ptw_dtlb_comm_o.ptw_ready = 1'b0;
                next_state = SERVING_iTLB;
            end else if (dtlb_ptw_comm_i.req.valid) begin   // 子情况3：仅dTLB有请求
                tlb_ptw_comm_o = dtlb_ptw_comm_i;
                next_state = SERVING_dTLB;
            end else if (itlb_ptw_comm_i.req.valid) begin   // 子情况4：仅iTLB有请求
                tlb_ptw_comm_o = itlb_ptw_comm_i;
                next_state = SERVING_iTLB;
            end else begin
                tlb_ptw_comm_o = '0;
                next_state = IDLE;
            end
        end
        SERVING_iTLB : begin    // 状态2：SERVING_iTLB（服务iTLB请求)
            ptw_itlb_comm_o.resp = ptw_tlb_comm_i.resp;
            ptw_dtlb_comm_o.resp = '0;
            // 向PTW转发请求：优先转发等待的iTLB请求，无则转发当前iTLB请求
            tlb_ptw_comm_o = (is_req_waiting_q) ? itlb_req_waiting_q : itlb_ptw_comm_i;
            if (!ptw_tlb_comm_i.resp.valid) begin  // 子情况1：PTW尚未处理完成（resp.valid=0）→ 保持当前状态
                next_state = SERVING_iTLB;
            end else begin
                next_state = IDLE;
                is_req_waiting_d = 1'b0;
            end
        end
        SERVING_dTLB : begin
            ptw_itlb_comm_o.resp = '0;
            ptw_dtlb_comm_o.resp = ptw_tlb_comm_i.resp;
            tlb_ptw_comm_o = dtlb_ptw_comm_i;
            if (!ptw_tlb_comm_i.resp.valid) begin
                next_state = SERVING_dTLB;
            end else begin
                next_state = IDLE;
            end
        end
    endcase
end

endmodule
