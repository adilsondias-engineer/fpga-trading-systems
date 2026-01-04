# Ring Buffer Assembly Optimization - SPSC Disruptor Pattern

## Overview

This document describes x86-64 assembly optimizations for the SPSC (Single-Producer Single-Consumer) Disruptor ring buffer pattern used in Projects 24-26.

## Target CPU Features

- **LOCK prefix**: Atomic read-modify-write operations
- **PAUSE**: Spin-wait hint for hyper-threaded CPUs
- **AVX2**: 256-bit SIMD for fast memory copy
- **PREFETCHW/T0**: Cache line prefetching

## Benchmark Results (Intel i9-14900K)

### Atomic Operations

| Operation | std::atomic (ns) | ASM (ns) | Result |
|-----------|------------------|----------|--------|
| Load (acquire) | 0.23 | 0.92 | **std::atomic 4x faster** |
| Store (release) | 0.19 | 0.37 | **std::atomic 2x faster** |
| Fetch-Add | 4.54 | 4.59 | Equivalent |
| SPSC Claim (no LOCK) | N/A | 0.59 | **7.77x faster than fetch_add** |

### Memory Operations

| Operation | Time (ns) | Notes |
|-----------|-----------|-------|
| memcpy 128 bytes | 0.48 | GCC optimizes to AVX |
| ASM AVX2 copy | 0.59 | Function call overhead |
| ASM Non-temporal | 47.56 | SFENCE penalty dominates |
| Full publish cycle | 1.23 | claim + copy + publish |

## Key Findings

### 1. SPSC Claim is the Big Win

The SPSC sequencer claim operation (no LOCK prefix) is **7.77x faster** than `std::atomic::fetch_add`:

```asm
# SPSC claim: ~0.59 ns
sequencer_claim_asm:
    mov     rax, [rdi]      # Load current cursor
    inc     rax             # next = cursor + 1
    mov     [rdi], rax      # Store (no LOCK - single producer!)
    ret

# vs std::atomic::fetch_add: ~4.54 ns (LOCK XADD)
```

**Note**: In SPSC pattern, only one thread writes to the cursor. No LOCK prefix needed because there's no concurrent modification.

### 2. Simple Atomics - Let the Compiler Win

For basic load/store operations, `std::atomic` is faster due to:
- GCC inlines the operation (no function call)
- x86 naturally provides acquire/release semantics
- No function call overhead (~1 ns)

```cpp
// This is faster - let GCC inline it
int64_t val = cursor_.load(std::memory_order_acquire);

// vs external ASM function (function call overhead)
int64_t val = atomic_load_acquire_asm(&cursor_);
```

### 3. Memory Copy - GCC Already Optimal

GCC's memcpy with `-O3 -march=native` already uses AVX2 for aligned 128-byte copies. External ASM is slower due to function call overhead.

### 4. Non-Temporal Stores - Use With Caution

Non-temporal stores (`VMOVNTDQ`) bypass the cache but require `SFENCE` for ordering. The fence is expensive (~30-50 cycles), making NT stores only worthwhile for:
- Very large transfers (KBs)
- Data that won't be read soon
- Streaming patterns

## Recommendations

### Use Assembly For:

1. **SPSC Sequencer Claim**: 7.77x improvement is significant
   ```cpp
   int64_t seq = sequencer_claim_asm(&cursor_);
   ```

2. **Spin-Wait with PAUSE**: Reduces power, improves latency on HT
   ```cpp
   sequencer_wait_for_asm(&cursor_, target_seq);
   ```

3. **Prefetching**: Warm up cache lines before access
   ```cpp
   prefetch_for_write_asm(next_slot);
   ```

### Use std::atomic For:

1. **Simple load/store**: GCC inlines and optimizes
2. **Fetch-add when contention possible**: LOCK prefix is correct
3. **CAS operations**: GCC generates optimal code

### Hybrid Approach (Recommended)

```cpp
class OptimizedSequencer {
public:
    // Use ASM for SPSC claim (7.77x faster)
    int64_t claim() {
        return sequencer_claim_asm(&cursor_);
    }

    // Use ASM for spin-wait (PAUSE instruction)
    void waitFor(int64_t sequence) const {
        sequencer_wait_for_asm(&cursor_, sequence);
    }

    // Use std::atomic for reads (GCC inlines)
    int64_t getCursor() const {
        return cursor_.load(std::memory_order_acquire);
    }

private:
    alignas(64) std::atomic<int64_t> cursor_{-1};
};
```

## Integration with Projects

### Project 25 (Market Maker) - Consumer

```cpp
// Use ASM spin-wait for efficient blocking
void waitForBBO(int64_t sequence) {
    sequencer_wait_for_asm(&producer_cursor_, sequence);
    // PAUSE instruction reduces CPU power while waiting
}
```

### Project 24 (Order Gateway) - Producer

```cpp
// Use ASM claim for SPSC producer
int64_t publishBBO(const BBOData& bbo) {
    int64_t seq = sequencer_claim_asm(&cursor_);
    // Copy to ring buffer slot
    ring_buffer_[seq & mask_] = bbo;
    sequencer_publish_asm(&cursor_, seq);
    return seq;
}
```

## Memory Ordering on x86-64

x86-64 provides strong memory ordering:

| Operation | x86 Behavior | Fence Needed? |
|-----------|--------------|---------------|
| Load → Load | Ordered | No |
| Load → Store | Ordered | No |
| Store → Store | Ordered | No |
| Store → Load | **Reordered** | MFENCE |

For SPSC Disruptor:
- Producer: store-release (naturally ordered on x86)
- Consumer: load-acquire (naturally ordered on x86)
- No explicit fences needed for correctness

## File Locations

- Assembly: [ring_buffer_asm.S](../asm/ring_buffer_asm.S)
- C++ Header: [ring_buffer_asm.h](../asm/ring_buffer_asm.h)
- Benchmark: [ring_buffer_benchmark.cpp](../benchmark/ring_buffer_benchmark.cpp)

## Conclusion

The **SPSC sequencer claim** operation is the clear winner for assembly optimization, providing **7.77x improvement** over `std::atomic::fetch_add`. For other operations, GCC's optimization is sufficient.

The key insight is that SPSC (single-producer single-consumer) allows us to eliminate the expensive LOCK prefix because there's no concurrent modification of the producer's cursor.

**End-to-end impact**: In the full trading pipeline (P24 → P25 → P26), the SPSC claim savings compound:
- P24 publishes BBO: ~4 ns saved
- P25 publishes Order: ~4 ns saved
- P26 publishes Fill: ~4 ns saved
- **Total: ~12 ns saved per round-trip**

This is meaningful in a system targeting sub-microsecond latency.

---

**Author**: Adilson Dias
**Date**: December 2025
**Benchmark Environment**: Intel i9-14900K, GCC 15, Ubuntu 24.04
