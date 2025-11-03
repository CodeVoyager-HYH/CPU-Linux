package config_bp;
// BTB
localparam int BTB_NR_ENTRIES      = 8;
localparam int BTB_OFFSET          = 1; 
localparam int BTB_NR_ROWS         = BTB_NR_ENTRIES / 2;
localparam int BTB_ROW_ADDR_BITS   = 1;
localparam int BTB_ROW_INDEX_BITS  = 1;
localparam int BTB_LOG_NR_ROWS     = $clog2(BTB_NR_ROWS); // log2(BTB_NR_ROWS)
localparam int BTB_PREDICTION_BITS = BTB_LOG_NR_ROWS + BTB_OFFSET + BTB_ROW_ADDR_BITS;

// BHT
localparam int BHT_OFFSET          = 1;
localparam int BHT_NR_ENTRIES      = 128;
localparam int BHT_NR_ROWS         = BHT_NR_ENTRIES / 2;
localparam int BHT_LOG_NR_ROWS     = 6;
localparam int BHT_ROW_ADDR_BITS   = 1;
localparam int BHT_ROW_INDEX_BITS  = 1;
localparam int BHT_PREDICTION_BITS = BHT_OFFSET + BHT_LOG_NR_ROWS + BHT_ROW_ADDR_BITS;

// RAS
localparam int RAS_DEPTH            = 6;
endpackage