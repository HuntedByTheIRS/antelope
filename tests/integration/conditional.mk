ARCH = x86
ifeq ($(ARCH),x86)
    CFLAGS = -m32
else
    CFLAGS = -m64
endif
all: ; @echo ARCH=$(ARCH) CFLAGS=$(CFLAGS)
