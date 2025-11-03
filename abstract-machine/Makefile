
# Makefile for AbstractMachine Kernels and Libraries
# Makefile文件处理变量的时候，


# $(AM_HOME)/Makefile 在执行的时候会导入目录$(AM_HOME)/scripts里面一个特定架构的Makefile文件
# 这个特定架构的Makefile文件一般也会导入一些其他的文件

### *Get a more readable version of this Makefile* by `make html` (requires python-markdown)
html:
	cat Makefile | sed 's/^\([^#]\)/    \1/g' | markdown_py > Makefile.html
.PHONY: html



## 1. 基本设置和检查

#调试帮助：可在终端显示颜色字样
COLOR_RED   := $(shell tput setaf 1)
COLOR_GREEN := $(shell tput setaf 2)
COLOR_BLUE := $(shell tput setaf 4)
COLOR_NONE  := $(shell tput sgr0)

#MAKECMDGOALS是一个内置宏
#检查：检查用户在运行makefile时候是否有指定目标（例如run, clean），则会执行下面的语句
ifeq ($(MAKECMDGOALS),) 
  MAKECMDGOALS  = image  #存疑：image是在哪里定义的？
  .DEFAULT_GOAL = image
endif

### 查找MAKECMDGOALS 是不是为clean | clean-all | html其中一个
### 这个if-eq对应的endif到最后一个, 如果MAKECMDGOALS为clean其中一个，那么就不会执行下面的很多语句
ifeq ($(findstring $(MAKECMDGOALS),clean|clean-all|html),)

