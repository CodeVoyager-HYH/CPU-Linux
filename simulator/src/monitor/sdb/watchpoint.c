
#include <common.h>
#include <defs.h>
#include <debug.h>

#define WP_NUMBER 10
#define WP_EXPR_LEN 101



typedef struct {
  int number;
  int keep;
  char expr[WP_EXPR_LEN];
  word_t value;
}WP;
static WP wp[WP_NUMBER];
static int wp_cnt = 0;

void wp_init(){
  wp_cnt = 0;
  for(int i = 0; i < WP_NUMBER; ++i){
    wp[i].number = i + 1;
    wp[i].keep   = 0; //不启用
    strcpy(wp[i].expr, "");
    wp[i].value =  0;
  }
}

//add不是增加一个监视点，是新启用一个监视点
void wp_add_watched(char *expr){
  //判断边界情况
  if(wp_cnt  >= WP_NUMBER){
    printf("WP is full, Please delete some watchpoints\n");
    return;
  }
  int idx = wp_cnt;
  strcpy(wp[idx].expr, expr);
  bool success = true;
  word_t value = get_expr_val(expr, &success);
  if(success == false){
    return;
  }
  //只有true之后，才让keep等于1
  printf("Watchpoint %d: [\"%s\"]\n", wp[idx].number, expr);
  wp[idx].keep = 1;
  wp[idx].value = value;
  wp_cnt++;
}
//num >= 1 && num <= WP_NUMBER
//del不是删除某个监视点，是让一个监视点不启用
void wp_del_watched(int num){
  //num必须是要在编号内
  if(!(num >= 1 && num <= WP_NUMBER)){
    printf("Error: Your [N] is bad, Please Reinput\n");
    return ;
  }
  for(int i = 0; i < WP_NUMBER; ++i){
    if(wp[i].number == num){
      if(wp[i].keep == 1){
        wp[num - 1].keep = 0;
        return;
      }else{
        printf("No breakpoint number %d.\n", num);
        return;
      }
    }
  }
}
void wp_check_and_update(){
  int stop_flag = 0;
  for(int i = 0; i < WP_NUMBER; ++i){
    if(wp[i].keep == 1){
      bool success = true;
      word_t new_value = get_expr_val(wp[i].expr, &success);
      assert(success == true);
      word_t old_value = wp[i].value;  
      if(new_value != old_value){
        wp[i].value = new_value;
        printf("\nwatchpoint %d:%s\n\n", i, wp[i].expr);
        printf("Old value = %u(0x%x)\n", old_value, old_value);
        printf("New value = %u(0x%x)\n", new_value, new_value); 
        stop_flag = 1;
      }       
    }
  }
  if(stop_flag == 1){

   // nemu_state.state = NEMU_STOP;
  }
}

void wp_print(){
  int cnt = 0;
  for(int i = 0; i < WP_NUMBER; ++i){
    if(wp[i].keep == 1){
      cnt++;
      printf("No=[%d], Value=[%u(0x%x)], Keep=[%d], Expr=[\"%s\"]\n", wp[i].number, wp[i].value,wp[i].value,wp[i].keep, wp[i].expr);
    }
  }
  if(cnt == 0){
    printf("No watchpoints.\n");
  }
  return;
}
