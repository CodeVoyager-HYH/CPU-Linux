#include <common.h>
#include <defs.h>
#include <debug.h>
#include <readline/readline.h>
#include <readline/history.h>


static int is_batch_mode = false;
static int cmd_help(char *args);
static int cmd_c   (char *args);
static int cmd_q   (char *args);
static int cmd_si  (char *args);
static int cmd_info(char *args);
static int cmd_x   (char *args);
static int cmd_p   (char *args);
static int cmd_w   (char *args);
static int cmd_d   (char *args);

static int cmd_clear(char *args);
static struct {
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table [] = {
  { "help", "Display information about all supported commands", cmd_help },
  { "c",    "Continue the execution of the program", cmd_c },
  { "q",    "Exit NEMU", cmd_q },
  { "si",   "Cause the program to execute a specified number of steps, or default to executing a single step, after which the program pauses.", cmd_si},
  { "info", "Print the information of registers or program watchpoints.", cmd_info},
  { "x",    "Calculate the value of the expression EXPR Output N consecutive 4-byte values in hexadecimal format from this address(EXPR).", cmd_x},
  { "p",    "eval a expression and get it value", cmd_p},
  { "w",    "add expression watched", cmd_w},
  { "d",    "delete expression watched", cmd_d},
  { "clear", "[clear]", cmd_clear},
};
#define NR_CMD ARRLEN(cmd_table) 

static char* rl_gets() {
  static char *line_read = NULL;
  if (line_read) {
    free(line_read);
    line_read = NULL;
  }
  line_read = readline("(npc) ");
  if (line_read && *line_read) {
    add_history(line_read);
  }
  return line_read;
}

static int cmd_help(char *args) {
  /* extract the first argument */
  char *arg = strtok(NULL, " ");
  int i;

  if (arg == NULL) {
    /* no argument given */
    for (i = 0; i < NR_CMD; i ++) {
      printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
    }
  }
  else {
    printf("Lists of classes of commands:\n\n");
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(arg, cmd_table[i].name) == 0) {
        printf("%s -- %s\n", cmd_table[i].name, cmd_table[i].description);
        return 0;
      }
    }
    printf("Unknown command '%s'\n", arg);
  }
  return 0;
}

static int cmd_c(char *args) {
  cpu_exec(UINT64_MAX);
  return 0;
}

static int cmd_q(char *args) {
  npc_close_simulation();
  Log("NPC close simulation");
  return -1;
}


static int cmd_si  (char *args){
  if(args == NULL){ 
    cpu_exec(1u); 
  }else{    
    word_t cnt = arg2val(args);  
    printf("si [%u]\n", cnt);
    cpu_exec(cnt);
  }  
  return 0;
}

static int cmd_info(char *args){
  //处理错误输入
  if(args == NULL){
    printf("command format:\n");
    printf("info [r] --->display all regs\n");
    printf("info [w] --->display all watchpoints\n");
  }

  else if(strcmp(args, "r") == 0){
    isa_reg_display();
  }
  else if(strcmp(args, "w") == 0){
    wp_print();
  }
  return 0;
}


//  x  3  0x80000000
static int cmd_x   (char *args){
  //输入不合法处理
  if(args == NULL){
    printf("Please Input: x [N] [expr]\n");
    return 0;
  }
//  printf("args=%s\n", args);
  //处理字符串中的[N]
  char   *num_args     = strtok(args, " ");
//  printf("num_args=%s\n", num_args);
  word_t  num_val      = arg2val(num_args);    
  //处理字符串的中的[expr]
  bool success = true;
  char *expr_args    = strtok(NULL, "");  
//  printf("expr_args=%s\n", expr_args);
  word_t expr_val     = get_expr_val(expr_args, &success);  


  //输入不合法处理
  if(num_val < 1){
    printf("In cmd_x: Your [N] is too less, Please Reinput\n");
    return 0;
  }
  if(success == false){ 
    printf("In cmd_x: Your [expr] is bad, Please Reinput\n");
    return 0; 
  }
  //从内存中获取数据

  
  get_memory_val(expr_val, num_val);
  return 0;
}
static int cmd_p   (char *args){
  bool success = true;
  word_t value = get_expr_val(args, &success);
  if(success == true){
    printf("%u(0x%x)\n", value,value);
  }
  return 0;
}


static int cmd_w   (char *args){
  //处理输入错误
  if(args == NULL){
    printf("Cmd Format: w [expr], Please Reinput\n");
    return 0;
  }
  if(strlen(args) > 100){
    printf("Your expression is too long, Please Reinput\n");
    return 0;
  }
  //执行
  wp_add_watched(args);
  return 0;
}
static int cmd_d   (char *args){
  //处理输入错误
  if(args == NULL){
    printf("Cmd Foramt: d [N], Please Reinput\n");
    return 0;
  }
  char *num_args = strtok(args, " ");
  int        num = arg2val(num_args);
  wp_del_watched(num);
  return 0;
}

void sdb_set_batch_mode() {
  is_batch_mode = true;
}

void sdb_mainloop() {
  if (is_batch_mode) {
    cmd_c(NULL);
    return;
  }
  for (char *str; (str = rl_gets()) != NULL; ) {
    char *str_end = str + strlen(str);
    char *cmd = strtok(str, " ");
    if (cmd == NULL) { 
      continue; 
    }
    char *args = cmd + strlen(cmd) + 1;
    if (args >= str_end) {
      args = NULL;
    }
#ifdef CONFIG_DEVICE
    extern void sdl_clear_event_queue();
    sdl_clear_event_queue();
#endif
    int i;
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(cmd, cmd_table[i].name) == 0) {
        if (cmd_table[i].handler(args) < 0) { return; }
        break;
      }
    }
    if (i == NR_CMD) { printf("Unknown command '%s'\n", cmd); }
  }
}
// arg2val, 默认arg是无符号十进制数
static word_t arg2val(char *arg){
  word_t value = 0u; 
  for(int i = 0;  arg[i] != '\0'; ++i){
    assert(arg[i] >='0' && arg[i] <= '9');
    word_t tmp = arg[i] - '0';
    value =  value * 10u + tmp;
  }
  return value;
}

void get_memory_val(paddr_t mem_addr, int length){
    //处理输入错误
  if(!(length >= 1)){
    printf("In get_memory_val: length is too small, Please Check Your Input\n");
    return;
  }
  if(!(mem_addr >= 0x80000000U && mem_addr <= 0x87FFFFFFU)){
    printf("In get_memory_val: mem_addr out of bounds, Please Check Your Input\n");
    return;
  }
  //执行
  for(int i = 0; i < length; ++i){
    printf("[0x%x]:0x%08x\n", mem_addr, pmem_read(mem_addr, 4u));
    mem_addr = mem_addr + 4u;
  }
}


void init_sdb() {
  init_regex();
  wp_init();
}


static int cmd_clear(char *args){
  printf("\033[1;1H\033[2J"); 
  return 0;
}
