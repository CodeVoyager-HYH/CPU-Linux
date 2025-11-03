// 指令集IMA
module decoder #(
  parameter type branchpredict_sbe_t = logic,
  parameter type scoreboard_entry_t  = logic
) (
  input   logic [config_pkg::VLEN-1:0]  pc_i,
  input   logic [31:0]                  instruction_i,
  input   branchpredict_sbe_t           branch_predict_i,
  
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
  logic [1:0] funct2;

  logic illegal_instr;
  logic illegal_instr_bm;
  logic illegal_instr_zic;
  logic illegal_instr_non_bm;
  logic virtual_illegal_instr;

  logic [config_pkg::XLEN-1:0] imm_i_type;
  logic [config_pkg::XLEN-1:0] imm_s_type;
  logic [config_pkg::XLEN-1:0] imm_sb_type;
  logic [config_pkg::XLEN-1:0] imm_u_type;
  logic [config_pkg::XLEN-1:0] imm_uj_type;

  // TODO: 没写ecall
  logic ecall;
  logic ebreak;

  enum logic [3:0] {
    NOIMM,
    IIMM,
    SIMM,
    SBIMM,
    UIMM,
    JIMM,
    RS3,
    MUX_RD_RS3
  } imm_select;

  assign opcode  = instruction_i [ 6: 0];
  assign funct2  = instruction_i [31:30];
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
    illegal_instr_bm                       = 1'b0;
    illegal_instr_zic                      = 1'b0;
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

    unique case (opcode)
      //=================================
      // Control Flow Instructions
      //=================================
      riscv::OpcodeLui: begin             // Lui
        imm_select       = UIMM;
        instruction_o.fu = ALU;
        instruction_o.rd = rd_idx;
      end
      riscv::OpcodeAuipc: begin           // Auipc
        instruction_o.fu     = ALU;
        imm_select           = UIMM;
        instruction_o.use_pc = 1'b1;
        instruction_o.rd     = rd_idx;
      end
      riscv::OpcodeJal: begin             // Jal
        instruction_o.fu        = CTRL_FLOW;
        imm_select              = JIMM;
        instruction_o.rd        = rd_idx;
        is_control_flow_instr_o = 1'b1;
      end
      riscv::OpcodeJalr: begin              // Jalr
        instruction_o.fu        = CTRL_FLOW;
        instruction_o.op        = config_pkg::JALR;
        instruction_o.rs1       = rs1_idx;
        imm_select              = IIMM;
        instruction_o.rd        = rd_idx;
        is_control_flow_instr_o = 1'b1;
        // // invalid jump and link register -> reserved for vector encoding
        // if (funct3 != 3'b0) illegal_instr = 1'b1;
        end
      riscv::OpcodeBranch: begin
          imm_select              = SBIMM;
          instruction_o.fu        = CTRL_FLOW;
          instruction_o.rs1       = rs1_idx;
          instruction_o.rs2       = rs2_idx;

          is_control_flow_instr_o = 1'b1;

          case (funct3)
            3'b000: instruction_o.op = config_pkg::EQ;    // Beq
            3'b001: instruction_o.op = config_pkg::NE;    // Bne
            3'b100: instruction_o.op = config_pkg::LTS;   // Blt
            3'b101: instruction_o.op = config_pkg::GES;   // Bge
            3'b110: instruction_o.op = config_pkg::LTU;   // Bltu
            3'b111: instruction_o.op = config_pkg::GEU;   // Bgeu
            default: begin
              is_control_flow_instr_o = 1'b0;
              illegal_instr           = 1'b1;
            end
          endcase
        end
      
      //==============================
      // Lsu
      //==============================
      riscv::OpcodeLoad: begin
          instruction_o.fu = LOAD;
          imm_select = IIMM;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rd = rd_idx;
          // determine load size and signed type
          unique case (funct3)
            3'b000: instruction_o.op = config_pkg::LB;    // Lb
            3'b001: instruction_o.op = config_pkg::LH;    // Lh
            3'b010: instruction_o.op = config_pkg::LW;    // Lw
            3'b100: instruction_o.op = config_pkg::LBU;   // Lbu
            3'b101: instruction_o.op = config_pkg::LHU;   // Lhu
            3'b110:
            if (config_pkg::XLEN == 64) instruction_o.op = config_pkg::LWU; // Lwu
            else illegal_instr = 1'b1;
            3'b011:
            if (config_pkg::XLEN == 64) instruction_o.op = config_pkg::LD;  // Ld
            else illegal_instr = 1'b1;
            default: illegal_instr = 1'b1;
          endcase
        end
      riscv::OpcodeStore: begin
          instruction_o.fu = STORE;
          imm_select = SIMM;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rs2 = rs2_idx;
          // determine store size
          unique case (funct3)
            3'b000: instruction_o.op = config_pkg::SB;  // Sb
            3'b001: instruction_o.op = config_pkg::SH;  // Sh
            3'b010: instruction_o.op = config_pkg::SW;  // Sw
            3'b011:
            if (config_pkg::XLEN == 64) instruction_o.op = config_pkg::SD;    // Sd
            else illegal_instr = 1'b1;
            default: illegal_instr = 1'b1;
          endcase
        end

      // --------------------------------
      // Reg-Immediate Operations
      // --------------------------------
      riscv::OpcodeOpImm: begin
          instruction_o.fu = ALU;
          imm_select = IIMM;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rd = rd_idx;
          unique case (funct3)
            3'b000: instruction_o.op = config_pkg::ADD;   // Addi
            3'b010: instruction_o.op = config_pkg::SLTS;  // Slti
            3'b011: instruction_o.op = config_pkg::SLTU;  // Sltiu
            3'b100: instruction_o.op = config_pkg::XORL;  // Xori
            3'b110: instruction_o.op = config_pkg::ORL;   // Ori
            3'b111: instruction_o.op = config_pkg::ANDL;  // Andi

            3'b001: begin
              instruction_o.op = config_pkg::SLL;  // slli
              if (instruction_i[31:26] != 6'b0) illegal_instr_non_bm = 1'b1;
            end

            3'b101: begin
              if (instruction_i[31:26] == 6'b0)
                instruction_o.op = config_pkg::SRL;  // Srli
              else if (instruction_i[31:26] == 6'b010_000)
                instruction_o.op = config_pkg::SRA;  // Srai
              else illegal_instr_non_bm = 1'b1;
            end
          endcase
        end

      // --------------------------
      // Reg-Reg Operations
      // --------------------------
      riscv::OpcodeOp: begin
          // --------------------------------------------
          // Vectorial Floating-Point Reg-Reg Operations
          // --------------------------------------------
          instruction_o.fu = (funct7 == 7'b000_0001) ? MULT : ALU;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rs2 = rs2_idx;
          instruction_o.rd  = rd_idx;

          unique case ({
            funct7, funct3
          })
            {7'b000_0000, 3'b000} : instruction_o.op = config_pkg::ADD;   // Add
            {7'b010_0000, 3'b000} : instruction_o.op = config_pkg::SUB;   // Sub
            {7'b000_0000, 3'b010} : instruction_o.op = config_pkg::SLTS;  // Slt
            {7'b000_0000, 3'b011} : instruction_o.op = config_pkg::SLTU;  // Sltu
            {7'b000_0000, 3'b100} : instruction_o.op = config_pkg::XORL;  // Xor
            {7'b000_0000, 3'b110} : instruction_o.op = config_pkg::ORL;   // Or
            {7'b000_0000, 3'b111} : instruction_o.op = config_pkg::ANDL;  // And
            {7'b000_0000, 3'b001} : instruction_o.op = config_pkg::SLL;   // Sll
            {7'b000_0000, 3'b101} : instruction_o.op = config_pkg::SRL;   // Srl
            {7'b010_0000, 3'b101} : instruction_o.op = config_pkg::SRA;   // Sra
            // Multiplications
            {7'b000_0001, 3'b000} : instruction_o.op = config_pkg::MUL;   // Mul
            {7'b000_0001, 3'b001} : instruction_o.op = config_pkg::MULH;  // Mulh
            {7'b000_0001, 3'b010} : instruction_o.op = config_pkg::MULHSU;// mulhsu
            {7'b000_0001, 3'b011} : instruction_o.op = config_pkg::MULHU; // mulhu
            {7'b000_0001, 3'b100} : instruction_o.op = config_pkg::DIV;   // Div
            {7'b000_0001, 3'b101} : instruction_o.op = config_pkg::DIVU;  // Divu
            {7'b000_0001, 3'b110} : instruction_o.op = config_pkg::REM;   // Rem
            {7'b000_0001, 3'b111} : instruction_o.op = config_pkg::REMU;  // Remu
            default: begin
              illegal_instr_non_bm = 1'b1;
            end
          endcase      
        end

      // --------------------------------
      // 32 bit Reg-Immediate Operations
      // --------------------------------
      riscv::OpcodeOpImm32: begin
          instruction_o.fu  = ALU;
          imm_select        = IIMM;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rd  = rd_idx;
          if (config_pkg::IS_XLEN64) begin
            unique case (funct3)
              3'b000:  instruction_o.op = config_pkg::ADDW; // Addiw
              3'b001: begin
                instruction_o.op = config_pkg::SLLW;        // Slliw
                if (instruction_i[31:25] != 7'b0) illegal_instr_non_bm = 1'b1;
              end
              3'b101: begin
                if (instruction_i[31:25] == 7'b0)
                  instruction_o.op = config_pkg::SRLW;      // Srliw
                else if (instruction_i[31:25] == 7'b010_0000)
                  instruction_o.op = config_pkg::SRAW;      // Sraiw
                else illegal_instr_non_bm = 1'b1;
              end
              default: illegal_instr_non_bm = 1'b1;
            endcase
          end else illegal_instr = 1'b1;
        end
      
      // --------------------------
      // 32bit Reg-Reg Operations
      // --------------------------
      riscv::OpcodeOp32: begin
          instruction_o.fu  = (funct7 == 7'b000_0001) ? MULT : ALU;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rs2 = rs2_idx;
          instruction_o.rd  = rd_idx;
          if (config_pkg::IS_XLEN64) begin
            unique case ({
              funct7, funct3
            })
              {7'b000_0000, 3'b000} : instruction_o.op = config_pkg::ADDW;  // Addw
              {7'b010_0000, 3'b000} : instruction_o.op = config_pkg::SUBW;  // Subw
              {7'b000_0000, 3'b001} : instruction_o.op = config_pkg::SLLW;  // Sllw
              {7'b000_0000, 3'b101} : instruction_o.op = config_pkg::SRLW;  // Srlw
              {7'b010_0000, 3'b101} : instruction_o.op = config_pkg::SRAW;  // Sraw
              // Multiplications
              {7'b000_0001, 3'b000} : instruction_o.op = config_pkg::MULW;  // Mulw
              {7'b000_0001, 3'b100} : instruction_o.op = config_pkg::DIVW;  // Divw
              {7'b000_0001, 3'b101} : instruction_o.op = config_pkg::DIVUW; // Divuw
              {7'b000_0001, 3'b110} : instruction_o.op = config_pkg::REMW;  // Remw
              {7'b000_0001, 3'b111} : instruction_o.op = config_pkg::REMUW; // Remuw
              default: illegal_instr_non_bm = 1'b1;
            endcase
          end else illegal_instr = 1'b1;
        end
      
      // ----------------------------------
      // Atomic Operations
      // ----------------------------------
        riscv::OpcodeAmo: begin
          instruction_o.fu  = STORE;
          instruction_o.rs1 = rs1_idx;
          instruction_o.rs2 = rs2_idx;
          instruction_o.rd  = rd_idx;
          if (funct3 == 3'h2) begin
            unique case (instruction_i[31:27])
              5'h0: instruction_o.op = config_pkg::AMO_ADDW;  // Amoadd.w
              5'h1: instruction_o.op = config_pkg::AMO_SWAPW; // Amo
              5'h2: begin
                instruction_o.op = config_pkg::AMO_LRW;
                if (rs2_idx != 0) illegal_instr = 1'b1;
              end
              5'h3:  instruction_o.op = config_pkg::AMO_SCW;
              5'h4:  instruction_o.op = config_pkg::AMO_XORW;
              5'h8:  instruction_o.op = config_pkg::AMO_ORW;
              5'hC:  instruction_o.op = config_pkg::AMO_ANDW;
              5'h10: instruction_o.op = config_pkg::AMO_MINW;
              5'h14: instruction_o.op = config_pkg::AMO_MAXW;
              5'h18: instruction_o.op = config_pkg::AMO_MINWU;
              5'h1C: instruction_o.op = config_pkg::AMO_MAXWU;
              default: illegal_instr = 1'b1;
            endcase
            // double words
          end else if (funct3 == 3'h3) begin
            unique case (instruction_i[31:27])
              5'h0: instruction_o.op = config_pkg::AMO_ADDD;
              5'h1: instruction_o.op = config_pkg::AMO_SWAPD;
              5'h2: begin
                instruction_o.op = config_pkg::AMO_LRD;
                if (rs2_idx != 0) illegal_instr = 1'b1;
              end
              5'h3:  instruction_o.op = config_pkg::AMO_SCD;
              5'h4:  instruction_o.op = config_pkg::AMO_XORD;
              5'h8:  instruction_o.op = config_pkg::AMO_ORD;
              5'hC:  instruction_o.op = config_pkg::AMO_ANDD;
              5'h10: instruction_o.op = config_pkg::AMO_MIND;
              5'h14: instruction_o.op = config_pkg::AMO_MAXD;
              5'h18: instruction_o.op = config_pkg::AMO_MINDU;
              5'h1C: instruction_o.op = config_pkg::AMO_MAXDU;
              default: illegal_instr = 1'b1;
            endcase
          end else begin
            illegal_instr = 1'b1;
          end
        end
      default: begin
        instruction_o.result  = {config_pkg::XLEN{1'b0}};
        instruction_o.use_imm = 1'b0;
      end
    endcase
  end

  // --------------------------------
  // Sign extend immediate
  // --------------------------------
  always_comb begin : sign_extend
    imm_i_type = {{config_pkg::XLEN - 12{instruction_i[31]}}, instruction_i[31:20]};
    imm_s_type = {
      {config_pkg::XLEN - 12{instruction_i[31]}}, instruction_i[31:25], instruction_i[11:7]
    };
    imm_sb_type = {
      {config_pkg::XLEN - 13{instruction_i[31]}},
      instruction_i[31],
      instruction_i[7],
      instruction_i[30:25],
      instruction_i[11:8],
      1'b0
    };
    imm_u_type = {
      {config_pkg::XLEN - 32{instruction_i[31]}}, instruction_i[31:12], 12'b0
    }; 
    imm_uj_type = {
      {config_pkg::XLEN - 20{instruction_i[31]}},
      instruction_i[19:12],
      instruction_i[20],
      instruction_i[30:21],
      1'b0
    };

    // NOIMM, IIMM, SIMM, SBIMM, UIMM, JIMM, RS3
    // select immediate
    case (imm_select)
      IIMM: begin
        instruction_o.imm     = imm_i_type;
        instruction_o.use_imm = 1'b1;
      end
      SIMM: begin
        instruction_o.imm     = imm_s_type;
        instruction_o.use_imm = 1'b1;
      end
      SBIMM: begin
        instruction_o.imm     = imm_sb_type;
        instruction_o.use_imm = 1'b1;
      end
      UIMM: begin
        instruction_o.imm     = imm_u_type;
        instruction_o.use_imm = 1'b1;
      end
      JIMM: begin
        instruction_o.imm     = imm_uj_type;
        instruction_o.use_imm = 1'b1;
      end
      default: begin
        instruction_o.imm     = {config_pkg::XLEN{1'b0}};
        instruction_o.use_imm = 1'b0;
      end
    endcase
  end
  
endmodule
