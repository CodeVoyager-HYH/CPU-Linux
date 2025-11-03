module tlb 
import mmu_pkg::*;
#(
)(
    input logic clk_i,                      
    input logic rst_ni,                     
    
    input cache_tlb_comm_t cache_tlb_comm_i,    
    output tlb_cache_comm_t tlb_cache_comm_o,   

    input ptw_tlb_comm_t ptw_tlb_comm_i,     
    output tlb_ptw_comm_t tlb_ptw_comm_o,       

    output logic pmu_tlb_access_o,            
    output logic pmu_tlb_miss_o               
);

tlb_entry_t [TLB_ENTRIES-1:0] tlb_entries;

function [TLB_IDX_SIZE-1:0] trunc_tlb_idx_size(input [31:0] val_in);
    trunc_tlb_idx_size = val_in[TLB_IDX_SIZE-1:0];
endfunction

function [TLB_IDX_SIZE-1:0] trunc_tlb_idx_size_4in(input [3:0] val_in);
    trunc_tlb_idx_size_4in = val_in[TLB_IDX_SIZE-1:0];
endfunction

// TLB WRITE LOGIC
///////////////////////////////

logic clear_tlb, write_tlb;
logic [TLB_ENTRIES-1:0] clear_mask;
logic [TLB_IDX_SIZE-1:0] write_idx;

assign write_idx = tlb_req_tmp.write_idx; 
always_ff @(posedge clk_i, negedge rst_ni) begin
    if(~rst_ni) begin
        for (int i=0; i<TLB_ENTRIES; ++i) begin
            tlb_entries[i] <= '0;
        end
    end else begin
        if (clear_tlb) begin
            for (int i=0; i<TLB_ENTRIES; ++i) begin
                if (clear_mask[i]) tlb_entries[i] <= '0;
            end
        end else if (write_tlb) begin
            tlb_entries[write_idx].vpn <= tlb_req_tmp.vpn;
            tlb_entries[write_idx].asid <= tlb_req_tmp.asid;
            tlb_entries[write_idx].ppn <= ptw_tlb_comm_i.resp.pte.ppn;
            tlb_entries[write_idx].level <= ptw_tlb_comm_i.resp.level;
            tlb_entries[write_idx].dirty <= ptw_tlb_comm_i.resp.pte.d;
            tlb_entries[write_idx].access <= ptw_tlb_comm_i.resp.pte.a;
            tlb_entries[write_idx].perms.ur <= ptw_tlb_comm_i.resp.pte.r & ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v; 
            tlb_entries[write_idx].perms.uw <= ptw_tlb_comm_i.resp.pte.w & ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v;
            tlb_entries[write_idx].perms.ux <= ptw_tlb_comm_i.resp.pte.x & ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v;
            tlb_entries[write_idx].perms.sr <= ptw_tlb_comm_i.resp.pte.r & !ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v;
            tlb_entries[write_idx].perms.sw <= ptw_tlb_comm_i.resp.pte.w & !ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v;
            tlb_entries[write_idx].perms.sx <= ptw_tlb_comm_i.resp.pte.x & !ptw_tlb_comm_i.resp.pte.u & ptw_tlb_comm_i.resp.pte.v;
            tlb_entries[write_idx].valid <= !ptw_tlb_comm_i.resp.error;
            tlb_entries[write_idx].nempty <= 1'b1;
        end
    end
end

// CAM, TLB READ LOGIC
///////////////////////////////

logic [TLB_ENTRIES-1:0] hits_g, hits_m, hits_k, hits_cam;
logic hit_g, hit_m, hit_k, hit_cam;
logic [TLB_IDX_SIZE-1:0] hit_idx;

logic [VPN_SIZE:0] cache_vpn;
assign cache_vpn = cache_tlb_comm_i.req.vpn;
logic [ASID_SIZE-1:0] cache_asid;
assign cache_asid = cache_tlb_comm_i.req.asid;

