package riscv;

    // RV32/64G listings:
    // Quadrant 0
    localparam OpcodeLoad = 7'b00_000_11;
    localparam OpcodeLoadFp = 7'b00_001_11;
    localparam OpcodeCustom0 = 7'b00_010_11;
    localparam OpcodeMiscMem = 7'b00_011_11;
    localparam OpcodeOpImm = 7'b00_100_11;
    localparam OpcodeAuipc = 7'b00_101_11;
    localparam OpcodeOpImm32 = 7'b00_110_11;
    // Quadrant 1
    localparam OpcodeStore = 7'b01_000_11;
    localparam OpcodeStoreFp = 7'b01_001_11;
    localparam OpcodeCustom1 = 7'b01_010_11;
    localparam OpcodeAmo = 7'b01_011_11;
    localparam OpcodeOp = 7'b01_100_11;
    localparam OpcodeLui = 7'b01_101_11;
    localparam OpcodeOp32 = 7'b01_110_11;
    // Quadrant 2
    localparam OpcodeMadd = 7'b10_000_11;
    localparam OpcodeMsub = 7'b10_001_11;
    localparam OpcodeNmsub = 7'b10_010_11;
    localparam OpcodeNmadd = 7'b10_011_11;
    localparam OpcodeOpFp = 7'b10_100_11;
    localparam OpcodeVec = 7'b10_101_11;
    localparam OpcodeCustom2 = 7'b10_110_11;
    // Quadrant 3
    localparam OpcodeBranch = 7'b11_000_11;
    localparam OpcodeJalr = 7'b11_001_11;
    localparam OpcodeRsrvd2 = 7'b11_010_11;
    localparam OpcodeJal = 7'b11_011_11;
    localparam OpcodeSystem = 7'b11_100_11;
    localparam OpcodeRsrvd3 = 7'b11_101_11;
    localparam OpcodeCustom3 = 7'b11_110_11;

    // RV64C/RV32C listings:
    // Quadrant 0
    localparam OpcodeC0 = 2'b00;
    localparam OpcodeC0Addi4spn = 3'b000;
    localparam OpcodeC0Fld = 3'b001;
    localparam OpcodeC0Lw = 3'b010;
    localparam OpcodeC0Ld = 3'b011;
    localparam OpcodeC0Zcb = 3'b100;
    localparam OpcodeC0Fsd = 3'b101;
    localparam OpcodeC0Sw = 3'b110;
    localparam OpcodeC0Sd = 3'b111;
    // Quadrant 1
    localparam OpcodeC1 = 2'b01;
    localparam OpcodeC1Addi = 3'b000;
    localparam OpcodeC1Addiw = 3'b001;  //for RV64I only
    localparam OpcodeC1Jal = 3'b001;  //for RV32I only
    localparam OpcodeC1Li = 3'b010;
    localparam OpcodeC1LuiAddi16sp = 3'b011;
    localparam OpcodeC1MiscAlu = 3'b100;
    localparam OpcodeC1J = 3'b101;
    localparam OpcodeC1Beqz = 3'b110;
    localparam OpcodeC1Bnez = 3'b111;
    // Quadrant 2
    localparam OpcodeC2 = 2'b10;
    localparam OpcodeC2Slli = 3'b000;
    localparam OpcodeC2Fldsp = 3'b001;
    localparam OpcodeC2Lwsp = 3'b010;
    localparam OpcodeC2Ldsp = 3'b011;
    localparam OpcodeC2JalrMvAdd = 3'b100;
    localparam OpcodeC2Fsdsp = 3'b101;
    localparam OpcodeC2Swsp = 3'b110;
    localparam OpcodeC2Sdsp = 3'b111;

endpackage
