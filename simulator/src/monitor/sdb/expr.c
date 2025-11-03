
#include <common.h>
#include <debug.h>
#include <regex.h>
#include <defs.h>

//--------------------------本文件内的函数声明--------------------
#define token_str_len 1000
#define token_array_len 65536
word_t expr2val         (char *str, int type, bool *success);
word_t eval             (int p, int q, bool *success) ;
bool   check_parentheses(int i, int j, int *process);
int    getPosition      (int p, int q);
void   print_tokens     (char *prompt,  int p, int q);
word_t get_expr_val     (char *args, bool *success);

static bool   prev_is_num (int i );
static word_t hex_char_to_num(char ch);
enum {
  TK_NOTYPE = 256, 
  TK_NUM_END_9,
  TK_NUM_END_F,
  TK_REG,
  TK_NEWLINE,
  TK_LEFT, // )
  TK_RIGHT,// (-->评估运算符优先级的时候，不算上面的东西，
           //运算符按照优先级的顺序排序
  TK_AND,  // && 优先级最低
  TK_EQ,   // ==
  TK_NEQ,  // !=
  TK_PLUS, // +
  TK_SUB,  // -
  TK_MUL,  // *
  TK_DIV,  // /
  TK_REF,  // [*]-->解引用(ref)， 优先级最高
  TK_NEG,  // [-]-->负号，暂时取消对其支持
};

//TK_NUM_END_9 和 TK_NUM_END_F的匹配顺序问题
//表达式是按照顺序，一个一个进行匹配的
//对于一个表达式  0x1000 + 3来说

//如果匹配顺序 TK_NUM_END_9 > TK_NUM_END_F：
//那么TK_NUM_END_9就只会匹配到0， 剩下表达式x1000 + 3, 然后再对剩余的表达式一个一个进行匹配
//但是我们写的规则里面没有直接是‘x’开头的规则， 最后这个x1000 + 3无法匹配，就会报错

//如果匹配顺序 TK_NUM_END_F > TK_NUM_END_9：
//那么TK_NUM_ENF_F的开头就刚好和0x匹配，就会匹配到0x1000， 最终剩下表达式 + 3

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {
  //regex--toke_type
  {"\\$[A-Za-z0-9]+|\\$\\$[A-Za-z0-9]+", TK_REG},   //$x1, $$0(特殊)
  {"0x[0-9a-fA-F]+U|0x[0-9a-fA-F]+", TK_NUM_END_F}, //0x300[U]
  {"[0-9]+U|[0-9]+", TK_NUM_END_9},                 //35[U]
  {" +",  TK_NOTYPE},    // spaces
  {"\\+", TK_PLUS},      // +
  {"-",   TK_SUB},       // -
  {"\\*", TK_MUL},       // *
  {"\\/", TK_DIV},       // /
  {"\\(", TK_LEFT},      // (
  {"\\)", TK_RIGHT},     // )
  {"\n",  TK_NEWLINE},   // newline
  {"==",  TK_EQ},        // ==
  {"!=",  TK_NEQ},       // !=
  {"&&",  TK_AND},       // &&
};

#define NR_REGEX ARRLEN(rules) //NR_REGEX->Number Of Regular Expression

static regex_t re[NR_REGEX] = {};
/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
//初始化正则表达式，
void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  //for循环中， 
  for (i = 0; i < NR_REGEX; i++) {
    //初始化正则表达式
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    //如果没有成功编译， 那么给出一个错误
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[token_str_len];
} Token;

static Token tokens[token_array_len] __attribute__((used)) = {}; 
static int nr_token __attribute__((used))  = 0;       