always_comb begin
    int i;
    for (i = 0; i < TLB_ENTRIES; i++) begin
        hits_g[i] = ((tlb_entries[i].vpn[26:18] == cache_vpn[26:18]) && (tlb_entries[i].asid == cache_asid) && tlb_entries[i].nempty && (tlb_entries[i].level == GIGA_PAGE)) ? 1'b1 : 1'b0;
        hits_m[i] = ((tlb_entries[i].vpn[26:9] == cache_vpn[26:9]) && (tlb_entries[i].asid == cache_asid) && tlb_entries[i].nempty && (tlb_entries[i].level == MEGA_PAGE)) ? 1'b1 : 1'b0;
        hits_k[i] = ((tlb_entries[i].vpn == cache_vpn[26:0]) && (tlb_entries[i].asid == cache_asid) && tlb_entries[i].nempty && (tlb_entries[i].level == KILO_PAGE)) ? 1'b1 : 1'b0;
    end
end
assign hits_cam = hits_g | hits_m | hits_k; 
assign hit_k = |hits_k;
assign hit_m = |hits_m;
assign hit_g = |hits_g;
assign hit_cam = |hits_cam;

// encodes the hit index
logic found;
always_comb begin
    hit_idx = '0; // don't care if no 'in' bits set
    found = 0;
    for (int i = 0; (i < TLB_ENTRIES) && (!found); i++) begin
        if (hits_cam[i]==1'b1) begin
            hit_idx = trunc_tlb_idx_size($unsigned(i));
            found = 1;
        end
    end
end

// HIT LOGIC
///////////////////////////////

logic tlb_hit, tlb_miss, store_hit, vm_enable, tlb_entry_access_is_zero, tlb_entry_dirty_is_zero, passthrough;

logic read_ok, write_ok, exec_ok, sv_priv_lvl; 

assign vm_enable = cache_tlb_comm_i.vm_enable;
assign passthrough = cache_tlb_comm_i.req.passthrough;

assign tlb_entry_access_is_zero = !tlb_entries[hit_idx].access && tlb_entries[hit_idx].valid;
assign tlb_entry_dirty_is_zero = !store_hit && tlb_entries[hit_idx].valid;

assign tlb_hit = vm_enable && hit_cam && store_hit;
assign tlb_miss = vm_enable && !(hit_cam);

always_comb begin
    if (cache_tlb_comm_i.req.store) begin
        if(tlb_entries[hit_idx].dirty) begin // dirty 
            store_hit = 1'b1;
        end else if (!write_ok) begin 
            store_hit = 1'b1;
        end else begin 
            store_hit = 1'b0;
        end     
    end else begin 
        store_hit = 1'b1;
    end
end

// EVICTION MECHANISM
///////////////////////////////
logic has_invalid_entry, access_hit;
logic unsigned [TLB_IDX_SIZE-1:0] eviction_idx, invalid_idx, plru_eviction_idx;

assign access_hit = tlb_hit & cache_tlb_comm_i.req.valid;

pseudoLRU #(.ENTRIES(TLB_ENTRIES)) tlb_PLRU (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .access_hit_i(access_hit),
    .access_idx_i(hit_idx),
    .replacement_idx_o(plru_eviction_idx)
);

