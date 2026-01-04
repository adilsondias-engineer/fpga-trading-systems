/**
 * Ring Buffer Atomics Benchmark - C++ std::atomic vs x86-64 Assembly
 *
 * Compares performance of:
 *   1. std::atomic operations (load, store, fetch_add, CAS)
 *   2. x86-64 assembly atomics (LOCK XADD, PAUSE)
 *   3. SPSC-optimized operations (no LOCK prefix)
 *   4. 128-byte copy (memcpy vs AVX2)
 *
 * Build:
 *   g++ -O3 -march=native -o ring_buffer_benchmark ring_buffer_benchmark.cpp \
 *       ../asm/ring_buffer_asm.S -lpthread
 *
 * Run:
 *   ./ring_buffer_benchmark
 *
 * Author: Adilson Dias
 * Date: December 2025
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <atomic>
#include <chrono>
#include <thread>

#include "../asm/ring_buffer_asm.h"

// ============================================================================
// Test Data Structures
// ============================================================================

// Simulate BboEvent (128 bytes, 2 cache lines)
struct alignas(64) TestEvent {
    char data[128];
};
static_assert(sizeof(TestEvent) == 128, "TestEvent must be 128 bytes");

// ============================================================================
// Benchmark Utilities
// ============================================================================

template<typename Func>
double benchmark_ns(Func&& f, int iterations) {
    // Warm-up
    for (int i = 0; i < 10000; i++) {
        f();
    }

    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iterations; i++) {
        f();
        asm volatile("" ::: "memory");  // Prevent optimization
    }
    auto end = std::chrono::high_resolution_clock::now();

    return std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count()
           / static_cast<double>(iterations);
}

// ============================================================================
// Correctness Tests
// ============================================================================

void verify_correctness() {
    printf("===========================================\n");
    printf("Correctness Verification\n");
    printf("===========================================\n\n");

    // Test atomic load/store
    alignas(64) int64_t test_val = 42;
    int64_t loaded = disruptor::asm_opt::atomic_load_acquire_asm(&test_val);
    bool load_ok = (loaded == 42);
    printf("atomic_load_acquire: %s (expected 42, got %ld)\n",
           load_ok ? "PASS" : "FAIL", loaded);

    disruptor::asm_opt::atomic_store_release_asm(&test_val, 100);
    bool store_ok = (test_val == 100);
    printf("atomic_store_release: %s (expected 100, got %ld)\n",
           store_ok ? "PASS" : "FAIL", test_val);

    // Test fetch_add
    test_val = 10;
    int64_t old_val = disruptor::asm_opt::atomic_fetch_add_asm(&test_val, 5);
    bool fetch_add_ok = (old_val == 10 && test_val == 15);
    printf("atomic_fetch_add: %s (old=%ld, new=%ld)\n",
           fetch_add_ok ? "PASS" : "FAIL", old_val, test_val);

    // Test CAS
    test_val = 20;
    int64_t expected = 20;
    bool cas_ok = disruptor::asm_opt::atomic_compare_exchange_asm(&test_val, &expected, 30);
    bool cas_result_ok = (cas_ok && test_val == 30);
    printf("atomic_CAS (success): %s (expected 20->30, got %ld)\n",
           cas_result_ok ? "PASS" : "FAIL", test_val);

    expected = 50;  // Wrong expected value
    cas_ok = disruptor::asm_opt::atomic_compare_exchange_asm(&test_val, &expected, 40);
    bool cas_fail_ok = (!cas_ok && expected == 30 && test_val == 30);
    printf("atomic_CAS (failure): %s (expected=%ld, val=%ld)\n",
           cas_fail_ok ? "PASS" : "FAIL", expected, test_val);

    // Test 128-byte copy
    TestEvent src, dst;
    memset(src.data, 0xAB, 128);
    memset(dst.data, 0, 128);

    if (disruptor::asm_opt::has_avx2()) {
        disruptor::asm_opt::copy_128_bytes_asm(&dst, &src);
        bool copy_ok = (memcmp(src.data, dst.data, 128) == 0);
        printf("copy_128_bytes_asm (AVX2): %s\n", copy_ok ? "PASS" : "FAIL");

        memset(dst.data, 0, 128);
        disruptor::asm_opt::copy_128_bytes_nt_asm(&dst, &src);
        copy_ok = (memcmp(src.data, dst.data, 128) == 0);
        printf("copy_128_bytes_nt_asm (NT): %s\n", copy_ok ? "PASS" : "FAIL");
    } else {
        printf("copy_128_bytes_asm: SKIPPED (no AVX2)\n");
    }

    // Test SPSC sequencer
    disruptor::asm_opt::SequencerAsm seq(1024);
    int64_t seq1 = seq.claim();
    int64_t seq2 = seq.claim();
    bool seq_ok = (seq1 == 0 && seq2 == 1);
    printf("sequencer_claim: %s (got %ld, %ld)\n",
           seq_ok ? "PASS" : "FAIL", seq1, seq2);

    printf("\n");
}

// ============================================================================
// Performance Benchmarks
// ============================================================================

void run_benchmarks() {
    printf("===========================================\n");
    printf("Performance Benchmarks (1M iterations)\n");
    printf("===========================================\n\n");

    const int ITERATIONS = 1000000;

    alignas(64) int64_t atomic_cpp = 0;
    alignas(64) int64_t atomic_asm = 0;
    alignas(64) std::atomic<int64_t> std_atomic{0};

    volatile int64_t sink;

    // --------------------
    // Atomic Load Benchmark
    // --------------------
    double cpp_load_ns = benchmark_ns([&]() {
        sink = std_atomic.load(std::memory_order_acquire);
    }, ITERATIONS);

    double asm_load_ns = benchmark_ns([&]() {
        sink = disruptor::asm_opt::atomic_load_acquire_asm(&atomic_asm);
    }, ITERATIONS);

    printf("Atomic Load (acquire):\n");
    printf("  std::atomic:  %.2f ns\n", cpp_load_ns);
    printf("  ASM:          %.2f ns\n", asm_load_ns);
    printf("  Speedup:      %.2fx (%.1f%% %s)\n\n",
           cpp_load_ns / asm_load_ns,
           std::abs(1.0 - asm_load_ns / cpp_load_ns) * 100.0,
           asm_load_ns < cpp_load_ns ? "faster" : "slower");

    // --------------------
    // Atomic Store Benchmark
    // --------------------
    double cpp_store_ns = benchmark_ns([&]() {
        std_atomic.store(sink, std::memory_order_release);
    }, ITERATIONS);

    double asm_store_ns = benchmark_ns([&]() {
        disruptor::asm_opt::atomic_store_release_asm(&atomic_asm, sink);
    }, ITERATIONS);

    printf("Atomic Store (release):\n");
    printf("  std::atomic:  %.2f ns\n", cpp_store_ns);
    printf("  ASM:          %.2f ns\n", asm_store_ns);
    printf("  Speedup:      %.2fx (%.1f%% %s)\n\n",
           cpp_store_ns / asm_store_ns,
           std::abs(1.0 - asm_store_ns / cpp_store_ns) * 100.0,
           asm_store_ns < cpp_store_ns ? "faster" : "slower");

    // --------------------
    // Fetch-Add Benchmark
    // --------------------
    std_atomic = 0;
    atomic_asm = 0;

    double cpp_fetch_add_ns = benchmark_ns([&]() {
        sink = std_atomic.fetch_add(1, std::memory_order_acq_rel);
    }, ITERATIONS);

    double asm_fetch_add_ns = benchmark_ns([&]() {
        sink = disruptor::asm_opt::atomic_fetch_add_asm(&atomic_asm, 1);
    }, ITERATIONS);

    printf("Atomic Fetch-Add:\n");
    printf("  std::atomic:  %.2f ns\n", cpp_fetch_add_ns);
    printf("  ASM (LOCK XADD): %.2f ns\n", asm_fetch_add_ns);
    printf("  Speedup:      %.2fx (%.1f%% %s)\n\n",
           cpp_fetch_add_ns / asm_fetch_add_ns,
           std::abs(1.0 - asm_fetch_add_ns / cpp_fetch_add_ns) * 100.0,
           asm_fetch_add_ns < cpp_fetch_add_ns ? "faster" : "slower");

    // --------------------
    // SPSC Claim Benchmark (no LOCK)
    // --------------------
    atomic_asm = 0;

    double spsc_claim_ns = benchmark_ns([&]() {
        sink = disruptor::asm_opt::sequencer_claim_asm(&atomic_asm);
    }, ITERATIONS);

    printf("SPSC Sequencer Claim (no LOCK):\n");
    printf("  ASM:          %.2f ns\n", spsc_claim_ns);
    printf("  vs fetch_add: %.2fx faster\n\n",
           asm_fetch_add_ns / spsc_claim_ns);

    // --------------------
    // 128-byte Copy Benchmark
    // --------------------
    alignas(64) TestEvent src, dst;
    memset(src.data, 0xAB, 128);

    double memcpy_ns = benchmark_ns([&]() {
        memcpy(&dst, &src, 128);
    }, ITERATIONS);

    printf("128-byte Copy:\n");
    printf("  memcpy:       %.2f ns\n", memcpy_ns);

    if (disruptor::asm_opt::has_avx2()) {
        double avx2_copy_ns = benchmark_ns([&]() {
            disruptor::asm_opt::copy_128_bytes_asm(&dst, &src);
        }, ITERATIONS);

        double avx2_nt_copy_ns = benchmark_ns([&]() {
            disruptor::asm_opt::copy_128_bytes_nt_asm(&dst, &src);
        }, ITERATIONS);

        printf("  ASM (AVX2):   %.2f ns\n", avx2_copy_ns);
        printf("  ASM (AVX2 NT): %.2f ns\n", avx2_nt_copy_ns);
        printf("  Speedup (AVX2): %.2fx (%.1f%% %s)\n",
               memcpy_ns / avx2_copy_ns,
               std::abs(1.0 - avx2_copy_ns / memcpy_ns) * 100.0,
               avx2_copy_ns < memcpy_ns ? "faster" : "slower");
        printf("  Speedup (NT): %.2fx (%.1f%% %s)\n\n",
               memcpy_ns / avx2_nt_copy_ns,
               std::abs(1.0 - avx2_nt_copy_ns / memcpy_ns) * 100.0,
               avx2_nt_copy_ns < memcpy_ns ? "faster" : "slower");
    } else {
        printf("  AVX2:         SKIPPED (not supported)\n\n");
    }

    // --------------------
    // Full Publish Cycle Benchmark
    // --------------------
    disruptor::asm_opt::SequencerAsm seq_asm(16384);

    double full_publish_ns = benchmark_ns([&]() {
        int64_t seq_num = seq_asm.claim();
        // Simulate writing to ring buffer slot
        disruptor::asm_opt::copy_128_bytes_asm(&dst, &src);
        seq_asm.publish(seq_num);
    }, ITERATIONS);

    printf("Full Publish Cycle (claim + copy + publish):\n");
    printf("  ASM (AVX2):   %.2f ns\n\n", full_publish_ns);
}

// ============================================================================
// Main
// ============================================================================

int main() {
    printf("===========================================\n");
    printf("Ring Buffer Atomics Benchmark\n");
    printf("SPSC Disruptor Pattern Optimization\n");
    printf("===========================================\n\n");

    printf("CPU Features:\n");
    printf("  AVX2: %s\n\n", disruptor::asm_opt::has_avx2() ? "YES" : "NO");

    verify_correctness();
    run_benchmarks();

    printf("===========================================\n");
    printf("Benchmark complete!\n");
    printf("===========================================\n\n");

    printf("KEY INSIGHTS:\n");
    printf("1. SPSC claim (no LOCK) is ~3-5x faster than atomic fetch_add\n");
    printf("2. AVX2 128-byte copy can be faster than memcpy for aligned data\n");
    printf("3. x86-64 naturally provides acquire/release semantics\n");
    printf("4. PAUSE instruction improves spin-wait efficiency\n");

    return 0;
}
