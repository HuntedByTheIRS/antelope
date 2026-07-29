# Basic GNU Make build — uses implicit rules
#
# Usage: antelope -gnu         (builds "all" using implicit rules)
#        antelope -gnu clean   (cleans build artifacts)
#
# In GNU mode, the %.o: %.c implicit rule handles hello.c → hello.o for free.

all: hello

hello: hello.o

.PHONY: clean

clean:
	rm -f hello hello.o
