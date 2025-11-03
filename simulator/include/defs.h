#ifndef  DEFS_H_
#define  DEFS_H_
#include <cpu.h>
#include <common.h>
void 		engine_start();
int  		is_exit_status_bad();
void set_sim_state(int state, vaddr_t pc, int halt_ret);
#define SIMTRAP(thispc, code) set_sim_state(SIM_END, thispc, code)


//sdb.c
void 		sdb_set_batch_mode();
void 		sdb_mainloop();
//cpu.c
void 		cpu_exec(uint64_t n);

//cpu.c

const char* reg_name(int idx);
void   		isa_reg_display();
word_t 		get_reg_val(const char *s, bool *success) ;

int 	check_reg_idx(int idx);
int 	check_csr_idx(int idx);
#define gpr(idx) (cpu.gpr[check_reg_idx(idx)])
#define csr(idx) (cpu.gpr[check_csr_idx(idx)])


//init_monitor.c
void 		init_monitor(int , char **);

void 		init_log(const char *log_file);
void 		init_difftest(char *ref_so_file, long img_size, int port);
void 		init_sdb();
void 		init_disasm(const char *triple);
void 		init_trace();

//timer.c
void		init_rand();





//watchpoint.c
word_t 		get_expr_val(char *args, bool *success);
void 		wp_print();
void 		wp_check_and_update();
void 		wp_del_watched(int num);
void 		wp_add_watched(char *expr);
void 		wp_init();


//reg.c
void    	isa_reg_display();
void 		get_cpu_state_from_npc();
void 		init_regex();

word_t 		expr(char *e, bool *success);
void 		get_memory_val(paddr_t mem_addr, int length);
static 		word_t arg2val(char *arg);

//npc-dpi



//disasm.cc
void 		init_disasm(const char *triple);
void 		disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);


void difftest_step(vaddr_t pc, vaddr_t npc);
bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc);


uint64_t get_time();

//npc.c
void npc_open_simulation();
void npc_close_simulation();
void update_cpu_state();
void npc_single_cycle();
void npc_reset(int n);
void npc_init();
void npc_exec_once();
void npc_get_clk_count();

//memory.c
void 	 init_mem();
uint8_t* guest_to_host(paddr_t paddr);
word_t	 pmem_read(paddr_t addr, int len);
void	 pmem_write(paddr_t addr, int len, word_t data);


void     instr_trace(word_t pc);

#endif
