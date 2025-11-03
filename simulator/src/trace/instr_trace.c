
#include <cpu.h>
#include <simulator_state.h>
#include <common.h>
#include <defs.h>

void instr_trace(word_t pc) {
    Decode s;
    s.pc = pc;
    s.inst_val = pmem_read(pc, 4);
    char *p = s.logbuf;
    p += snprintf(p, sizeof(s.logbuf), FMT_WORD ":", s.pc);
    int ilen = 4;
    int i;
    uint8_t *inst = (uint8_t *)&s.inst_val;
    for (i = ilen - 1; i >= 0; i --) {
        p += snprintf(p, 4, " %02x", inst[i]);
    }
    int ilen_max = MUXDEF(CONFIG_ISA_x86, 8, 4);
    int space_len = ilen_max - ilen;
    if (space_len < 0) space_len = 0;
    space_len = space_len * 3 + 1;
    memset(p, ' ', space_len);
    p += space_len;
    disassemble(p, s.logbuf + sizeof(s.logbuf) - p, s.pc, (uint8_t *)&s.inst_val, ilen);
    printf("%s\n",s.logbuf);
}