// Detect and identify if and entry is not being used
always_comb begin
    invalid_idx = '0;
    has_invalid_entry = ~tlb_entries[invalid_idx].nempty;
    while (!has_invalid_entry && (invalid_idx != $unsigned(TLB_ENTRIES-1))) begin
        invalid_idx = trunc_tlb_idx_size_4in(invalid_idx + 1'b1);
        has_invalid_entry = ~tlb_entries[invalid_idx].nempty;
    end
end

assign eviction_idx = has_invalid_entry ? invalid_idx : plru_eviction_idx;


logic clean_tlb; 
always_comb begin
    clear_tlb = 1'b0;
    clear_mask = '0;
    if (ptw_tlb_comm_i.invalidate_tlb) begin 
        clear_tlb = 1'b1;
        clear_mask = 'hFF;
    end else if (clean_tlb) begin 
        clear_tlb = 1'b1;
        for (int i=0; i<TLB_ENTRIES; ++i) begin
            if (!tlb_entries[i].valid || (($unsigned(i) == hit_idx) && hit_cam && !store_hit)) begin
                clear_mask[i] = 1'b1; 
            end 
        end
    end
end

// TLB FSM,  TLB miss 
///////////////////////////////

typedef enum logic [1:0] {
    IDLE,
    SEND_REQUEST,
    WAIT_RESPONSE,
    INVALIDATED_WAIT_RESPONSE
} ptw_state;

ptw_state current_state, next_state;
logic store_tlb_req, send_tlb_req, tlb_ready;
logic pmu_tlb_access, pmu_tlb_miss;
tlb_req_tmp_storage_t tlb_req_tmp;

always_comb begin
    store_tlb_req = 1'b0;
    send_tlb_req = 1'b0;
    write_tlb = 1'b0;
    clean_tlb = 1'b0;
    tlb_ready = 1'b0;
    pmu_tlb_access = 1'b0;
    pmu_tlb_miss = 1'b0;
    next_state = current_state; 
    case (current_state)
        IDLE : begin
            tlb_ready = 1'b1;
            if (cache_tlb_comm_i.req.valid) begin 
                clean_tlb = 1'b1; 
                pmu_tlb_access = 1'b1; 
                if (tlb_miss) begin 
                    store_tlb_req = 1'b1; 
                    pmu_tlb_miss = 1'b1; 
                    next_state = SEND_REQUEST;
                end
            end 
        end
        SEND_REQUEST : begin
            send_tlb_req = 1'b1; 
            if (!ptw_tlb_comm_i.ptw_ready && ptw_tlb_comm_i.invalidate_tlb) begin
                next_state = IDLE; 
            end else if (ptw_tlb_comm_i.ptw_ready) begin
                if (ptw_tlb_comm_i.invalidate_tlb) begin
                    next_state = INVALIDATED_WAIT_RESPONSE; 
                end else begin
                    next_state = WAIT_RESPONSE;    
                end
            end 
        end
        WAIT_RESPONSE : begin
            if (ptw_tlb_comm_i.resp.valid) begin
                write_tlb = 1'b1;
                next_state = IDLE;
            end else if (ptw_tlb_comm_i.invalidate_tlb) begin
                next_state = INVALIDATED_WAIT_RESPONSE; 
            end
        end
        INVALIDATED_WAIT_RESPONSE : begin
            if (ptw_tlb_comm_i.resp.valid) begin
                next_state = IDLE;   
            end
        end
    endcase
end

always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
        tlb_req_tmp <= '0;
    end else if (store_tlb_req) begin
        tlb_req_tmp.vpn <= cache_tlb_comm_i.req.vpn[VPN_SIZE-1:0];
        tlb_req_tmp.asid <= cache_tlb_comm_i.req.asid;
        tlb_req_tmp.store <= cache_tlb_comm_i.req.store;
        tlb_req_tmp.fetch <= cache_tlb_comm_i.req.instruction;
        tlb_req_tmp.write_idx <= eviction_idx;
    end
end

// TLB-PTW send request
always_comb begin
    if (send_tlb_req) begin
        tlb_ptw_comm_o.req.valid = 1'b1;
        tlb_ptw_comm_o.req.vpn = tlb_req_tmp.vpn;
        tlb_ptw_comm_o.req.asid = tlb_req_tmp.asid;
        tlb_ptw_comm_o.req.prv = cache_tlb_comm_i.priv_lvl; 
        tlb_ptw_comm_o.req.store = tlb_req_tmp.store;
        tlb_ptw_comm_o.req.fetch = tlb_req_tmp.fetch;
    end else begin
        tlb_ptw_comm_o.req = '0;
    end
end




// PERMISSION 检查
///////////////////////////////

assign sv_priv_lvl = (cache_tlb_comm_i.priv_lvl != '0) ? 1'b1 : 1'b0; // 不使用 supervisor

// Read permission
always_comb begin
    if (sv_priv_lvl) begin
        if (ptw_tlb_comm_i.ptw_status.sum) begin 
            if (ptw_tlb_comm_i.ptw_status.mxr) begin 
                read_ok = tlb_entries[hit_idx].perms.sr | tlb_entries[hit_idx].perms.ur | tlb_entries[hit_idx].perms.sx | tlb_entries[hit_idx].perms.ux;
            end else begin
                read_ok = tlb_entries[hit_idx].perms.sr | tlb_entries[hit_idx].perms.ur;
            end
        end else begin
            if (ptw_tlb_comm_i.ptw_status.mxr) begin 
                read_ok = tlb_entries[hit_idx].perms.sr | tlb_entries[hit_idx].perms.sx;
            end else begin
                read_ok = tlb_entries[hit_idx].perms.sr;
            end
        end
    end else begin // User mode
        if (ptw_tlb_comm_i.ptw_status.mxr) begin 
            read_ok = tlb_entries[hit_idx].perms.ur | tlb_entries[hit_idx].perms.ux;
        end else begin
            read_ok = tlb_entries[hit_idx].perms.ur;
        end
    end
end

// Write 请求
always_comb begin
    if(sv_priv_lvl) begin
        if (ptw_tlb_comm_i.ptw_status.sum) begin 
            write_ok = tlb_entries[hit_idx].perms.sw | tlb_entries[hit_idx].perms.uw;
        end else begin
            write_ok = tlb_entries[hit_idx].perms.sw;
        end
    end else begin
        write_ok = tlb_entries[hit_idx].perms.uw;
    end
end

// Execution 请求
assign exec_ok = (sv_priv_lvl) ? tlb_entries[hit_idx].perms.sx : tlb_entries[hit_idx].perms.ux;

logic xcpt_if, xcpt_st, xcpt_ld;
assign xcpt_if = (vm_enable && ((tlb_hit && !exec_ok) || tlb_entry_access_is_zero)) ? 1'b1 : 1'b0;
assign xcpt_st = (vm_enable && ((tlb_hit && !write_ok) || tlb_entry_access_is_zero || tlb_entry_dirty_is_zero)) ? 1'b1 : 1'b0;
assign xcpt_ld = (vm_enable && ((tlb_hit && !read_ok) || tlb_entry_access_is_zero)) ? 1'b1 : 1'b0;

// PPN 
///////////////////////////////

logic [PPN_SIZE-1:0] ppn_k, ppn_m, ppn_g;

assign ppn_k = tlb_entries[hit_idx].ppn;
assign ppn_m = {tlb_entries[hit_idx].ppn >> PAGE_LVL_BITS, cache_vpn[PAGE_LVL_BITS-1:0]};
assign ppn_g = {tlb_entries[hit_idx].ppn >> (PAGE_LVL_BITS * 2), cache_vpn[PAGE_LVL_BITS*2-1:0]};

// TLB 交互
///////////////////////////////

assign tlb_cache_comm_o.tlb_ready = tlb_ready; 
assign tlb_cache_comm_o.resp.miss = tlb_miss;
assign tlb_cache_comm_o.resp.ppn =
    ((ppn_k & {PPN_SIZE{hit_k & vm_enable & ~passthrough}}) | (ppn_m & {PPN_SIZE{hit_m & vm_enable & ~passthrough}})) |
    ((ppn_g & {PPN_SIZE{hit_g & vm_enable & ~passthrough}}) | {{(PPN_SIZE-VPN_SIZE-1){1'b0}}, cache_vpn & {(VPN_SIZE+1){~(vm_enable & ~passthrough)}}});
assign tlb_cache_comm_o.resp.xcpt.load = xcpt_ld;
assign tlb_cache_comm_o.resp.xcpt.store = xcpt_st;
assign tlb_cache_comm_o.resp.xcpt.fetch = xcpt_if;

assign tlb_cache_comm_o.resp.hit_idx = 'h0;

// PMU 
///////////////////////////////
assign pmu_tlb_access_o = pmu_tlb_access;
assign pmu_tlb_miss_o = pmu_tlb_miss;

endmodule
