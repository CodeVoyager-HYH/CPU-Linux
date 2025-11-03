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

typedef struct packed {
    logic x;
    logic w;
    logic r;
} pmpcfg_access_t;

typedef enum logic [1:0] {
    // 禁用pmp表项目
    OFF   = 2'b00,  
    // 区域 X 的结束地址紧邻下一区域的基地址寄存器 pmpaddrX 的值。
    // 该地址区域可表示为 [pmpaddr(X-1), pmpaddrX)。特别的，PMP 条目 0 表示的地址区域为 [0, pmpaddr0)。
    // 如果 pmpaddri−1 ≥ pmpaddri，则 PMP 条目 i 不匹配任何地址，即区域为空
    TOR   = 2'b01,  
    // 4字节大小区域
    NA4   = 2'b10,  
    // 2的幂次方大小区域 大小至少大于8字节
    NAPOT = 2'b11   
} pmp_addr_mode_t;

// packed struct of a PMP configuration register (8bit)
typedef struct packed {
    logic           locked;       // L字段，如果为1，则M模式也需要检查PMP
    logic [1:0]     reserved;
    pmp_addr_mode_t addr_mode;    // Off, TOR, NA4, NAPOT
    pmpcfg_access_t access_type;
} pmpcfg_t;


typedef struct packed {
    logic [PPN_SIZE-1:0] ppn; 
    logic [1:0] rfs;
    logic d;
    logic a;
    logic g;
    logic u;
    logic x;
    logic w;
    logic r;
    logic v;
} pte_t;

typedef struct packed {
    logic        sd    ;
    logic [26:0] zero5 ;
    logic [1:0]  sxl   ;
    logic [1:0]  uxl   ;
    logic [8:0]  zero4 ;
    logic        tsr   ;
    logic        tw    ;
    logic        tvm   ;
    logic        mxr   ;
    logic        sum   ;
    logic        mprv  ;
    logic [1:0]  xs    ;
    logic [1:0]  fs    ;
    logic [1:0]  mpp   ;
    logic [1:0]  zero3 ;
    logic        spp   ;  
    logic        mpie  ;
    logic        zero2 ;
    logic        spie  ;
    logic        upie  ;
    logic        mie   ;
    logic        zero1 ;
    logic        sie   ;
    logic        uie   ;
} csr_mstatus_t;

////////////////////////////////      
//
//  Cache-TLB communication
//
///////////////////////////////   

// Cache-TLB request
typedef struct packed {
    logic                 valid;        // Translation request valid.
    logic [ASID_SIZE-1:0] asid;         // Address space identifier.
    logic [VPN_SIZE:0]    vpn;          // Virtual page number.
    logic                 passthrough;  // Virtual address directly corresponds to physical address, for direct assignment between a virtual machine and the physical device.
    logic                 instruction;  // The translation request is for a instruction fetch address.
    logic                 store;        // The translation request is for a store address.
} cache_tlb_req_t;                      // Translation request.

typedef struct packed {
    cache_tlb_req_t req;            // Translation request.
    logic [1:0]     priv_lvl;       // Privilege level of the translation: 2'b00 (User), 2'b01 (Supervisor), 2'b11 (Machine).
    logic           vm_enable;      // Memory virtualization is active.
} cache_tlb_comm_t;                 // Communication from translation requester to TLB.

typedef struct packed {
    logic load;                     // Load operation.
    logic store;                    // Store operation.
    logic fetch;                    // Fetch operation.
} tlb_ex_t;                         // Exception origin.

// TLB-Cache response
typedef struct packed { 
    logic                miss;      // If the translation request missed set to 1 Otherwise, the rest of the signals have valid information of the response.
    logic [PPN_SIZE-1:0] ppn;       // Physical page number.
    tlb_ex_t             xcpt;      // Exceptions produced by the requests.
    logic [7:0]          hit_idx;   // CAM hit index of the translation request.
} tlb_cache_resp_t;                 // Translation response.

typedef struct packed {
    logic            tlb_ready;     // The tlb is ready to accept a translation request. If 0 it shouldn't receive any translation request.
    tlb_cache_resp_t resp;          // Translation response.
} tlb_cache_comm_t;                 // Communication from TLB to translation requester.

////////////////////////////////      
//
//  TLB-PTW communication
//
///////////////////////////////

// TLB-PTW request
typedef struct packed {
    logic                 valid;    // Translation request valid.
    logic [VPN_SIZE-1:0]  vpn;      // Virtual page number.
    logic [ASID_SIZE-1:0] asid;     // Address space identifier. 
    logic [1:0]           prv;      // Privilege level of the translation: 2'b00 (User), 2'b01 (Supervisor), 2'b11 (Machine).
    logic                 store;    // Store operation.               
    logic                 fetch;    // Fetch operation.
} tlb_ptw_req_t;                    // Translation request of the TLB to the PTW.