//e为expression
static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;
  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;
       // Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s", i, rules[i].regex, position, substr_len, substr_len, substr_start);
        position += substr_len;

        //switch更直观。
        //对于数字类的token，将其添加到token.str里面去
        //对于运算符的token，只需要保存运算符的类型即可，
        switch (rules[i].token_type) {          
          case TK_NUM_END_F:       //ex: 0x80000000
          case TK_NUM_END_9:       //ex: 123
          case TK_REG:             //ex: $x0
              assert(substr_len < token_str_len);
              tokens[nr_token].type = rules[i].token_type;
              strncpy(tokens[nr_token].str, substr_start, substr_len);
              nr_token++;
              break;               //don't remove it
          case TK_NEWLINE:  break; // \n   ，不计入token，一般字符串表达式的最后一个字符是换行符
                                   //表达式测试的时候，里面有空格！！！所以要去除空格
          case TK_NOTYPE:   break; // space, 空格不计入token
          case TK_AND:             // && 
          case TK_NEQ:             // !=
          case TK_EQ:              // ==
          case TK_PLUS:            // +
          case TK_SUB:             // -(sub) and -(neg)
          case TK_MUL:             // *(mul) and *(ref)
          case TK_DIV:             // /
          case TK_LEFT:            // (
          case TK_RIGHT:           // )
              //所有运算符共用下面的代码，记录其类型  
              tokens[nr_token].type = rules[i].token_type; //TK_REG
              nr_token++;
              break;
          default:
              break;
        }
        break;
      }
    }
    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }  

  //将-分成【负号/减号】, 将*分成【引用/乘法】
  for(int i =0 ; i < nr_token; ++i){
    //如果i==0，那么就不会计算后面的
    if(tokens[i].type == TK_MUL && (i == 0 || !prev_is_num(i-1))){
      tokens[i].type = TK_REF;
    }
    /*暂时取消对负号的支持
    else if(tokens[i].type == TK_SUB && (i == 0 || !prev_is_num(i-1))){
      tokens[i].type = TK_NEG;
    }
    */
  }
  for(int i = 0; i < nr_token; ++i){
//    printf("tokens[%d].type=%d\n", i, tokens[i].type);
  }
  return true;
}


//str is 0x[xxxx],  if type=TK_NUM_END_F
//str is   [0-9],   if type=TK_NUM_END_9
//str is  $[a-zA-Z],if type=TK_REG
word_t expr2val(char *str, int type, bool *success){
  //----------------对TK-REG的计算-----------------------
  if(type == TK_REG){
    word_t value = get_reg_val(str + 1, success);
    //if flag == false, value = 0;
    if(*success == false){
      printf("Error: no such reg\n");
    }
    return value;
  }
  
  //-----------------对TK_NUM的计算-----------------------
  int i = 0; //用于下面的for循环
  word_t dig = 0u, value = 0u;
  if     (type == TK_NUM_END_9) { dig = 10u; }
  else if(type == TK_NUM_END_F) { dig = 16u; i = 2;} //i=2,是避免计算0x8000中的0x
  for(        ; i < strlen(str); ++i){
    if(str[i] != 'U'){
      value = value * dig + hex_char_to_num(str[i]);
    }
  }
  return value;
}



//
bool check_parentheses(int i, int j, int *process){
  assert(i < j);
  //检测整个表达式是否被一个大括号包围着
  bool tmp_check = (tokens[i].type == TK_LEFT  && tokens[j].type == TK_RIGHT);
  int arr[320]; //320个左右大括号，保证一定可以匹配
  int left_count = 0; 
  //检测左右括号的数量是否匹配
  int most_left_idx = i;
  int tmp = i;

  while(i <= j){
    if(tokens[i].type ==TK_LEFT){
      arr[left_count] = i;//记录下标
      left_count++;
    }
    else if(tokens[i].type == TK_RIGHT){
      if(left_count > 0){
        if(i == j){
          left_count--;
          most_left_idx = arr[left_count]; 
        }else{
          left_count--;
        }
      }else{
        //TK_RIGHT more than TK_LEFT
        //"(4 + 3)) * ((2 - 1)" // false, bad expression
        *process = 4;
        return false;
      }
    }
    else{
      //isn't TK_LEFT or TK_RIGHT, just ignore it
    }
    i++;
  }


  if(left_count == 0 ){
    if(tmp_check == false){
      //括号数量匹配，但是左右大括号不匹配
      //3+()+4,   3+(3+4)
      *process = 1;
      return false;
    }else{
      if(most_left_idx == tmp){
        //括号数量匹配，左右大括号匹配, 嵌套匹配
        //(()())
        //(3+4)
        //^   ^
        *process = 3;
        return true;
      }else{
        //括号数量匹配，左右大括号匹配, 嵌套不匹配
        //()()
        *process = 2;
        return false;
      }
    }
  }
  else{
    *process = 4;
    return false;
  }
}     

