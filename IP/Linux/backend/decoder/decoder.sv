// 指令集IMA
module decoder #(
  parameter type branchpredict_sbe_t = logic,
  parameter type scoreboard_entry_t  = logic
) (
  input   logic [config_pkg::VLEN-1:0]  pc_i,
  input   logic [31:0]                  instruction_i,
  input   branchpredict_sbe_t           branch_predict_i,
  input   priv_lvl_t                    priv_lvl_i,
  input   logic                         tw_i, 


  input   exception_t                   ex_i,
  input   irq_ctrl_t                    irq_ctrl_i,
  input   logic [1:0]                   irq_i,
  input   logic                         tsr_i, // Sret 的trap
  input   logic                         tvm_i,
  
  output  scoreboard_entry_t            instruction_o,
  output  logic                         is_control_flow_instr_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [4:0] funct5;
  logic [6:0] funct7;
  logic [4:0] rs1_idx;
  logic [4:0] rs2_idx;
  logic [4:0] rd_idx;
  logic [config_pkg::XLEN-1:0] imm;

  logic illegal_instr;
  logic illegal_instr_non_bm;
  logic virtual_illegal_instr;

  logic [config_pkg::XLEN-1:0] imm_i_type;
  logic [config_pkg::XLEN-1:0] imm_s_type;
  logic [config_pkg::XLEN-1:0] imm_sb_type;
  logic [config_pkg::XLEN-1:0] imm_u_type;
  logic [config_pkg::XLEN-1:0] imm_uj_type;

  logic ecall;
  logic ebreak;

  enum logic [3:0] {
    NOIMM,
    IIMM,
    SIMM,
    SBIMM,
    UIMM,
    JIMM
  } imm_select;

  assign opcode  = instruction_i [ 6: 0];
  assign funct3  = instruction_i [14:12];
  assign funct5  = instruction_i [31:27];
  assign funct7  = instruction_i [31:25];
  assign rs1_idx = instruction_i [19:15];
  assign rs2_idx = instruction_i [24:20];
  assign rd_idx  = instruction_i [11: 7];

  always_comb begin
    imm_select                             = NOIMM;
    is_control_flow_instr_o                = 1'b0;
    illegal_instr                          = 1'b0;
    illegal_instr_non_bm                   = 1'b0;
    virtual_illegal_instr                  = 1'b0;
    instruction_o.pc                       = pc_i;
    instruction_o.trans_id                 = '0;
    instruction_o.fu                       = NONE;
    instruction_o.op                       = ariane_pkg::ADD;
    instruction_o.rs1                      = '0;
    instruction_o.rs2                      = '0;
    instruction_o.rd                       = '0;
    instruction_o.use_pc                   = 1'b0;
    instruction_o.use_zimm                 = 1'b0;
    instruction_o.bp                       = branch_predict_i;
    ecall                                  = 1'b0;
    ebreak                                 = 1'b0;

    
    if (~ex_i.valid) begin  // 因为如果有异常，先处理异常指令
      case (instr.rtype.opcode)
        riscv::OpcodeSystem: begin
          instruction_o.fu = CSR;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rs2 = instr.rtype.rs2;   
          instruction_o.rd = instr.itype.rd;

          unique case (instr.itype.funct3)
            3'b000: begin
              // check if the RD and and RS1 fields are zero, this may be reset for the SFENCE.VMA instruction
              if (instr.itype.rs1 != '0 || instr.itype.rd != '0) begin
                illegal_instr = 1'b1;
              end
              case (instr.itype.imm)
                // ECALL 
                12'b0: ecall = 1'b1;
                // EBREAK
                12'b1: ebreak = 1'b1;
                // SRET
                12'b1_0000_0010: begin
                    instruction_o.op = ariane_pkg::SRET;  // 只能S，M模式使用
                    if (priv_lvl_i == riscv::PRIV_LVL_U) begin
                      illegal_instr = 1'b1;
                    end
                    if (priv_lvl_i == riscv::PRIV_LVL_S && tsr_i) begin
                      illegal_instr = 1'b1;
                    end
                end
                // MRET
                12'b11_0000_0010: begin
                  instruction_o.op = ariane_pkg::MRET;  // 只能在M模式
                  if ((priv_lvl_i == riscv::PRIV_LVL_S) || (priv_lvl_i == riscv::PRIV_LVL_U))
                    illegal_instr = 1'b1;
                end
                // WFI TODO:目前未支持U模式使用WFI
                12'b1_0000_0101: begin
                  instruction_o.op = ariane_pkg::WFI;
                  if (priv_lvl_i == riscv::PRIV_LVL_S && tw_i) begin
                    illegal_instr = 1'b1;
                    instruction_o.op = ariane_pkg::ADD;
                  end
                  if (priv_lvl_i == riscv::PRIV_LVL_U) begin
                    illegal_instr = 1'b1;
                    instruction_o.op = ariane_pkg::ADD;
                  end
                end
                // SFENCE.VMA
                default: begin
                  if (instr.instr[31:25] == 7'b1001) begin
                    illegal_instr    = ((priv_lvl_i inside {riscv::PRIV_LVL_M, riscv::PRIV_LVL_S}) && instr.itype.rd == '0) ? 1'b0 : 1'b1;
                    instruction_o.op = ariane_pkg::SFENCE_VMA;
                    // check TVM flag and intercept SFENCE.VMA call if necessary
                    if (priv_lvl_i == riscv::PRIV_LVL_S && tvm_i) begin
                      illegal_instr = 1'b1;
                    end
                  end
                  else
                    illegal_instr = 1'b1;
                end
              endcase
            end
            // atomically swaps values in the CSR and integer register
            3'b001: begin  // CSRRW
              imm_select = IIMM;
              instruction_o.op = ariane_pkg::CSR_WRITE;
            end
            // atomically set values in the CSR and write back to rd
            3'b010: begin  // CSRRS
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_SET;
            end
            // atomically clear values in the CSR and write back to rd
            3'b011: begin  // CSRRC
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_CLEAR;
            end
            // use zimm and iimm
            3'b101: begin  // CSRRWI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              instruction_o.op = ariane_pkg::CSR_WRITE;
            end
            3'b110: begin  // CSRRSI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == 5'b0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_SET;
            end
            3'b111: begin  // CSRRCI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_CLEAR;
            end
            default: illegal_instr = 1'b1;
          endcase
        end
        // Memory ordering instructions
        riscv::OpcodeMiscMem: begin
          instruction_o.fu  = CSR;
          instruction_o.rs1 = '0;
          instruction_o.rs2 = '0;
          instruction_o.rd  = '0;

          case (instr.stype.funct3)
            // FENCE
            // Currently implemented as a whole DCache flush boldly ignoring other things
            3'b000: instruction_o.op = ariane_pkg::FENCE;
            // FENCE.I
            3'b001: instruction_o.op = ariane_pkg::FENCE_I;

            default: illegal_instr = 1'b1;
          endcase
        end

        // --------------------------
        // Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp: begin
            instruction_o.fu = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
            instruction_o.rs1 = instr.rtype.rs1;
            instruction_o.rs2 = instr.rtype.rs2;
            instruction_o.rd  = instr.rtype.rd;

            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : instruction_o.op = ariane_pkg::ADD;  // Add
              {7'b010_0000, 3'b000} : instruction_o.op = ariane_pkg::SUB;  // Sub
              {7'b000_0000, 3'b010} : instruction_o.op = ariane_pkg::SLTS;  // Set Lower Than
              {
                7'b000_0000, 3'b011
              } :
              instruction_o.op = ariane_pkg::SLTU;  // Set Lower Than Unsigned
              {7'b000_0000, 3'b100} : instruction_o.op = ariane_pkg::XORL;  // Xor
              {7'b000_0000, 3'b110} : instruction_o.op = ariane_pkg::ORL;  // Or
              {7'b000_0000, 3'b111} : instruction_o.op = ariane_pkg::ANDL;  // And
              {7'b000_0000, 3'b001} : instruction_o.op = ariane_pkg::SLL;  // Shift Left Logical
              {7'b000_0000, 3'b101} : instruction_o.op = ariane_pkg::SRL;  // Shift Right Logical
              {7'b010_0000, 3'b101} : instruction_o.op = ariane_pkg::SRA;  // Shift Right Arithmetic
              // Multiplications
              {7'b000_0001, 3'b000} : instruction_o.op = ariane_pkg::MUL;
              {7'b000_0001, 3'b001} : instruction_o.op = ariane_pkg::MULH;
              {7'b000_0001, 3'b010} : instruction_o.op = ariane_pkg::MULHSU;
              {7'b000_0001, 3'b011} : instruction_o.op = ariane_pkg::MULHU;
              {7'b000_0001, 3'b100} : instruction_o.op = ariane_pkg::DIV;
              {7'b000_0001, 3'b101} : instruction_o.op = ariane_pkg::DIVU;
              {7'b000_0001, 3'b110} : instruction_o.op = ariane_pkg::REM;
              {7'b000_0001, 3'b111} : instruction_o.op = ariane_pkg::REMU;
              default: begin
                illegal_instr_non_bm = 1'b1;
              end
            endcase
        end

        // --------------------------
        // 32bit Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp32: begin
          instruction_o.fu  = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
          instruction_o.rs1 = instr.rtype.rs1;
          instruction_o.rs2 = instr.rtype.rs2;
          instruction_o.rd  = instr.rtype.rd;
            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : instruction_o.op = ariane_pkg::ADDW;  // addw
              {7'b010_0000, 3'b000} : instruction_o.op = ariane_pkg::SUBW;  // subw
              {7'b000_0000, 3'b001} : instruction_o.op = ariane_pkg::SLLW;  // sllw
              {7'b000_0000, 3'b101} : instruction_o.op = ariane_pkg::SRLW;  // srlw
              {7'b010_0000, 3'b101} : instruction_o.op = ariane_pkg::SRAW;  // sraw
              // Multiplications
              {7'b000_0001, 3'b000} : instruction_o.op = ariane_pkg::MULW;
              {7'b000_0001, 3'b100} : instruction_o.op = ariane_pkg::DIVW;
              {7'b000_0001, 3'b101} : instruction_o.op = ariane_pkg::DIVUW;
              {7'b000_0001, 3'b110} : instruction_o.op = ariane_pkg::REMW;
              {7'b000_0001, 3'b111} : instruction_o.op = ariane_pkg::REMUW;
              default: illegal_instr_non_bm = 1'b1;
            endcase
            illegal_instr = illegal_instr_non_bm;
        end
        // --------------------------------
        // Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm: begin
          instruction_o.fu = ALU;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          unique case (instr.itype.funct3)
            3'b000: instruction_o.op = ariane_pkg::ADD;  // Add Immediate
            3'b010: instruction_o.op = ariane_pkg::SLTS;  // Set to one if Lower Than Immediate
            3'b011:
            instruction_o.op = ariane_pkg::SLTU;  // Set to one if Lower Than Immediate Unsigned
            3'b100: instruction_o.op = ariane_pkg::XORL;  // Exclusive Or with Immediate
            3'b110: instruction_o.op = ariane_pkg::ORL;  // Or with Immediate
            3'b111: instruction_o.op = ariane_pkg::ANDL;  // And with Immediate

            3'b001: begin
              instruction_o.op = ariane_pkg::SLL;  // Shift Left Logical by Immediate
              if (instr.instr[31:26] != 6'b0) illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && CVA6Cfg.XLEN == 32) illegal_instr_non_bm = 1'b1;
            end

            3'b101: begin
              if (instr.instr[31:26] == 6'b0)
                instruction_o.op = ariane_pkg::SRL;  // Shift Right Logical by Immediate
              else if (instr.instr[31:26] == 6'b010_000)
                instruction_o.op = ariane_pkg::SRA;  // Shift Right Arithmetically by Immediate
              else illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && CVA6Cfg.XLEN == 32) illegal_instr_non_bm = 1'b1;
            end
          endcase
            illegal_instr = illegal_instr_non_bm;
        end

        // --------------------------------
        // 32 bit Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm32: begin
          instruction_o.fu = ALU;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          if (CVA6Cfg.IS_XLEN64) begin
            unique case (instr.itype.funct3)
              3'b000:  instruction_o.op = ariane_pkg::ADDW;  // Add Immediate
              3'b001: begin
                instruction_o.op = ariane_pkg::SLLW;  // Shift Left Logical by Immediate
                if (instr.instr[31:25] != 7'b0) illegal_instr_non_bm = 1'b1;
              end
              3'b101: begin
                if (instr.instr[31:25] == 7'b0)
                  instruction_o.op = ariane_pkg::SRLW;  // Shift Right Logical by Immediate
                else if (instr.instr[31:25] == 7'b010_0000)
                  instruction_o.op = ariane_pkg::SRAW;  // Shift Right Arithmetically by Immediate
                else illegal_instr_non_bm = 1'b1;
              end
              default: illegal_instr_non_bm = 1'b1;
            endcase
              illegal_instr = illegal_instr_non_bm;

          end else illegal_instr = 1'b1;
        end
        // --------------------------------
        // LSU
        // --------------------------------
        riscv::OpcodeStore: begin
          instruction_o.fu = STORE;
          imm_select = SIMM;
          instruction_o.rs1 = instr.stype.rs1;
          instruction_o.rs2 = instr.stype.rs2;
          // determine store size
          unique case (instr.stype.funct3)
            3'b000: instruction_o.op = ariane_pkg::SB;
            3'b001: instruction_o.op = ariane_pkg::SH;
            3'b010: instruction_o.op = ariane_pkg::SW;
            3'b011: instruction_o.op = ariane_pkg::SD;
          endcase
        end

        riscv::OpcodeLoad: begin
          instruction_o.fu = LOAD;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          // determine load size and signed type
          unique case (instr.itype.funct3)
            3'b000: instruction_o.op = ariane_pkg::LB;
            3'b001: instruction_o.op = ariane_pkg::LH;
            3'b010: instruction_o.op = ariane_pkg::LW;
            3'b100: instruction_o.op = ariane_pkg::LBU;
            3'b101: instruction_o.op = ariane_pkg::LHU;
            3'b110: instruction_o.op = ariane_pkg::LWU;
            3'b011: instruction_o.op = ariane_pkg::LD;
            default: illegal_instr = 1'b1;
          endcase
        end

        // ----------------------------------
        // Atomic Operations
        // ----------------------------------
        riscv::OpcodeAmo: begin
          // we are going to use the load unit for AMOs
          instruction_o.fu  = STORE;
          instruction_o.rs1 = instr.atype.rs1;
          instruction_o.rs2 = instr.atype.rs2;
          instruction_o.rd  = instr.atype.rd;

          if (instr.stype.funct3 == 3'h2) begin
            unique case (instr.instr[31:27])
              5'h0: instruction_o.op = ariane_pkg::AMO_ADDW;
              5'h1: instruction_o.op = ariane_pkg::AMO_SWAPW;
              5'h2: begin
                instruction_o.op = ariane_pkg::AMO_LRW;
                if (instr.atype.rs2 != 0) illegal_instr = 1'b1;
              end
              5'h3: instruction_o.op = ariane_pkg::AMO_SCW;
              5'h4: instruction_o.op = ariane_pkg::AMO_XORW;
              5'h8: instruction_o.op = ariane_pkg::AMO_ORW;
              5'hC: instruction_o.op = ariane_pkg::AMO_ANDW;
              5'h10: instruction_o.op = ariane_pkg::AMO_MINW;
              5'h14: instruction_o.op = ariane_pkg::AMO_MAXW;
              5'h18: instruction_o.op = ariane_pkg::AMO_MINWU;
              5'h1C: instruction_o.op = ariane_pkg::AMO_MAXWU;
              default: illegal_instr = 1'b1;
            endcase
            // double words
          end else if (instr.stype.funct3 == 3'h3) begin
            unique case (instr.instr[31:27])
              5'h0: instruction_o.op = ariane_pkg::AMO_ADDD;
              5'h1: instruction_o.op = ariane_pkg::AMO_SWAPD;
              5'h2: begin
                instruction_o.op = ariane_pkg::AMO_LRD;
                if (instr.atype.rs2 != 0) illegal_instr = 1'b1;
              end
              5'h3: instruction_o.op = ariane_pkg::AMO_SCD;
              5'h4: instruction_o.op = ariane_pkg::AMO_XORD;
              5'h8: instruction_o.op = ariane_pkg::AMO_ORD;
              5'hC: instruction_o.op = ariane_pkg::AMO_ANDD;
              5'h10: instruction_o.op = ariane_pkg::AMO_MIND;
              5'h14: instruction_o.op = ariane_pkg::AMO_MAXD;
              5'h18: instruction_o.op = ariane_pkg::AMO_MINDU;
              5'h1C: instruction_o.op = ariane_pkg::AMO_MAXDU;
              default: illegal_instr = 1'b1;
            endcase
          end else begin
            illegal_instr = 1'b1;
          end
        end

        // --------------------------------
        // Control Flow Instructions
        // --------------------------------
        riscv::OpcodeBranch: begin
          imm_select              = SBIMM;
          instruction_o.fu        = CTRL_FLOW;
          instruction_o.rs1       = instr.stype.rs1;
          instruction_o.rs2       = instr.stype.rs2;

          is_control_flow_instr_o = 1'b1;

          case (instr.stype.funct3)
            3'b000: instruction_o.op = ariane_pkg::EQ;
            3'b001: instruction_o.op = ariane_pkg::NE;
            3'b100: instruction_o.op = ariane_pkg::LTS;
            3'b101: instruction_o.op = ariane_pkg::GES;
            3'b110: instruction_o.op = ariane_pkg::LTU;
            3'b111: instruction_o.op = ariane_pkg::GEU;
            default: begin
              is_control_flow_instr_o = 1'b0;
              illegal_instr           = 1'b1;
            end
          endcase
        end
        // Jump and link register
        riscv::OpcodeJalr: begin
          instruction_o.fu        = CTRL_FLOW;
          instruction_o.op        = ariane_pkg::JALR;
          instruction_o.rs1       = instr.itype.rs1;
          imm_select              = IIMM;
          instruction_o.rd        = instr.itype.rd;
          is_control_flow_instr_o = 1'b1;
          // invalid jump and link register -> reserved for vector encoding
          if (instr.itype.funct3 != 3'b0) illegal_instr = 1'b1;
        end
        // Jump and link
        riscv::OpcodeJal: begin
          instruction_o.fu        = CTRL_FLOW;
          imm_select              = JIMM;
          instruction_o.rd        = instr.utype.rd;
          is_control_flow_instr_o = 1'b1;
        end

        riscv::OpcodeAuipc: begin
          instruction_o.fu     = ALU;
          imm_select           = UIMM;
          instruction_o.use_pc = 1'b1;
          instruction_o.rd     = instr.utype.rd;
        end

        riscv::OpcodeLui: begin
          imm_select       = UIMM;
          instruction_o.fu = ALU;
          instruction_o.rd = instr.utype.rd;
        end

        default: illegal_instr = 1'b1;
      endcase
    end
  end

  // --------------------------------
  // Sign extend immediate
  // --------------------------------
  always_comb begin : sign_extend
    imm_i_type = {{CVA6Cfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:20]};
    imm_s_type = {
      {CVA6Cfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:25], instruction_i[11:7]
    };
    imm_sb_type = {
      {CVA6Cfg.XLEN - 13{instruction_i[31]}},
      instruction_i[31],
      instruction_i[7],
      instruction_i[30:25],
      instruction_i[11:8],
      1'b0
    };
    imm_u_type = {
      {CVA6Cfg.XLEN - 32{instruction_i[31]}}, instruction_i[31:12], 12'b0
    };  // JAL, AUIPC, sign extended to 64 bit
    //  if zcmt then xlen jump address assign to immediate
    imm_uj_type = {
      {CVA6Cfg.XLEN - 20{instruction_i[31]}},
      instruction_i[19:12],
      instruction_i[20],
      instruction_i[30:21],
      1'b0
    };


    // NOIMM, IIMM, SIMM, SBIMM, UIMM, JIMM, RS3
    // select immediate
    case (imm_select)
      IIMM: begin
        instruction_o.result  = imm_i_type;
        instruction_o.use_imm = 1'b1;
      end
      SIMM: begin
        instruction_o.result  = imm_s_type;
        instruction_o.use_imm = 1'b1;
      end
      SBIMM: begin
        instruction_o.result  = imm_sb_type;
        instruction_o.use_imm = 1'b1;
      end
      UIMM: begin
        instruction_o.result  = imm_u_type;
        instruction_o.use_imm = 1'b1;
      end
      JIMM: begin
        instruction_o.result  = imm_uj_type;
        instruction_o.use_imm = 1'b1;
      end
      RS3: begin
        // result holds address of fp operand rs3
        instruction_o.result  = {{CVA6Cfg.XLEN - 5{1'b0}}, instr.r4type.rs3};
        instruction_o.use_imm = 1'b0;
      end
      MUX_RD_RS3: begin
        // result holds address of operand rs3 which is in rd field
        instruction_o.result  = {{CVA6Cfg.XLEN - 5{1'b0}}, instr.rtype.rd};
        instruction_o.use_imm = 1'b0;
      end
      default: begin
        instruction_o.result  = {CVA6Cfg.XLEN{1'b0}};
        instruction_o.use_imm = 1'b0;
      end
    endcase
  end

  // ---------------------
  // Exception handling
  // ---------------------
  logic [CVA6Cfg.XLEN-1:0] interrupt_cause;

  // this instruction has already executed if the exception is valid
  assign instruction_o.valid = instruction_o.ex.valid;

  always_comb begin : exception_handling
    interrupt_cause = '0;
    instruction_o.ex = ex_i;
    // look if we didn't already get an exception in any previous
    // stage - we should not overwrite it as we retain order regarding the exception
    if (~ex_i.valid) begin
      // if we didn't already get an exception save the instruction here as we may need it
      // in the commit stage if we got a access exception to one of the CSR registers
      instruction_o.ex.tval  = {{CVA6Cfg.XLEN-32{1'b0}}, instruction_i};

      // instructions which will throw an exception are marked as valid
      // e.g.: they can be committed anytime and do not need to wait for any functional unit
      // check here if we decoded an invalid instruction or if the compressed decoder already decoded
      // a invalid instruction
      if (illegal_instr || is_illegal_i) begin
        if (!CVA6Cfg.CvxifEn) instruction_o.ex.valid = 1'b1;
        // we decoded an illegal exception here
        instruction_o.ex.cause = riscv::ILLEGAL_INSTR;
      end else if (CVA6Cfg.RVH && virtual_illegal_instr) begin
        instruction_o.ex.valid = 1'b1;
        // we decoded an virtual illegal exception here
        instruction_o.ex.cause = riscv::VIRTUAL_INSTRUCTION;
        // we got an ecall, set the correct cause depending on the current privilege level
      end else if (ecall) begin
        // this exception is valid
        instruction_o.ex.valid = 1'b1;
        // depending on the privilege mode, set the appropriate cause
        if (priv_lvl_i == riscv::PRIV_LVL_S && CVA6Cfg.RVS) begin
          instruction_o.ex.cause = riscv::ENV_CALL_SMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_U) begin
          instruction_o.ex.cause = riscv::ENV_CALL_UMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_M) begin
          instruction_o.ex.cause = riscv::ENV_CALL_MMODE;
        end
      end else if (ebreak) begin
        // this exception is valid
        instruction_o.ex.valid = 1'b1;
        // set breakpoint cause
        instruction_o.ex.cause = riscv::BREAKPOINT;
      end
      // -----------------
      // Interrupt Control
      // -----------------
      // we decode an interrupt the same as an exception, hence it will be taken if the instruction did not
      // throw any previous exception.
      // we have three interrupt sources: external interrupts, software interrupts, timer interrupts (order of precedence)
      // for two privilege levels: Supervisor and Machine Mode
      // Virtual Supervisor Timer Interrupt
        // Supervisor Timer Interrupt
        if (irq_ctrl_i.mie[riscv::IRQ_S_TIMER] && irq_ctrl_i.mip[riscv::IRQ_S_TIMER]) begin
          interrupt_cause = INTERRUPTS.S_TIMER;
        end
        // Supervisor Software Interrupt
        if (irq_ctrl_i.mie[riscv::IRQ_S_SOFT] && irq_ctrl_i.mip[riscv::IRQ_S_SOFT]) begin
          interrupt_cause = INTERRUPTS.S_SW;
        end
        // Supervisor External Interrupt
        // The logical-OR of the software-writable bit and the signal from the external interrupt controller is
        // used to generate external interrupts to the supervisor
        if (irq_ctrl_i.mie[riscv::IRQ_S_EXT] && (irq_ctrl_i.mip[riscv::IRQ_S_EXT] | irq_i[ariane_pkg::SupervisorIrq])) begin
          interrupt_cause = INTERRUPTS.S_EXT;
        end

      // Machine Timer Interrupt
      if (irq_ctrl_i.mip[riscv::IRQ_M_TIMER] && irq_ctrl_i.mie[riscv::IRQ_M_TIMER]) begin
        interrupt_cause = INTERRUPTS.M_TIMER;
      end
      if (CVA6Cfg.SoftwareInterruptEn) begin
        // Machine Mode Software Interrupt
        if (irq_ctrl_i.mip[riscv::IRQ_M_SOFT] && irq_ctrl_i.mie[riscv::IRQ_M_SOFT]) begin
          interrupt_cause = INTERRUPTS.M_SW;
        end
      end
      // Machine Mode External Interrupt
      if (irq_ctrl_i.mip[riscv::IRQ_M_EXT] && irq_ctrl_i.mie[riscv::IRQ_M_EXT]) begin
        interrupt_cause = INTERRUPTS.M_EXT;
      end

      if (interrupt_cause[CVA6Cfg.XLEN-1] && irq_ctrl_i.global_enable) begin
        // However, if bit i in mideleg is set, interrupts are considered to be globally enabled if the hart’s current privilege
        // mode equals the delegated privilege mode (S or U) and that mode’s interrupt enable bit
        // (SIE or UIE in mstatus) is set, or if the current privilege mode is less than the delegated privilege mode.
        if (irq_ctrl_i.mideleg[interrupt_cause[$clog2(CVA6Cfg.XLEN)-1:0]]) begin
            if ((irq_ctrl_i.sie && priv_lvl_i == riscv::PRIV_LVL_S) || (priv_lvl_i == riscv::PRIV_LVL_U)) begin
              instruction_o.ex.valid = 1'b1;
              instruction_o.ex.cause = interrupt_cause;
            end
        end else begin
          instruction_o.ex.valid = 1'b1;
          instruction_o.ex.cause = interrupt_cause;
        end
      end
    end
  end
endmodule