### 打印build信息
$(info $(COLOR_RED)# Building $(NAME)-$(MAKECMDGOALS) [$(ARCH)]$(COLOR_NONE))

### 检查：检查文件$(AM_HOME)/am/include/am.h是否真的存在
ifeq ($(wildcard $(AM_HOME)/am/include/am.h),)
  $(error $$AM_HOME must be an AbstractMachine repo)
endif

### 检查：环境变量$ARCH必须是$(AM_HOME)/scripts/*.mk其中之一，否则会报错
ARCHS = $(basename $(notdir $(shell ls $(AM_HOME)/scripts/*.mk)))
ifeq ($(filter $(ARCHS), $(ARCH)), )
  $(error Expected $$ARCH in {$(ARCHS)}, Got "$(ARCH)")
endif

### 从$(ARCH)里面解析字段ISA和PLATFORM字段，比如ARCH=riscv32e-nemu, 会被解析成ISA=riscv32e, FLATFORM=nemu
ARCH_SPLIT = $(subst -, ,$(ARCH))
ISA        = $(word 1,$(ARCH_SPLIT))
PLATFORM   = $(word 2,$(ARCH_SPLIT))


### 检查：如果SRCS为空或者未定义，那么就会报一个错误
ifeq ($(flavor SRCS), undefined)
  $(error Nothing to build)
endif

#检查到此结束
#这个endif和ifeq ($(findstring $(MAKECMDGOALS),clean|clean-all|html),)对应
endif  


## 2. 编译目标

#创建目录：/build/$ARCH
#在按下 make run ARCH=$ISA-nemu xxx的之后, ，下面这三个变量会根据被-include Makefile之后有不同值
#查找的线索是 看哪里被创建了/build/$(ARCH)目录 (ARCH的值也会改变，因为是被-include Makefile的)
WORK_DIR  = $(shell pwd)
DST_DIR   = $(WORK_DIR)/build/$(ARCH)
$(shell mkdir -p $(DST_DIR))

# 编译目标，一个二进制镜像 或者 静态库(.a文件)
IMAGE_REL = build/$(NAME)-$(ARCH)
IMAGE     = $(abspath $(IMAGE_REL))
ARCHIVE   = $(WORK_DIR)/build/$(NAME)-$(ARCH).a #归档文件，作为静态库被链接

### Collect the files to be linked: object files (`.o`) and libraries (`.a`)
OBJS      = $(addprefix $(DST_DIR)/, $(addsuffix .o, $(basename $(SRCS))))
LIBS     := $(sort $(LIBS) am klib) # lazy evaluation ("=") causes infinite recursions
LINKAGE   = $(OBJS) \
  $(addsuffix -$(ARCH).a, $(join \
    $(addsuffix /build/, $(addprefix $(AM_HOME)/, $(LIBS))), \
    $(LIBS) ))

## 3. 编译选项
### (Cross) compilers, e.g., mips-linux-gnu-g++
$(info CROSS_COMPILE=$(CROSS_COMPILE))
AS        = $(CROSS_COMPILE)gcc     #汇编器
CC        = $(CROSS_COMPILE)gcc     #C编译器
CXX       = $(CROSS_COMPILE)g++     #C++编译器
LD        = $(CROSS_COMPILE)ld      #链接器
AR        = $(CROSS_COMPILE)ar      #不知道
OBJDUMP   = $(CROSS_COMPILE)objdump #反汇编
OBJCOPY   = $(CROSS_COMPILE)objcopy #文件拷贝
READELF   = $(CROSS_COMPILE)readelf #解析ELF



### [追加]编译选项
# 将include添加到编译选项中
# LIBS被处理，每个被addprefix处理过后的文件会再被addsuffix处理   addprefix是加前缀，addsuffix是加后缀
INC_PATH += $(WORK_DIR)/include $(addsuffix /include/, $(addprefix $(AM_HOME)/, $(LIBS)))
INCFLAGS += $(addprefix -I, $(INC_PATH))   #给每个INC路径加上-I选项

$(info INC_PATH = $(INC_PATH))

ARCH_H := arch/$(ARCH).h
#-D选项是添加预处理器宏
CFLAGS   += -O2 -MMD -Wall -Werror $(INCFLAGS) \
            -D__ISA__=\"$(ISA)\" -D__ISA_$(shell echo $(ISA) | tr a-z A-Z)__ \
            -D__ARCH__=$(ARCH) -D__ARCH_$(shell echo $(ARCH) | tr a-z A-Z | tr - _) \
            -D__PLATFORM__=$(PLATFORM) -D__PLATFORM_$(shell echo $(PLATFORM) | tr a-z A-Z | tr - _) \
            -DARCH_H=\"$(ARCH_H)\" \
            -fno-asynchronous-unwind-tables -fno-builtin -fno-stack-protector \
            -Wno-main -U_FORTIFY_SOURCE -fvisibility=hidden
CXXFLAGS +=  $(CFLAGS) -ffreestanding -fno-rtti -fno-exceptions
ASFLAGS  += -MMD $(INCFLAGS)
LDFLAGS  += -z noexecstack
$(info LDFLAGS=$(LDFLAGS))
## 4. 特定架构的配置

### Paste in arch-specific configurations (e.g., from `scripts/x86_64-qemu.mk`)
#   拷贝特定架构的配置
-include $(AM_HOME)/scripts/$(ARCH).mk
#检查： 首先通过which 找到CC编译器的路径，然后通过wildcard判断编译器路径是否存在
#如果CC不存在， 那么会使用native gcc/binutils
### Fall back to native gcc/binutils if there is no cross compiler
ifeq ($(wildcard $(shell which $(CC))),)
  $(info  $(COLOR_GREEN)$(CC) not found; fall back to default gcc and binutils$(COLOR_NONE))
  CROSS_COMPILE :=
endif

## 5. Compilation Rules
### 使用gcc将每个.c文件编译成.o文件
$(DST_DIR)/%.o: %.c
	@mkdir -p $(dir $@) && echo + CC $<
	@$(CC) -std=gnu11 $(CFLAGS) -c -o $@ $(realpath $<)

### 使用g++将每个.cc文件编译成.o文件
$(DST_DIR)/%.o: %.cc
	@mkdir -p $(dir $@) && echo + CXX $<
	@$(CXX) -std=c++17 $(CXXFLAGS) -c -o $@ $(realpath $<)

### 使用g++将每个.cpp文件编译成.o文件
$(DST_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@) && echo + CXX $<
	@$(CXX) -std=c++17 $(CXXFLAGS) -c -o $@ $(realpath $<)

### Rule (compile): a single `.S` -> `.o` (gcc, which preprocesses and calls as)
$(DST_DIR)/%.o: %.S
	@mkdir -p $(dir $@) && echo + AS $<
	@$(AS) $(ASFLAGS) -c -o $@ $(realpath $<)

### Rule (recursive make): build a dependent library (am, klib, ...)
$(LIBS): %:
	@$(MAKE) -s -C $(AM_HOME)/$* archive

### Rule (link): objects (`*.o`) and libraries (`*.a`) -> `IMAGE.elf`, the final ELF binary to be packed into image (ld)
$(IMAGE).elf: $(OBJS) $(LIBS)
	@echo + LD "->" $(IMAGE_REL).elf
	@$(LD) $(LDFLAGS) -o $(IMAGE).elf --start-group $(LINKAGE) --end-group

### Rule (archive): objects (`*.o`) -> `ARCHIVE.a` (ar)
$(ARCHIVE): $(OBJS)
	@echo + AR "->" $(shell realpath $@ --relative-to .)
	@$(AR) rcs $(ARCHIVE) $(OBJS)

### Rule (`#include` dependencies): paste in `.d` files generated by gcc on `-MMD`
-include $(addprefix $(DST_DIR)/, $(addsuffix .d, $(basename $(SRCS))))

## 6. Miscellaneous

### Build order control
image: image-dep
archive: $(ARCHIVE)
image-dep: $(OBJS) $(LIBS)
	@echo \# Creating image [$(ARCH)]
.PHONY: image image-dep archive run $(LIBS)

### Clean a single project (remove `build/`)
clean:
	rm -rf Makefile.html $(WORK_DIR)/build/
.PHONY: clean

### Clean all sub-projects within depth 2 (and ignore errors)
#CLEAN_ALL是目录
CLEAN_ALL = $(dir $(shell find . -mindepth 2 -name Makefile))
clean-all: $(CLEAN_ALL) clean
$(CLEAN_ALL):
	-@$(MAKE) -s -C $@ clean
.PHONY: clean-all $(CLEAN_ALL)