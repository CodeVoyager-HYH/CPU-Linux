import ariane_pkg::*;

module instr_realign (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic valid_i,
    input  logic [VLEN-1:0] address_i,
    input  logic [FETCH_LEN-1:0] data_i,

    output logic [1:0] instr_is_compressed_o,
    output logic serving_unaligned_o,       // 指示是否非对齐
    output logic [1:0] valid_o,             // 可能是两条压缩指令，所以有两个
    output logic [1:0][VLEN-1:0] addr_o,    //对齐后的地址
    output logic [1:0][31:0] instr_o
);

//  主要是解决指令未对齐问题，针对16位压缩指令和32位普通指令的混合场景
//  识别压缩指令和跟踪未对齐状态实现拼接，输出对齐的32位指令和地址   
//  32位判断：
//    首先，把指令设置为未对齐，开始判断语句
//    当时压缩指令或者未对齐：
//        1.下一条是压缩指令，保存高位指令(下一次拼接指令)，非对齐状态清除，输出指令
//        2.需要的指令是32位但是地址是16位对齐不是32位————需要拼接指令  

    // logic [1:0] instr_is_compressed_o;//指示指令是不是压缩指令

    for (genvar i = 0; i < 2; i++) begin
        assign instr_is_compressed_o[i] = ~&data_i[i*16+:2];// 取data_i中第i个16位字段的最低2位，若不是11则为压缩指令，1是压缩指令
    end

    // 需要跟踪的额外状态
    logic [15:0] unaligned_instr_d, unaligned_instr_q;          // 保存需要拼接的数据
    logic unaligned_d, unaligned_q;                             // 判断是不是未对齐
    logic [VLEN-1:0] unaligned_address_d, unaligned_address_q;  // 保存未对齐的地址
    
    assign serving_unaligned_o = unaligned_q;

    always_comb begin : re_align        // 这里只考虑取指是32位的
        unaligned_d         = 1'b0;
        unaligned_address_d = {address_i[VLEN-1:2], 2'b10}; // 四字节是永远对齐的，所以这里直接二字节对齐
        unaligned_instr_d   = unaligned_instr_q;

        valid_o[0] = valid_i;   // 因为输入是32位，valid_i只能判断指令是不是有效，只能判断一个，另一个需要看是不是压缩指令判断
        instr_o[0] = unaligned_q? {data_i[15:0], unaligned_instr_q}: data_i[31:0];
        addr_o [0] = unaligned_q? unaligned_address_q: address_i;
        valid_o[1] = 1'b0;   
        instr_o[1] = '0;
        addr_o [1] = {address_i[VLEN-1:2], 2'b10};

        if(instr_is_compressed_o[0] || unaligned_q) begin // 第一条指令是压缩指令
            if(instr_is_compressed_o[1]) begin
                // 第二条指令也是压缩指令
                unaligned_d = 1'b0;
                valid_o[1]  = valid_i;
                instr_o[1]  = {16'b0, data_i[31:16]};
            end
            else begin  //第二条是正常指令，需要拼接指令
                unaligned_d = 1'b1;
                unaligned_address_d = {address_i[VLEN-1:2], 2'b10};
                unaligned_instr_d = data_i[31:16];
            end
        end

        if (valid_i && address_i[1]) begin      // 处理“地址不是 32 位对齐，而是 16 位对齐”的特殊情况：
            if(!instr_is_compressed_o[0]) begin   // 非压缩指令
                valid_o = '0;
                unaligned_d = 1'b1;
                unaligned_address_d = {address_i[VLEN-1:2], 2'b10};
                unaligned_instr_d = data_i[15:0];
            end
            else begin
                valid_o = 2'b01;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin 
        if(!rst_ni) begin
            unaligned_q         <= 1'b0;
            unaligned_address_q <= '0;
            unaligned_instr_q   <= '0;
        end
        else begin
            if(valid_i) begin
                unaligned_address_q <= unaligned_address_d;
                unaligned_instr_q   <= unaligned_instr_d;
            end
            
            if (flush_i) begin
                unaligned_q <= 1'b0;
            end 
            else if (valid_i) begin
            unaligned_q <= unaligned_d;
            end
        end
    end

endmodule