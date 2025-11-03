package config_pkg;

localparam longint  unsigned VLEN             = 64;
localparam longint  unsigned XLEN             = 64;
localparam int      unsigned FETCH_LEN        = 32;
localparam int      unsigned FETCH_ALIGN_BITS = $clog2(FETCH_WIDTH / 8);
localparam int      unsigned FETCH_WIDTH      = unsigned'32;
localparam int               NR_SB_ENTRIES    = 8;
localparam int               FU_LEN           = 3;// ALU FSU Brache_unit mult dev none
localparam int      unsigned XLEN_ALIGN_BYTES = $clog2(XLEN / 8);
localparam int               LOAD_BUFF_SIZE   = 8;
localparam NrPMPEntries = 16; // PMP entries 数量

  // --------------------
// 非密等区域
localparam                   NrMaxRules       = 16; // 非密等区域最大的配置数量
int unsigned                 NrNonIdempotentRules;  // 非幂等区域的规则数量
logic [NrMaxRules-1:0][63:0] NonIdempotentAddrBase; // 地址起始
logic [NrMaxRules-1:0][63:0] NonIdempotentLength;   // 地址范围
localparam                   POINTER_SIZE     = $clog2(NR_SB_ENTRIES);

// 定义 RISC-V 特权级别
typedef enum logic [1:0] {
    PRIV_LVL_M  = 2'b11,
    PRIV_LVL_HS = 2'b10,
    PRIV_LVL_S  = 2'b01,
    PRIV_LVL_U  = 2'b00
  } priv_lvl_t;

  // --------------------
  // Atomics
  // --------------------
  typedef enum logic [3:0] {
    AMO_NONE = 4'b0000,
    AMO_LR   = 4'b0001,
    AMO_SC   = 4'b0010,
    AMO_SWAP = 4'b0011,
    AMO_ADD  = 4'b0100,
    AMO_AND  = 4'b0101,
    AMO_OR   = 4'b0110,
    AMO_XOR  = 4'b0111,
    AMO_MAX  = 4'b1000,
    AMO_MAXU = 4'b1001,
    AMO_MIN  = 4'b1010,
    AMO_MINU = 4'b1011,
    AMO_CAS1 = 4'b1100,  // unused, not part of riscv spec, but provided in OpenPiton
    AMO_CAS2 = 4'b1101   // unused, not part of riscv spec, but provided in OpenPiton
  } amo_t;

  // 函数 用于32位值进行符号扩展
  function automatic logic [63:0] sext32to64(logic [31:0] operand);
    return {{32{operand[31]}}, operand[31:0]};
  endfunction
  
  function automatic logic [1:0] extract_transfer_size(fu_op op);
    case (op)
      LD, HLV_D, SD, HSV_D, FLD, FSD,
            AMO_LRD,   AMO_SCD,
            AMO_SWAPD, AMO_ADDD,
            AMO_ANDD,  AMO_ORD,
            AMO_XORD,  AMO_MAXD,
            AMO_MAXDU, AMO_MIND,
            AMO_MINDU: begin
        return 2'b11;
      end
      LW, LWU, HLV_W, HLV_WU, HLVX_WU,
            SW, HSV_W, FLW, FSW,
            AMO_LRW,   AMO_SCW,
            AMO_SWAPW, AMO_ADDW,
            AMO_ANDW,  AMO_ORW,
            AMO_XORW,  AMO_MAXW,
            AMO_MAXWU, AMO_MINW,
            AMO_MINWU: begin
        return 2'b10;
      end
      LH, LHU, HLV_H, HLV_HU, HLVX_HU, SH, HSV_H, FLH, FSH: return 2'b01;
      LB, LBU, HLV_B, HLV_BU, SB, HSV_B, FLB, FSB:          return 2'b00;
      default:                                              return 2'b11;
    endcase
  endfunction

  function automatic logic range_check(logic [63:0] base, logic [63:0] len, logic [63:0] address);
    return (address >= base) && (({1'b0, address}) < (65'(base) + len));
  endfunction : range_check

  function automatic logic is_inside_nonidempotent_regions( logic [63:0] address);
    logic [NrMaxRules-1:0] pass;    // 存储每个规则的检查结果（1表示地址命中该区域）
    pass = '0;

    // 遍历所有非幂等区域规则，检查地址是否落在该区域内
    for (int unsigned k = 0; k < NrNonIdempotentRules; k++) begin
      // 调用 range_check 函数，判断 address 是否在 [Base, Base+Length) 范围内
      pass[k] = range_check(NonIdempotentAddrBase[k], NonIdempotentLength[k], address);
    end
    return |pass;
  endfunction : is_inside_nonidempotent_regions

  typedef enum logic [2:0] {
    NoCF,    // No control flow prediction
    Branch,  // Branch
    Jump,    // Jump to address from immediate
    JumpR,   // Jump to address from registers
    Return   // Return Address Prediction
  } cf_t;

  typedef enum logic [3:0] {
    NONE,       // 0
    LOAD,       // 1
    STORE,      // 2
    ALU,        // 3
    CTRL_FLOW,  // 4
    MULT,       // 5
    CSR,        // 6
    FPU,        // 7
    FPU_VEC,    // 8
    CVXIF,      // 9
    ACCEL,      // 10
    AES         // 11
  } fu_t;

  typedef enum logic [7:0] {  // basic ALU op
    ADD,
    SUB,
    ADDW,
    SUBW,
    // logic operations
    XORL,
    ORL,
    ANDL,
    // shifts
    SRA,
    SRL,
    SLL,
    SRLW,
    SLLW,
    SRAW,
    // comparisons
    LTS,
    LTU,
    GES,
    GEU,
    EQ,
    NE,
    // jumps
    JALR,
    BRANCH,
    // set lower than operations
    SLTS,
    SLTU,
    // CSR functions
    MRET,
    SRET,
    DRET,
    ECALL,
    WFI,
    FENCE,
    FENCE_I,
    SFENCE_VMA,
    HFENCE_VVMA,
    HFENCE_GVMA,
    CSR_WRITE,
    CSR_READ,
    CSR_SET,
    CSR_CLEAR,
    // LSU functions
    LD,
    SD,
    LW,
    LWU,
    SW,
    LH,
    LHU,
    SH,
    LB,
    SB,
    LBU,
    // Hypervisor Virtual-Machine Load and Store Instructions
    HLV_B,
    HLV_BU,
    HLV_H,
    HLV_HU,
    HLVX_HU,
    HLV_W,
    HLVX_WU,
    HSV_B,
    HSV_H,
    HSV_W,
    HLV_WU,
    HLV_D,
    HSV_D,
    // Atomic Memory Operations
    AMO_LRW,
    AMO_LRD,
    AMO_SCW,
    AMO_SCD,
    AMO_SWAPW,
    AMO_ADDW,
    AMO_ANDW,
    AMO_ORW,
    AMO_XORW,
    AMO_MAXW,
    AMO_MAXWU,
    AMO_MINW,
    AMO_MINWU,
    AMO_SWAPD,
    AMO_ADDD,
    AMO_ANDD,
    AMO_ORD,
    AMO_XORD,
    AMO_MAXD,
    AMO_MAXDU,
    AMO_MIND,
    AMO_MINDU,
    // Multiplications
    MUL,
    MULH,
    MULHU,
    MULHSU,
    MULW,
    // Divisions
    DIV,
    DIVU,
    DIVW,
    DIVUW,
    REM,
    REMU,
    REMW,
    REMUW,
    // Floating-Point Load and Store Instructions
    FLD,
    FLW,
    FLH,
    FLB,
    FSD,
    FSW,
    FSH,
    FSB,
    // Floating-Point Computational Instructions
    FADD,
    FSUB,
    FMUL,
    FDIV,
    FMIN_MAX,
    FSQRT,
    FMADD,
    FMSUB,
    FNMSUB,
    FNMADD,
    // Floating-Point Conversion and Move Instructions
    FCVT_F2I,
    FCVT_I2F,
    FCVT_F2F,
    FSGNJ,
    FMV_F2X,
    FMV_X2F,
    // Floating-Point Compare Instructions
    FCMP,
    // Floating-Point Classify Instruction
    FCLASS,
    // Vectorial Floating-Point Instructions that don't directly map onto the scalar ones
    VFMIN,
    VFMAX,
    VFSGNJ,
    VFSGNJN,
    VFSGNJX,
    VFEQ,
    VFNE,
    VFLT,
    VFGE,
    VFLE,
    VFGT,
    VFCPKAB_S,
    VFCPKCD_S,
    VFCPKAB_D,
    VFCPKCD_D,
    // Offload Instructions to be directed into cv_x_if
    OFFLOAD,
    // Or-Combine and REV8
    ORCB,
    REV8,
    // Bitwise Rotation
    ROL,
    ROLW,
    ROR,
    RORI,
    RORIW,
    RORW,
    // Sign and Zero Extend
    SEXTB,
    SEXTH,
    ZEXTH,
    // Count population
    CPOP,
    CPOPW,
    // Count Leading/Training Zeros
    CLZ,
    CLZW,
    CTZ,
    CTZW,
    // Carry less multiplication Op's
    CLMUL,
    CLMULH,
    CLMULR,
    // Single bit instructions Op's
    BCLR,
    BCLRI,
    BEXT,
    BEXTI,
    BINV,
    BINVI,
    BSET,
    BSETI,
    // Integer minimum/maximum
    MAX,
    MAXU,
    MIN,
    MINU,
    // Shift with Add Unsigned Word and Unsigned Word Op's (Bitmanip)
    SH1ADDUW,
    SH2ADDUW,
    SH3ADDUW,
    ADDUW,
    SLLIUW,
    // Shift with Add (Bitmanip)
    SH1ADD,
    SH2ADD,
    SH3ADD,
    // Bitmanip Logical with negate op (Bitmanip)
    ANDN,
    ORN,
    XNOR,
    // Accelerator operations
    ACCEL_OP,
    ACCEL_OP_FS1,
    ACCEL_OP_FD,
    ACCEL_OP_LOAD,
    ACCEL_OP_STORE,
    // Zicond instruction
    CZERO_EQZ,
    CZERO_NEZ,
    // Pack instructions
    PACK,
    PACK_H,
    PACK_W,
    // Brev8 instruction
    BREV8,
    // Zip instructions
    UNZIP,
    ZIP,
    // Xperm instructions
    XPERM8,
    XPERM4,
    // AES Encryption instructions
    AES32ESI,
    AES32ESMI,
    AES64ES,
    AES64ESM,
    // AES Decryption instructions
    AES32DSI,
    AES32DSMI,
    AES64DS,
    AES64DSM,
    AES64IM,
    // AES Key-Schedule instructions
    AES64KS1I,
    AES64KS2,
    // Hashing instructions
    SHA256SIG0,
    SHA256SIG1,
    SHA256SUM0,
    SHA256SUM1,
    SHA512SIG0H,
    SHA512SIG0L,
    SHA512SIG1H,
    SHA512SIG1L,
    SHA512SUM0R,
    SHA512SUM1R,
    SHA512SIG0,
    SHA512SIG1,
    SHA512SUM0,
    SHA512SUM1
  } fu_op;

endpackage
