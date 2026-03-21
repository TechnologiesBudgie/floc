# =============================================================================
# Makefile — FLOC (Fast Lines Of Code)
#
# Requirements:
#   Linux / macOS: gfortran >= 9, gcc, GNU make
#   Windows:       MinGW-w64 gfortran + gcc  (or WSL/MSYS2)
#
# Targets:
#   make            Build optimised binary  → floc
#   make debug      Build debug binary      → floc_debug
#   make clean      Remove generated files
#   make install    Install to PREFIX/bin   (default PREFIX=/usr/local)
#
# Performance flags:
#   -O3 -march=native   Maximum scalar optimisations + SIMD for the byte loops
#   -fopenmp            Enable OpenMP parallel region
#   -funroll-loops      Unroll inner state-machine loops
#   -ffast-math         Safe for integer/char arithmetic in this code
# =============================================================================

FC      := gfortran
CC      := gcc
LD      := gfortran

PREFIX  ?= /usr/local

# Detect OS for platform-specific flags
UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)

ifeq ($(UNAME_S),Darwin)
  OPENMP_FLAGS := -Xpreprocessor -fopenmp -lomp
  # macOS: OpenMP via libomp (brew install libomp)
  OPENMP_INC   := $(shell brew --prefix libomp 2>/dev/null)/include
  OPENMP_LIB   := $(shell brew --prefix libomp 2>/dev/null)/lib
  ifneq ($(OPENMP_INC),)
    OPENMP_FLAGS := -Xpreprocessor -fopenmp -I$(OPENMP_INC) -L$(OPENMP_LIB) -lomp
  endif
else ifeq ($(UNAME_S),Windows)
  OPENMP_FLAGS := -fopenmp
  EXE_SUFFIX   := .exe
else
  # Linux default
  OPENMP_FLAGS := -fopenmp
  EXE_SUFFIX   :=
endif

# ── Compiler flags ────────────────────────────────────────────────────────────
FFLAGS_COMMON := -std=f2008 -Wall -Wextra -Wno-unused-parameter \
                 -fbacktrace $(OPENMP_FLAGS)

FFLAGS_OPT    := -O3 -march=native -funroll-loops \
                 -finline-functions $(FFLAGS_COMMON)

FFLAGS_DEBUG  := -O0 -g -fcheck=all -fdump-fortran-original $(FFLAGS_COMMON)

CFLAGS        := -O3 -march=native -Wall

# ── Sources (order matters: modules before programs that USE them) ─────────────
SRC_DIR := src
OBJ_DIR := build

MOD_SRCS := \
    $(SRC_DIR)/floc_lang_defs.f90  \
    $(SRC_DIR)/floc_string_utils.f90 \
    $(SRC_DIR)/floc_cdir.f90       \
    $(SRC_DIR)/floc_counter.f90

MAIN_SRC := $(SRC_DIR)/floc_main.f90
C_SRC    := $(SRC_DIR)/dir_helper.c

# ── Object files ───────────────────────────────────────────────────────────────
MOD_OBJS  := $(patsubst $(SRC_DIR)/%.f90, $(OBJ_DIR)/%.o, $(MOD_SRCS))
MAIN_OBJ  := $(OBJ_DIR)/floc_main.o
C_OBJ     := $(OBJ_DIR)/dir_helper.o

ALL_OBJS  := $(MOD_OBJS) $(MAIN_OBJ) $(C_OBJ)

TARGET    := floc$(EXE_SUFFIX)
TARGET_DBG:= floc_debug$(EXE_SUFFIX)

# ── Default target ─────────────────────────────────────────────────────────────
.PHONY: all debug clean install test

all: $(OBJ_DIR) $(TARGET)

debug: FFLAGS_OPT := $(FFLAGS_DEBUG)
debug: $(OBJ_DIR) $(TARGET_DBG)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

# ── Link ───────────────────────────────────────────────────────────────────────
$(TARGET): $(ALL_OBJS)
	$(LD) $(FFLAGS_OPT) -o $@ $^
	@echo ""
	@echo "  ✓  Built:  $@"
	@echo "  Run:  ./$@ --help"

$(TARGET_DBG): $(ALL_OBJS)
	$(LD) $(FFLAGS_DEBUG) -o $@ $^

# ── Compile C helper ─────────────────────────────────────────────────────────
$(OBJ_DIR)/dir_helper.o: $(C_SRC)
	$(CC) $(CFLAGS) -c -o $@ $<

# ── Compile Fortran modules (in dependency order) ─────────────────────────────
$(OBJ_DIR)/floc_lang_defs.o: $(SRC_DIR)/floc_lang_defs.f90
	$(FC) $(FFLAGS_OPT) -J$(OBJ_DIR) -c -o $@ $<

$(OBJ_DIR)/floc_string_utils.o: $(SRC_DIR)/floc_string_utils.f90
	$(FC) $(FFLAGS_OPT) -J$(OBJ_DIR) -c -o $@ $<

$(OBJ_DIR)/floc_cdir.o: $(SRC_DIR)/floc_cdir.f90
	$(FC) $(FFLAGS_OPT) -J$(OBJ_DIR) -c -o $@ $<

$(OBJ_DIR)/floc_counter.o: $(SRC_DIR)/floc_counter.f90 \
                             $(OBJ_DIR)/floc_lang_defs.o \
                             $(OBJ_DIR)/floc_string_utils.o
	$(FC) $(FFLAGS_OPT) -J$(OBJ_DIR) -I$(OBJ_DIR) -c -o $@ $<

$(OBJ_DIR)/floc_main.o: $(SRC_DIR)/floc_main.f90 \
                          $(OBJ_DIR)/floc_lang_defs.o  \
                          $(OBJ_DIR)/floc_counter.o    \
                          $(OBJ_DIR)/floc_cdir.o
	$(FC) $(FFLAGS_OPT) -J$(OBJ_DIR) -I$(OBJ_DIR) -c -o $@ $<

# ── Clean ──────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(OBJ_DIR) $(TARGET) $(TARGET_DBG) *.mod

# ── Install ────────────────────────────────────────────────────────────────────
install: $(TARGET)
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)
	@echo "Installed to $(PREFIX)/bin/$(TARGET)"

# ── Quick self-test ────────────────────────────────────────────────────────────
test: $(TARGET)
	@echo "--- Self-test: counting the FLOC source tree ---"
	./$(TARGET) src/
