module pmp_data_if
  import config_pkg::*;
  import mmu_pkg::*;
#(
    parameter type                   icache_areq_t = logic,
    parameter type                   exception_t   = logic
) (
    input logic clk_i,
    input logic rst_ni,
    // IF interface
    input icache_areq_t icache_areq_i,
    output icache_areq_t icache_areq_o,
    input [VLEN-1:0] icache_fetch_vaddr_i, 
    input logic lsu_valid_i,  // request lsu access
    input logic [PLEN-1:0] lsu_paddr_i,  // physical address in
    input logic [VLEN-1:0] lsu_vaddr_i,  // virtual address in, for tval only
    input exception_t lsu_exception_i,  // lsu exception coming from MMU, or misaligned exception
    input logic lsu_is_store_i,  // the translation is requested by a store
    output logic lsu_valid_o,  // translation is valid
    output logic [PLEN-1:0] lsu_paddr_o,  // translated address
    output exception_t lsu_exception_o,  // address translation threw an exception
    // General control signals
    input riscv::priv_lvl_t priv_lvl_i,
    input riscv::priv_lvl_t ld_st_priv_lvl_i,
    // PMP
    input riscv::pmpcfg_t [avoid_neg(NrPMPEntries-1):0] pmpcfg_i,
    input logic [avoid_neg(NrPMPEntries-1):0][PLEN-3:0] pmpaddr_i
);
  logic [XLEN-1:0] fetch_vaddr_xlen, lsu_vaddr_xlen;

  logic pmp_if_allow;
  logic match_any_execute_region;
  logic data_allow_o;

  riscv::pmp_access_t pmp_access_type;

  logic no_locked_data, no_locked_if;


  assign lsu_vaddr_xlen   = lsu_vaddr_i[XLEN-1:0];
  assign fetch_vaddr_xlen = icache_fetch_vaddr_i[XLEN-1:0];


  //-----------------------
  // Instruction Interface
  //-----------------------
  assign match_any_execute_region = config_pkg::is_inside_execute_regions(
        {{64 - PLEN{1'b0}}, icache_areq_i.fetch_paddr}
  );

  always_comb begin : instr_interface
    icache_areq_o.fetch_valid     = icache_areq_i.fetch_valid;
    icache_areq_o.fetch_paddr     = icache_areq_i.fetch_paddr;
    icache_areq_o.fetch_exception = icache_areq_i.fetch_exception;

    if (!match_any_execute_region || !pmp_if_allow) begin
      icache_areq_o.fetch_exception.cause = INSTR_ACCESS_FAULT;
      icache_areq_o.fetch_exception.valid = 1'b1;
      icache_areq_o.fetch_exception.tval = fetch_vaddr_xlen;

    end
  end

  // Instruction fetch
  pmp i_pmp_if (
      .addr_i       (icache_areq_i.fetch_paddr),
      .priv_lvl_i   (priv_lvl_i),
      .access_type_i(ACCESS_EXEC),
      .conf_addr_i  (pmpaddr_i),
      .conf_i       (pmpcfg_i),
      .allow_o      (pmp_if_allow)
  );

  //-----------------------
  // Data Interface
  //-----------------------
  always_comb begin : data_interface
    // save request and DTLB response
    lsu_valid_o     = lsu_valid_i;
    lsu_paddr_o     = lsu_paddr_i;
    lsu_exception_o = lsu_exception_i;
    pmp_access_type = lsu_is_store_i ? ACCESS_WRITE : ACCESS_READ;

    // If translation is not enabled, check the paddr immediately against PMPs
    if (lsu_valid_i && !data_allow_o) begin
      lsu_exception_o.valid = 1'b1;
      lsu_exception_o.tval = lsu_vaddr_xlen;

      if (lsu_is_store_i) begin
        lsu_exception_o.cause = riscv::ST_ACCESS_FAULT;
      end else begin
        lsu_exception_o.cause = riscv::LD_ACCESS_FAULT;
      end

    end
  end

  // Load/store PMP check
  pmp  i_pmp_data (
      .addr_i       (lsu_paddr_i),
      .priv_lvl_i   (ld_st_priv_lvl_i),
      .access_type_i(pmp_access_type),
      // Configuration
      .conf_addr_i  (pmpaddr_i),
      .conf_i       (pmpcfg_i),
      .allow_o      (data_allow_o)
  );

  // ----------------
  // Assert for PMPs
  // ----------------

  // synthesis translate_off
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      no_locked_data <= 1'b0;
    end else begin
      if (ld_st_priv_lvl_i == PRIV_LVL_M) begin
        no_locked_data <= 1'b1;
        for (int i = 0; i < NrPMPEntries; i++) begin
          if (pmpcfg_i[i].locked && pmpcfg_i[i].addr_mode != OFF) begin
            no_locked_data <= no_locked_data & 1'b0;
          end else no_locked_data <= no_locked_data & 1'b1;
        end
        if (no_locked_data == 1'b1) assert (data_allow_o == 1'b1);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      no_locked_if <= 1'b0;
    end else begin
      if (priv_lvl_i == PRIV_LVL_M) begin
        no_locked_if <= 1'b1;
        for (int i = 0; i < NrPMPEntries; i++) begin
          if (pmpcfg_i[i].locked && pmpcfg_i[i].addr_mode != OFF) begin
            no_locked_if <= no_locked_if & 1'b0;
          end else no_locked_if <= no_locked_if & 1'b1;
        end
        if (no_locked_if == 1'b1) assert (pmp_if_allow == 1'b1);
      end
    end
  end
endmodule
