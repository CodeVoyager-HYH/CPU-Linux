ifneq ($(CONFIG_ITRACE)$(CONFIG_IQUEUE),)
CXXSRC = $(NPC_HOME)src/utils/disasm.cc
CXXFLAGS += $(shell llvm-config --cxxflags) -fPIE
LIBS += $(shell llvm-config --libs)
endif
