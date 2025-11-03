#include <common.h>
#include <simulator_state.h>

SIMState sim_state = {.state = SIM_STOP};

int is_exit_status_bad() {
  int good = (sim_state.state == SIM_END && sim_state.halt_ret == 0) 
           ||(sim_state.state == SIM_QUIT);
  return !good;
}

void set_sim_state(int state, vaddr_t pc, int halt_ret) {
  //difftest_skip_ref();
  sim_state.state = state;
  sim_state.halt_pc = pc;
  sim_state.halt_ret = halt_ret;
}


