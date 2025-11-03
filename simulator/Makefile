TOPNAME :=CPU
CPU_DIR=$(CPU_HOME)/IP/pipeline-cpu



PREFIX_NAME:=npc
SRC_DIR:=$(SIM_HOME)/src
TOPNAME_FLAG = --top-module $(TOPNAME)
PREFIX_FLAG  = --prefix $(PREFIX_NAME)

VL_ROOT_HEADER=\\\"$(PREFIX_NAME).h\\\"


VERILATOR = verilator
VERILATOR_CFLAGS += -MMD --build -j 8 -trace -cc -O0 --x-assign fast --x-initial fast --noassert -I$(CPU_DIR)
VERILATOR_CFLAGS += $(TOPNAME_FLAG)
VERILATOR_CFLAGS += $(PREFIX_FLAG)


BUILD_DIR = $(SIM_HOME)/build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

default: $(BIN)
$(shell mkdir -p $(BUILD_DIR))

# project source
VSRCS = $(shell find $(abspath $(CPU_DIR)) -name "*.v")
CSRCS = $(shell find $(abspath $(SRC_DIR)) -name "*.c" -o -name "*.cpp" -o -name "*.cc")
#header 

INC_DIR  := $(SIM_HOME)/include

INC_PATH = $(INC_DIR) $(INC_DIR)/utils $(INC_DIR)/generated

LDFLAGS += -lreadline -lhistory -ldl -pie $(shell llvm-config --libs)

# rules for verilator
INCFLAGS := $(addprefix -I, $(INC_PATH) )

#这个-fpermissive要暂时放到-D宏后面，暂时不清楚依赖关系
CXXFLAGS += $(INCFLAGS)
CXXFLAGS += -DTOP_NAME=$(PREFIX_NAME) -DVL_ROOT_HEADER=$(VL_ROOT_HEADER) -DVL_DPI_HEADER=$(VL_DPI_HEADER)
CXXFLAGS += -fpermissive

$(BIN): $(VSRCS) $(CSRCS)
	$(shell mkdir -p $(BUILD_DIR))
	@-rm -rf $(OBJ_DIR)
	@rm -f waveform.vcd
	$(VERILATOR) $(VERILATOR_CFLAGS) $^    \
		$(addprefix -CFLAGS ,  $(CXXFLAGS)) \
		$(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

override ARGS ?= --log=$(BUILD_DIR)/npc-log.txt
override ARGS += --diff=$(SIM_HOME)/nemu/riscv32-nemu-interpreter-so
override ARGS += --batch

all: default

run: clean $(BIN)
	$(BIN) $(ARGS) $(IMAGE)
sim: 
	gtkwave waveform.vcd

clean:
	rm -rf $(BUILD_DIR)
	rm -f waveform.vcd


.PHONY: default all clean run sim