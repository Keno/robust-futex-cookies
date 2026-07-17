# LKMM litmus tests

Herd7 (7.58) runs against the kernel's own memory model
(`tools/memory-model/linux-kernel.cfg` at the series base):

    herd7 -conf tools/memory-model/linux-kernel.cfg <test>.litmus

| Test | Models | Result |
|------|--------|--------|
| membarrier-shared-rseq-ready.litmus | patch 5 as merged: READY published by atomic_or() + smp_mb__after_atomic(), paired with the fence's leading smp_mb() | **Never** (0 positive / 3 states) |
| membarrier-shared-rseq-ready-broken.litmus | the reviewed defect (issue #2): plain atomic_or() publication, no barrier | **Sometimes** (1 positive / 3 states) |

The forbidden outcome is the store-buffering case: the fence reads
`mm->membarrier_state` without READY (skips the task) while the task's
already-started RSEQ reservation reads the pre-fence generation state.
The `Never` test also ships in the kernel series as
`Documentation/litmus-tests/membarrier/membarrier-shared-rseq-ready.litmus`
(patch 5).
