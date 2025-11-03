#ifndef NPC_STATE_H_
#define NPC_STATE_H_
#include <common.h>

typedef struct {
  int state;
  vaddr_t halt_pc;
  uint32_t halt_ret;
} SIMState;
uint64_t  get_time();
struct tm get_system_time();



#endif


