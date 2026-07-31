# rime.nvim - librime Lua binding
#
# Build rimeshim.so from rime.nobj.c (committed or generated).
#
# Requirements:
#   - C/C++ compiler (clang/macOS or gcc/Linux)
#   - librime (development files)
#
# LuaJIT headers are bundled in include/ -- no need to install luajit.
#
# Usage:
#   make                                          # auto-detect librime
#   make LIBRIME_DIR=/opt/homebrew/opt/librime    # explicit path

# --- LuaJIT (bundled) ---
LUAJIT_CFLAGS := -Iinclude

# --- librime ---
ifdef LIBRIME_DIR
  LIBRIME_CFLAGS := -I$(LIBRIME_DIR)/include
  LIBRIME_LIBS   := -L$(LIBRIME_DIR)/lib -lrime
else
  LIBRIME_CFLAGS := $(shell \
    pkg-config --cflags rime 2>/dev/null || \
    (test -d /opt/homebrew/opt/librime && echo "-I/opt/homebrew/opt/librime/include") || \
    (test -d /usr/local/opt/librime && echo "-I/usr/local/opt/librime/include") || \
    echo "-I/usr/local/include")
  LIBRIME_LIBS := $(shell \
    pkg-config --libs rime 2>/dev/null || \
    (test -d /opt/homebrew/opt/librime && echo "-L/opt/homebrew/opt/librime/lib -lrime") || \
    (test -d /usr/local/opt/librime && echo "-L/usr/local/opt/librime/lib -lrime") || \
    echo "-L/usr/local/lib -lrime")
endif

CFLAGS ?= -O3 -Wno-int-conversion

# 平台相关的链接参数：
#   macOS: -bundle -undefined dynamic_lookup（clang 构建 Lua 模块）
#   Linux: -shared（gcc/g++ 构建共享库，未定义符号默认允许、运行时解析）
ifeq ($(shell uname), Darwin)
  LUA_MODULE_LDFLAGS := -bundle -undefined dynamic_lookup
else
  LUA_MODULE_LDFLAGS := -shared
endif

# .c 依赖所有 .nobj.lua（rime.nobj.lua 通过 subfiles 引用 src/*.nobj.lua）
NOBJ_DEPS := rime.nobj.lua src/traits.nobj.lua src/session.nobj.lua

all: lua/rimeshim.so

lua/rimeshim.so: rime.nobj.c
	$(CC) -c $(CFLAGS) $(LUAJIT_CFLAGS) $(LIBRIME_CFLAGS) -o rime.nobj.o rime.nobj.c
	$(CXX) -o lua/rimeshim.so rime.nobj.o $(LIBRIME_LIBS) $(LUA_MODULE_LDFLAGS)

clean:
	rm -f rime.nobj.o lua/rimeshim.so

.PHONY: all clean fix_rpath
