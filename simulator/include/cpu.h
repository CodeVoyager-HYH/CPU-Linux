#ifndef __CPU_CPU_H__
#define __CPU_CPU_H__

#include <common.h>
#include <debug.h>

typedef struct {
  word_t gpr[GPR_NUM];
  vaddr_t pc;

  word_t csr[CSR_NUM];
} CPU_state;

//Decode结构体
typedef struct Decode {
  vaddr_t pc;
  vaddr_t snpc;
  vaddr_t dnpc;
  uint32_t inst_val;
  IFDEF(CONFIG_ITRACE, char logbuf[128]);
} Decode;

#endif
