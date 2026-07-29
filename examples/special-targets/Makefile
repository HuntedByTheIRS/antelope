# .WAIT and .JOBS examples — GNU Make mode (-gnu)
#
# Usage:
#   antelope -gnu -j4            Build all targets with 4 parallel jobs
#   antelope -gnu clean          Clean build artifacts
#
# .WAIT splits prerequisites into sequential groups:
#   target: group1 .WAIT group2
#   → group1 completes first, then group2 starts
#
# .JOBS limits concurrency for named targets (GNU Make 4.4+):
#   .JOBS: 2 heavy_a heavy_b
#   → at most 2 of {heavy_a, heavy_b} run concurrently

# ── Example 1: .WAIT ordering barrier ──────────────────────────────
#
# In a multi-stage build, .WAIT ensures earlier stages complete
# before later stages begin.  Targets on the same side of .WAIT
# can run in parallel.

all: stage1 stage2 stage3

# Stage 1: independent tasks — all run in parallel
stage1: task_a task_b
	@echo "[stage1] all prerequisite tasks complete"

task_a:
	@echo "[task_a] running..."
	@sleep 0.2
	@echo "[task_a] done"

task_b:
	@echo "[task_b] running..."
	@sleep 0.2
	@echo "[task_b] done"

# Stage 2: must wait for stage1, then runs two tasks in parallel
stage2: stage1 .WAIT task_c task_d
	@echo "[stage2] all prerequisite tasks complete"

task_c:
	@echo "[task_c] running..."
	@sleep 0.3
	@echo "[task_c] done"

task_d:
	@echo "[task_d] running..."
	@sleep 0.3
	@echo "[task_d] done"

# Stage 3: must wait for stage2
stage3: stage2 .WAIT
	@echo "[stage3] final stage complete"

# ── Example 2: .JOBS resource throttle ─────────────────────────────
#
# When some targets are resource-heavy (CPU, memory, I/O), .JOBS
# caps their concurrency while allowing lighter targets to use
# the full global -j limit.

.JOBS: 2 big_compile_a big_compile_b big_compile_c

all_heavy: big_compile_a big_compile_b big_compile_c small_task
	@echo "All done"

big_compile_a:
	@echo "[big_compile_a] compiling..."
	@sleep 0.4
	@echo "[big_compile_a] done"

big_compile_b:
	@echo "[big_compile_b] compiling..."
	@sleep 0.4
	@echo "[big_compile_b] done"

big_compile_c:
	@echo "[big_compile_c] compiling..."
	@sleep 0.4
	@echo "[big_compile_c] done"

small_task:
	@echo "[small_task] done instantly"

# ── Housekeeping ────────────────────────────────────────────────────

.PHONY: all stage1 stage2 stage3 task_a task_b task_c task_d
.PHONY: all_heavy big_compile_a big_compile_b big_compile_c small_task
.PHONY: clean

clean:
	@echo "Cleaning..."
