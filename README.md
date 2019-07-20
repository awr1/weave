# Weave - experiments in threading in Nim

This repo will store my experiments in a threading runtime.

This is also a good pretext to try the new Nim runtime and memory safety semantics:

https://github.com/nim-lang/Nim/wiki/Destructors,-2nd-edition#sink-parameters


## Challenges

My research is stored in laser repo:
https://github.com/numforge/laser/blob/master/research/runtime_threads_tasks_allocation_NUMA.md

1. Child-stealing vs continuation stealing
2. Cactus stacks, environment capture, destructors and races
3. Child stealing:
   - Allocator overhead
   - Space for unbounded child task allocations
4. Continuation stealing:
   - Implementation of checking if continuation was stolen
   - references to local storage if the continuing thread
     is not the parent thread
5. Ergonomics: tasks as closures vs tasks as objects

Bonus

6. NUMA-aware scheduling
7. Heterogenous computing (some tasks on GPUs, some on CPUs)
