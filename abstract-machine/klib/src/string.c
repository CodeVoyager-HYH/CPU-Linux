#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

//计算字符串的长度
size_t strlen(const char *s) {  
  size_t i = 0;  
  while(s[i] != '\0'){
    i++;
  }
  return i;
}
//将src复制到dst里面去
char *strcpy(char *dst, const char *src) { 
  assert(dst != NULL && src != NULL);

  size_t len = strlen(src);
  size_t i = 0;
  for(     ; i < len; ++i){
    dst[i] = src[i];
  }
  dst[i] = '\0';
  return dst;
}
//将src复制到dst里面去，最多复制n个， 
//无论src的长度是多少， 都会复制n个东西
char *strncpy(char *dst, const char *src, size_t n) {
  size_t i;
  for (i = 0; i < n && src[i] != '\0'; i++){
    dst[i] = src[i];
  }
  for ( ; i < n; i++){
    dst[i] = '\0';
  }
  return dst;
}
char *strcat(char *dst, const char *src) {

  size_t dst_len = strlen(dst);     
  size_t i = 0;
  for(   ;src[i] != '\0'; ++i){
    dst[dst_len + i] = src[i];
  }
  dst[dst_len + i] = '\0'; 
  return dst;
}

//RIGHT
//返回值为正数，如果s1 > s2
//返回值为负数，如果s1 < s2
//返回值为0  ，如果s1 == s2

//正常是比较两个相等不相等，如果不相等

//如果两个字符都相等，那么需要判断它们是否有一个是结尾字符
//结尾字符的ASCII码值是0，所以如果两个字符不相等，可以直接相减判断
int strcmp(const char *s1, const char *s2) {
  assert(s1 != NULL && s2 != NULL);

  int i = 0;
  for(  ; s1[i] == s2[i]; ++i){
    if(s1[i] == '\0') return 0;
  }
  return s1[i] - s2[i];
}

//RIGHT
int strncmp(const char *s1, const char *s2, size_t n) {
  if(s1 == NULL || s2 == NULL){
    return 0;
  }


  int i = 0;
  for(  ; i < n && s1[i] == s2[i]; ++i){
    if(s1[i] == '\0') return 0;
  }
  //三种可能性
  //1. s1[i] != s2[i] , i < n
  //2. s1[i] == s2[i] , i == n
  //3. s1[i] != s2[i] , i == n
  if(i == n) return 0;
  return s1[i] - s2[i];
}


//将内存区域s的前n个字节设置为c
void *memset(void *s, int c, size_t n) {
  if(s == NULL){
    return s;
  }
	char* tmp = (char *)s;
  for(size_t i = 0; i < n; ++i){
    tmp[i] = c;
  }
	return s;
}

//拷贝n字节，要处理dst和src内存重叠的情况
void *memmove(void *dst, const void *src, size_t n) {
  //输入错误处理
  if(dst == NULL || src == NULL){
    return NULL;
  }

  //如果N==0，那么就什么也不拷贝, 直接返回dst
  //写这一行，主要是怕后面的 i = n -1 出现小于0的情况
  if(n == 0) { return dst; }

  char *d = (char *)dst;
  char *s = (char *)src;    
  if(dst < src){
    for(int i = 0; i < n; ++i){
      d[i] = s[i];
    }  
  }else{
    for(int i = n - 1; i >= 0; --i){
      d[i] = s[i];
    }
  }
  return dst;
}

void *memcpy(void *out, const void *in, size_t n) {
  //输入错误处理
  if(out == NULL || in == NULL){
    printf("Error: Calling Memcpy with Null Pointer\n");
    return NULL;
  }

  char *d = (char *)out;
  char *s = (char *)in;
  for(size_t i = 0; i < n; ++i){
    d[i] = s[i];
  }
  return out;
}

//比较n个字符
//这里直接返回a[i] - b[i]的原因是， '\0' 的ASCII码值是0
int memcmp(const void *s1, const void *s2, size_t n) {
  const char *a = (char*)s1;
  const char *b = (char*)s2;
  for(size_t i = 0; i < n; ++i){
    if(a[i] != b[i]){
      return a[i] - b[i]; 
    }
  }
  return 0;
}
#endif