word_t eval(int p, int q, bool *success) {
  if(*success == false){
    return 0u;
  }
  int process = 0;
  if (p > q) {
    *success = false;
    return 0u;
  }
  else if (p == q) {
    //单个数，对表达式求值
    word_t value = expr2val(tokens[p].str, tokens[p].type, success);
    if(*success  == false) return 0u;
    return value; 
  }
  else if (check_parentheses(p, q, &process) == true) {
    //正确的表达式
    return eval(p+1, q-1, success);    
  }else{
    //坏的表达式
    if(process == 4){
      *success = false;  
      return 0u;
    }    
    else if(process == 2 || process == 1){
      int op = getPosition(p, q);
      word_t val1 = 0U;
 
     if(tokens[p].type != TK_REF) val1 = eval(p, op - 1, success); //防止 *0x80000000的情况出现，此时op = 0, op-1 = -1
      word_t val2 = eval(op + 1, q, success);
      switch (tokens[op].type) {
        case TK_AND : return val1 && val2;
        case TK_NEQ : return val1 == val2 ? 0u : 1u;
        case TK_EQ  : return val1 == val2 ? 1u : 0u;
        case TK_PLUS: return val1 + val2;
        case TK_SUB : return val1 - val2;
        case TK_MUL : return val1 * val2;
        case TK_DIV : return val1 / val2;
        case TK_REF : return pmem_read(val2, 4);
        //case TK_NEG : return -val2; 暂时取消对负号的支持
        default: assert(0);
      }
    }
  }
  *success = true;
  return 0u;
}

//保证每个接受再次评估的表达式，都一定能够找到一个位置
int getPosition(int p, int q){
    int idx = -1;
    int left_count = 0;
    while(p <= q){
      if(tokens[p].type == TK_LEFT){
        left_count++;
      }else if(tokens[p].type == TK_RIGHT){
        left_count--;
      }else if(left_count == 0){
          //   1 +   3 * 3
          //     idx   p
          //按优先级进行计算和排序
          switch (tokens[p].type){
            case TK_AND:if(idx == -1 || tokens[idx].type >= TK_AND) {idx = p;} {}
                        break;
            case TK_EQ:  
            case TK_NEQ:if(idx == -1 || tokens[idx].type >= TK_PLUS || tokens[idx].type >= TK_SUB) {idx = p;} 
                        break;
            case TK_PLUS:
            case TK_SUB:if(idx == -1 || tokens[idx].type >= TK_PLUS || tokens[idx].type >= TK_SUB) {idx = p;}
                        break;
            case TK_MUL: 
            case TK_DIV: if(idx == -1 || tokens[idx].type >= TK_MUL || tokens[idx].type >= TK_DIV) {idx = p;}
                        break;
            //负号和解引用的优先级相同
            case TK_REF: if(idx == -1) { idx = p;} break;
            //case TK_NEG: if(idx == -1) { idx = p;} break; 暂时取消对负号的支持
          default:       break;
        } 
      }
      p++;
    }
    assert(idx != -1);
    return idx;
}

void init_token(){
  nr_token = 0;  
  for(int i = 0; i < token_array_len; ++i){
    memset(tokens[i].str, 0, sizeof(tokens[i].str)); // 使用memset函数将str数组清零
    tokens[i].type = 0;
  }
}
//eval_expr 
//return 0, if false, then success is set to false        
//return the value of expression , if success , then success is set to true
word_t expr(char *e, bool *success) {
  init_token();
  if (!make_token(e)) { *success = false;}
  return eval(0, nr_token-1, success);
}

//print tokens for debug-- tokens[q], [p, q]
void print_tokens(char *prompt, int p, int q){
  assert(p >= 0);
  assert(q < nr_token);
  printf("%s", prompt);
  printf("------tokens[%d,%d]=", p, q);
  for(int i = p; i <= q; ++i){
    printf("%s", tokens[i].str);
  }
  printf("\n");
}
static bool prev_is_num(int i ){
  switch(tokens[i].type) {
    case TK_NUM_END_9:
    case TK_NUM_END_F:
    case TK_REG      :
    case TK_LEFT     :
    case TK_RIGHT    : return true; 
    default          : return false;
  }
  return false;
}
static word_t hex_char_to_num(char ch){
  //0x123456790
  word_t value = 0u;
  switch (ch){
    case 'a': 
    case 'A': value = 10u; break;
    case 'b': 
    case 'B': value = 11u; break;
    case 'c':
    case 'C': value = 12u; break;
    case 'd':
    case 'D': value = 13u; break;
    case 'e':
    case 'E': value = 14u; break;
    case 'f':
    case 'F': value = 15u; break;
  default   : value = ch - '0'; break; 
  }
  return value;
}

word_t get_expr_val(char *args, bool *success){
  word_t value = expr(args,  success);
  if(*success == false){ printf("Error : Your expression is bad, please reinput\n");}
  return value;
}