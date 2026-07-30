# rime.nvim - librime Lua binding
#
# Build rime.so from rime.nobj.c (committed or generated).
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

# .c 依赖所有 .nobj.lua（rime.nobj.lua 通过 subfiles 引用 src/*.nobj.lua）
NOBJ_DEPS := rime.nobj.lua src/traits.nobj.lua src/session.nobj.lua

all: lua/rime.so

rime.nobj.c: $(NOBJ_DEPS)
	@echo "  → $@ 需要更新"
	if command -v native_objects >/dev/null 2>&1; then \
	  echo "  用 native_objects 生成..."; \
	  native_objects -outpath . -gen lua rime.nobj.lua; \
	else \
	  echo "  ❌ native_objects 不可用，无法重新生成 $@"; \
	fi

lua/rime.so: rime.nobj.c
	$(CC) -c $(CFLAGS) $(LUAJIT_CFLAGS) $(LIBRIME_CFLAGS) -o rime.nobj.o rime.nobj.c
	$(CXX) -o lua/rime.so rime.nobj.o $(LIBRIME_LIBS) -bundle -undefined dynamic_lookup

clean:
	rm -f rime.nobj.o lua/rime.so

.PHONY: all clean fix_rpath