typedef struct packed {
    tlb_ptw_req_t req;              // Translation request of the TLB to the PTW.
} tlb_ptw_comm_t;                   // Communication from TLB to PTW.

// PTW-TLB response
typedef struct packed {
    logic                      valid; // Translation response valid.
    logic                      error; // An error has ocurred with the translation request. Only check if the response is valid.
    pte_t                      pte;   // Page table entry.
    logic [$clog2(LEVELS)-1:0] level; // Page entry size: 2'b00 (1 GiB Page), 2'b01 (2 MiB Page), 2'b10 (4 KiB Page). 
} ptw_tlb_resp_t;                     // PTW response to TLB translation request.

typedef struct packed {
    ptw_tlb_resp_t resp;            // PTW response to TLB translation request.
    logic          ptw_ready;       // PTW is ready to receive a translation request.
    csr_mstatus_t  ptw_status;      // mstatus csr register value, sent through the ptw.    
    logic          invalidate_tlb;  // Signal to flush all entries in TLB and don't allocate in-progress transactions with the PTW.
} ptw_tlb_comm_t;                   // Communication from to PTW to TLB.

////////////////////////////////      
//
//  TLB
//
///////////////////////////////

typedef struct packed {
    logic ur;               // User read permission.
    logic uw;               // User write permission.
    logic ux;               // User execute permission.
    logic sr;               // Supervisor read permission.
    logic sw;               // Supervisor write permission.
    logic sx;               // Supervisor execute permission.
} tlb_entry_permissions_t;  // TLB page entry permissions.

typedef struct packed {
    logic [VPN_SIZE-1:0]    vpn;    // Virtual page number.
    logic [ASID_SIZE-1:0]   asid;   // Address space identifier.
    logic [PPN_SIZE-1:0]    ppn;    // Physical page number.
    logic [1:0]             level;  // Page entry size: 2'b00 (1 GiB Page), 2'b01 (2 MiB Page), 2'b10 (4 KiB Page).
    logic                   dirty;  // The page entry is set as dirty.
    logic                   access; // The page entry has been accessed.
    tlb_entry_permissions_t perms;  // TLB page entry permissions
    logic                   valid;  // The tlb entry is valid, set to 1 when the PTW sends a translation response without errors.
    logic                   nempty; // The tlb entry is not empty, when the PTW sends a translation response that we don't have to ignore, it is set to 1.
} tlb_entry_t;                      // TLB page entry.

typedef struct packed {
    logic [VPN_SIZE-1:0]        vpn;        // Virtual page number.
    logic [ASID_SIZE-1:0]       asid;       // Address space identifier.
    logic                       store;      // Store operation.
    logic                       fetch;      // Fetch operation.
    logic [TLB_IDX_SIZE-1:0]    write_idx;  // Index where the page requested to the PTW will be stored in the TLB's CAM. 
} tlb_req_tmp_storage_t;                    // Stored information of the translation request saved on a miss.

////////////////////////////////      
//
//  PTW
//
///////////////////////////////
//
typedef struct packed {
    logic valid;
    logic [SIZE_VADDR:0] tags;
    logic [PPN_SIZE-1:0] data;
    logic [15:0] asid;
} ptw_ptecache_entry_t;

////////////////////////////////      
//
//  PTW Communications
//
///////////////////////////////

// PTW-DMEM request
typedef struct packed {
    logic                valid  ;
    logic [SIZE_VADDR:0] addr   ;
    logic [4:0]          cmd    ;
    logic [3:0]          typ    ;
    logic                kill   ;
    logic                phys   ;
    logic [63:0]         data   ;
} ptw_dmem_req_t;

typedef struct packed {
    ptw_dmem_req_t req;
} ptw_dmem_comm_t;

// PTW-DMEM response
typedef struct packed {
    logic        valid        ;
    logic [SIZE_VADDR:0] addr ;
    logic [7:0]  tag_addr     ;
    logic [4:0]  cmd          ;
    logic [3:0]  typ          ;
    logic [63:0] data         ;
    logic        nack         ;
    logic        replay       ;
    logic        has_data     ;
    logic [63:0] data_subw    ;
    logic [63:0] store_data   ;
    logic        rnvalid      ;
    logic [7:0]  rnext        ;
    logic        xcpt_ma_ld   ;
    logic        xcpt_ma_st   ;
    logic        xcpt_pf_ld   ;
    logic        xcpt_pf_st   ;
    logic        ordered      ;
} dmem_ptw_resp_t;

typedef struct packed {
    logic dmem_ready;
    dmem_ptw_resp_t resp;
} dmem_ptw_comm_t;

// CSR interface

typedef struct packed {
    logic [63:0] satp;
    logic flush;
    csr_mstatus_t mstatus;
} csr_ptw_comm_t;

endpackage
