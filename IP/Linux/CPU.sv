module CPU #(
// ---------------------------
// 前端
// ---------------------------

  // 分支预测
  localparam type bp_ctl_t = struct packed {
    logic valid;
    // 主要是根据指令判断用哪一个分支预测器 00——btb 01——bht 10——ras 11——不使用分支预测器
    logic [1:0] bp_ctl_i;
    // 控制进出栈 00进栈，01出栈，10进栈出栈同时 ,11无操作
    logic [1:0] ras_ctl;
  },
  
  localparam type updata_bp_t = struct packed {
    logic valid;
    bp_ctl_t bp_update_ctl;
    logic [config_pkg::VLEN-1: 0] vpc,
    logic [config_pkg::VLEN-1: 0] addr, 
  },
  
  localparam type bp_result_t = struct packed {
    logic pred_valid;
    logic [config_pkg::VLEN-1: 0] pred_add; 
  }

  localparam type branchpredict_sbe_t = struct packed {
      cf_t                     cf;               // type of control flow prediction
      logic [CVA6Cfg.VLEN-1:0] predict_address;  // target address at which to jump, or not
    },

  parameter type exception_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] cause;  // cause of exception
      logic [CVA6Cfg.XLEN-1:0] tval;  // additional information of causing exception (e.g.: instruction causing it),
      // address of LD/ST fault
      logic [CVA6Cfg.GPLEN-1:0] tval2;  // additional information when the causing exception in a guest exception
      logic [31:0] tinst;  // transformed instruction information
      logic gva;  // signals when a guest virtual address is written to tval
      logic valid;
    },
  
  localparam type fu_data_t = struct packed {
      fu_t                              fu;
      fu_op                             operation;
      logic [CVA6Cfg.XLEN-1:0]          operand_a;
      logic [CVA6Cfg.XLEN-1:0]          operand_b;
      logic [$clog2(config_pkg::NR_SB_ENTRIES):0] issue_pointer;
      logic [CVA6Cfg.XLEN-1:0]          imm;
      logic [CVA6Cfg.XLEN-1:0]          pc;
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] pointer;
    },

  localparam type scoreboard_entry_t = struct packed {
      logic [CVA6Cfg.VLEN-1:0] pc;  // PC of instruction
      // with the transaction id in any case make the width more generic
      fu_t fu;  // functional unit to use
      fu_op op;  // operation to perform in each functional unit
      logic [REG_ADDR_SIZE-1:0] rs1;  // register source address 1
      logic [REG_ADDR_SIZE-1:0] rs2;  // register source address 2
      //====================
      logic [copnfig_pkg::XLEN-1:0] imm;//新加
      //====================
      logic [REG_ADDR_SIZE-1:0] rd;  // register destination address
      logic [CVA6Cfg.XLEN-1:0] result;  // for unfinished instructions this field also holds the immediate,
      // for unfinished floating-point that are partly encoded in rs2, this field also holds rs2
      // for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
      // this field holds the address of the third operand from the floating-point register file
      logic valid;  // is the result valid
      logic use_imm;  // should we use the immediate as operand b?
      logic use_zimm;  // use zimm as operand a
      logic use_pc;  // set if we need to use the PC as operand a, PC from exception
      exception_t ex;  // exception has occurred
      branchpredict_sbe_t bp;  // branch predict scoreboard data structure
      logic vfp;  // is this a vector floating-point instruction?
    },
) (
  ports
);

  
endmodule