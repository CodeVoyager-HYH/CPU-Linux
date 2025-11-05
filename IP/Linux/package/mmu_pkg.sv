package mmu_pkg;

// SV39 Parameters
parameter VPN_SIZE = 27;
parameter PPN_SIZE = 27;
parameter SIZE_VADDR = 39;
parameter ASID_SIZE = 7;
parameter LEVELS = 3;
parameter PAGE_LVL_BITS = 9;
parameter PTESIZE = 8;
parameter ASID_WIDTH = 16;
parameter PLEN = 56;
parameter TLB_ENTRIES = 8;
parameter TLB_IDX_SIZE = $clog2(TLB_ENTRIES);

parameter PTW_CACHE_SIZE = $clog2(LEVELS*2);
parameter PPNW =  44;
parameter [1:0] GIGA_PAGE = 2'b00;  // 1 GiB Page
parameter [1:0] MEGA_PAGE = 2'b01;  // 2 MiB Page
parameter [1:0] KILO_PAGE = 2'b10;  // 4 KiB Page

int unsigned VpnLen         = 27;
int unsigned PtLevels       = 3; 
int unsigned SharedTlbDepth = 64;
endpackage
