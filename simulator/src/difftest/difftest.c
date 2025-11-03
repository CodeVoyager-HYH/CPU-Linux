
#include "simulator_state.h"
#include <dlfcn.h>
#include <utils.h>
#include <common.h>
#include <defs.h>
#include <debug.h>
#include <cpu.h>


void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(uint64_t NO) = NULL;
#ifdef CONFIG_DIFFTEST
extern CPU_state cpu;
extern SIMState sim_state;

static bool is_skip_ref = false;
static int skip_dut_nr_inst = 0;
void difftest_skip_ref() {
  is_skip_ref = true;
  skip_dut_nr_inst = 0;
}

void difftest_skip_dut(int nr_ref, int nr_dut) {
  skip_dut_nr_inst += nr_dut;
  while (nr_ref -- > 0) {
    ref_difftest_exec(1);
  }
}

void init_difftest(char *ref_so_file, long img_size, int port) {
  assert(ref_so_file != NULL);
  void *handle;
  handle = dlopen(ref_so_file, RTLD_LAZY);
  assert(handle);

  ref_difftest_memcpy =  (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
  assert(ref_difftest_memcpy);

  ref_difftest_regcpy = (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");
  assert(ref_difftest_regcpy);

  ref_difftest_exec =  (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  assert(ref_difftest_exec);

  ref_difftest_raise_intr = (void (*)(uint64_t))dlsym(handle, "difftest_raise_intr");
  assert(ref_difftest_raise_intr);

  void (*ref_difftest_init)(int) = (void (*)(int))dlsym(handle, "difftest_init");
  assert(ref_difftest_init);

  ref_difftest_init(port); //do nothing
  ref_difftest_memcpy(RESET_VECTOR, guest_to_host(RESET_VECTOR), img_size, DIFFTEST_TO_REF);
  ref_difftest_regcpy(&cpu, DIFFTEST_TO_REF);  //cpu-->REF

  Log("Differential testing: %s", ANSI_FMT("ON", ANSI_FG_GREEN));
  Log("The result of every instruction will be compared with %s. "
      "This will help you a lot for debugging, but also significantly reduce the performance. "
      "If it is not necessary, you can turn it off in menuconfig.", ref_so_file);

}






//ref是参考处理器执行完对应指令后的数据
//pc是执行指令的地址
extern word_t commit_pre_pc;

static void checkregs(CPU_state *ref, vaddr_t pc) {
  //目前只对比
  
  if(commit_pre_pc != ref->pc){
      printf("[NPC] Difftest Error: 在执行完pc=[%x]指令之后,DUT和REF的状态出现不一致:\n", pc);
      printf("[参考处理器.pc]=0x%x\n[你的处理器.pc]=0x%x\n", ref->pc, commit_pre_pc);
      printf("\n-----------以下是所有寄存器数据：\n");
      for(int i = 0;  i < 32; ++i){
        printf("[参考处理器.%s]=0x%x, [你的处理器.%s]=0x%x\n", reg_name(i), ref->gpr[i], reg_name(i), gpr(i));
      }
      npc_close_simulation();
      printf("下面将会产生一个makefile错误，暂时不用担心\n");
      exit(1);
  }

  for(int i = 0; i < 32; ++i){
    if(ref->gpr[i] != cpu.gpr[i]){  
      printf("[NPC] Difftest Error: 在执行完pc=[%x]指令之后,DUT和REF状态出现不一致:\n", pc);
      printf("[参考处理器.%s]=0x%x, [你的处理器.%s]=0x%x\n", reg_name(i), ref->gpr[i], reg_name(i), gpr(i));      
      npc_close_simulation();
      printf("下面将会产生一个makefile错误，暂时不用担心\n");
      exit(1);
    }
  }
  


#ifdef CONFIG_DIFFTEST_CSR
    bool is_mtvec_bad    = ref->csr[MTVEC]    != cpu.csr[MTVEC];
    bool is_mcause_bad   = ref->csr[MCAUSE]   != cpu.csr[MCAUSE];
    bool is_mstatus_bad  = ref->csr[MSTATUS]  != cpu.csr[MSTATUS];
    bool is_mepc_bad     = ref->csr[MEPC]     != cpu.csr[MEPC];
    bool is_csr_bad      = is_mcause_bad || is_mepc_bad || is_mstatus_bad || is_mtvec_bad;
    if(is_csr_bad){
      printf("处理器对比出错,在执行完pc=[%x]这条指令后,[参考处理器]和[你的处理器]的寄存器状态对比出现不一致:\n", pc);
      if(is_mtvec_bad){ printf("[参考处理器].mtvec=0x%x, [你的处理器].mtvec=0x%x\n",      ref->csr[MTVEC],cpu.csr[MTVEC]);}
      if(is_mcause_bad){ printf("[参考处理器].mcause=0x%x, [你的处理器].mcause=0x%x\n",   ref->csr[MCAUSE],cpu.csr[MCAUSE]);}
      if(is_mstatus_bad){ printf("[参考处理器].mstatus=0x%x, [你的处理器].mstatus=0x%x\n",ref->csr[MSTATUS],cpu.csr[MSTATUS]); }
      if(is_mepc_bad){ printf("[参考处理器].mpec=0x%x, [你的处理器].mpec=0x%x\n",         ref->csr[MEPC],cpu.csr[MEPC]); }
      printf("\n--------->下面是[参考处理器]和[你的处理器]的所有寄存器状态\n");
      for(int i = 0; i < 32; ++i){
        if(ref->gpr[i] != cpu.gpr[i]){ printf("------>寄存器状态不一致:");}
        printf("[参考处理器].%s=0x%x, [你的处理器].%s=0x%x\n", reg_name(i), ref->gpr[i], reg_name(i), gpr(i));
      }
      npc_close_simulation();
      exit(1);
    }
#endif

}


//difftest_step
void difftest_step(vaddr_t pc, vaddr_t next_pc) {
  CPU_state ref_r;
  if (skip_dut_nr_inst > 0) {
    ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
    if (ref_r.pc == next_pc) {
      skip_dut_nr_inst = 0;
      checkregs(&ref_r, next_pc);
      return;
    }
    skip_dut_nr_inst --;
    if (skip_dut_nr_inst == 0)
      panic("can not catch up with ref.pc = " FMT_WORD " at pc = " FMT_WORD, ref_r.pc, pc);
    return;
  }

  if (is_skip_ref) {
    ref_difftest_regcpy(&cpu, DIFFTEST_TO_REF);
    is_skip_ref = false;
    return;
  }
  ref_difftest_exec(1);
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT); //把REF的内容
  checkregs(&ref_r, pc);
}

#else
void init_difftest(char *ref_so_file, long img_size, int port) { }
#endif
