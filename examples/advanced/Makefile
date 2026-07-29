# Advanced Makefile showcasing pattern rules, VPATH, conditionals,
# functions, automatic variables, and target-specific variables.
#
# Usage: antelope -gnu           (builds "all")
#        antelope -gnu DEBUG=1   (debug build)
#        antelope -gnu check     (run the test target)
#        antelope -gnu clean     (clean build artifacts)

# ---- Project Configuration ----

PROJECT   = myapp
SRCDIR    = src
BUILDDIR  = build
VPATH     = $(SRCDIR)

# ---- Conditional Configuration ----

ifeq ($(DEBUG),1)
    CFLAGS = -g -O0 -DDEBUG
    BUILDDIR = build/debug
else
    CFLAGS = -O2 -DNDEBUG
    BUILDDIR = build/release
endif

# ---- Auto-discovered sources ----

SRCS := $(notdir $(wildcard $(SRCDIR)/*.c))
OBJS := $(patsubst %.c,$(BUILDDIR)/%.o,$(SRCS))

# ---- Targets ----

.PHONY: all clean check

all: $(BUILDDIR)/$(PROJECT)

# Output directory creation (order-only prerequisite — timestamp doesn't
# trigger rebuild, but the directory must exist before the recipe runs).
$(BUILDDIR)/$(PROJECT): $(OBJS) | $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $^

# Pattern rule: build .o from .c, placing output in BUILDDIR
$(BUILDDIR)/%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Create the output directory
$(BUILDDIR):
	mkdir -p $@

# ---- Per-target variables (release target gets extra optimization) ----

$(BUILDDIR)/release/$(PROJECT): CFLAGS += -flto

# ---- Utility targets ----

check: $(BUILDDIR)/$(PROJECT)
	@echo "Running tests..."
	./$(BUILDDIR)/$(PROJECT) --test
	@echo "All tests passed."

clean:
	rm -rf $(BUILDDIR)

# ---- Informational ----

info:
	$(info Project:    $(PROJECT))
	$(info Sources:    $(SRCS))
	$(info Objects:    $(OBJS))
	$(info CFLAGS:     $(CFLAGS))
	$(info Build dir:  $(BUILDDIR))
