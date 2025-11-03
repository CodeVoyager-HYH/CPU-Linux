#ifndef __COMMON_H__
#define __COMMON_H__
#include <macro.h>
#include <autoconf.h>
#include <sim_difftest.h>
//C-Standard-File
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <autoconf.h>
#define __GUEST_ISA__ riscv32


//Type
typedef uint32_t  word_t;
typedef  int32_t sword_t;
typedef word_t   vaddr_t;
typedef word_t   paddr_t;
//
#define FMT_WORD  "0x%08" PRIx32
#define FMT_PADDR "0x%08" PRIx32

//memory
#define PMEM_LEFT  ((paddr_t)CONFIG_MBASE)
#define PMEM_RIGHT ((paddr_t)CONFIG_MBASE + CONFIG_MSIZE - 1)
#define RESET_VECTOR (PMEM_LEFT + CONFIG_PC_RESET_OFFSET)

//gpr && csr
#define GPR_NUM 32
enum{
  x0 = 0,
  MSTATUS=0,
  MTVEC,
  MEPC,
  MCAUSE,
  ERROR_CSR_IDX,
  CSR_NUM,
  CSRRW = 0x100,
  CSRRS = 0x101,

  MSTATUS_IDX = 0x300,
  MTVEC_IDX   = 0x305,
  MEPC_IDX    = 0x341,
  MCAUSE_IDX  = 0x342,
};
enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };
enum { SIM_RUNNING, SIM_STOP, SIM_END, SIM_ABORT, SIM_QUIT };
#endif
