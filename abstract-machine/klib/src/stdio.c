#include <am.h>
#include <klib.h>
#include <klib-macros.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

static void  int_to_str(char *str,          int num);
static void uint_to_str(char *str, unsigned int num);
static void swap_str(char *str, int l, int r);

#define BUF_SIZE 1024
int printf(const char *fmt, ...) {
  char out[BUF_SIZE] = {};
  va_list ap;
  va_start(ap, fmt);
  int num = vsprintf(out, fmt, ap);
  va_end(ap);
 
  //输出
  for(int i = 0; i < num; ++i){
    putch(out[i]);
  }
  return num;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  int out_index = 0;
  while(*fmt != '\0'){
    //如果遇到%号
    if(*fmt == '%'){
      fmt++; //跳过%号，直接看下一个的值，是d还是s，（是d就是%d，是s就是%s）
      switch (*fmt){
        case 'd': {
          int num = va_arg(ap, int);//得到这个数字了，但是要把这个数字打印到屏幕终端去
          char s[BUF_SIZE] = {};
          int_to_str(s, num);
          strcpy(out + out_index, s); 
          out_index += strlen(s);
          break;
        }
        case 's':{
          char *str = va_arg(ap, char *); 
          strcpy(out + out_index, str); 
          out_index += strlen(str);
          break;
        } 
        case 'u':{
          uint64_t num = va_arg(ap, uint64_t);
          char s[BUF_SIZE] = {};
          uint_to_str(s, num);
          strcpy(out + out_index, s); 
          out_index += strlen(s);
          break;
        }
        default: 
          out[out_index++] = *fmt;
          break; 
      }
    }else{
      out[out_index++] = *fmt; //如果不是%d之类，而是普通字符，则输出到out里面去
    }
    fmt++;
  }
  out[out_index] = '\0';
  return out_index;
}
int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int num = vsprintf(out, fmt, ap);
  va_end(ap);
  return num;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

//(L, R)
static void swap_str(char *str, int l, int r){
  assert(str != NULL);
  while(l <= r){
    char tmp = str[l];
    str[l] = str[r];
    str[r] = tmp;
    l++;  r--;
  }
}

//int_to_str分四种情况
//1. num = INT_MIN32
//2. num == 0
//3. num < 0
//4. num > 0
static void int_to_str(char *str, int num){
  assert(str != NULL);
  int i = 0;

  if(num == INT32_MIN){
    str[i++] = '-';
    str[i++] = '2';
    str[i++] = '1';
    str[i++] = '4';
    str[i++] = '7';
    str[i++] = '4';
    str[i++] = '8';
    str[i++] = '3';
    str[i++] = '6';
    str[i++] = '4';
    str[i++] = '8';
    str[i] = '\0';
    return;
  }
  int l = 0;  
  if(num == 0){
    str[i++] = '0';
  }
  else if(num < 0) {
    str[i++] = '-';
    num = -num;
    l = 1;
  }
  //小于0和大于0共用下面的while循环逻辑
  //INT_MIN32属于小于0的范畴，
  while(num != 0){
    str[i++] = num % 10 + '0';
    num /= 10;
  }
  str[i] = '\0';
  swap_str(str, l, i-1);
}

static void uint_to_str(char *str, unsigned int num){
  int i = 0;
  if(num == 0){
    str[i++] = '0';
    str[i]   = '\0';
    return;
  }
  while(num > 0){
    str[i++] = num % 10 + '0';
    num = num / 10;
  }
  str[i] = '\0';
  swap_str(str, 0, i - 1);
}
#endif
