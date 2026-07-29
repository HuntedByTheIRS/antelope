# Parallel build example — multiple independent sub-projects
#
# Usage: antelope -gnu -j4    (build all modules in parallel with 4 jobs)
#        antelope -gnu -j0    (build with unlimited parallelism)
#        antelope -gnu clean  (clean all modules)

SUBDIRS = module_a module_b module_c

.PHONY: all clean $(SUBDIRS)

all clean: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@ $(MAKECMDGOALS)

# .WAIT ensures module_c starts only after module_a and module_b finish.
module_c: module_a module_b .WAIT
