/*
 * ============================================================================
 * Phase 18B: 64-bit AXI-Stream Tiled Matrix Multiply with 16-Column PE Path
 *            and True K-Tile Prefetch Overlap
 *
 * Description:
 *   This is the final optimized bare-metal C application running on the Zynq ARM PS.
 *   The software coordinates the hardware acceleration process:
 *     1. Generates input matrices (A and B) filled with random signed int8 elements.
 *     2. Computes the baseline matrix multiplication in software to act as the "golden reference".
 *     3. Pre-extracts and pre-packs the 32x32 tiles of A and B into contiguous 64-bit DMA
 *        input stream arrays (8 x int8 elements per u64 word) to avoid run-time memory overhead.
 *     4. Configures registers of the custom PL accelerator through AXI-Lite.
 *     5. Orchestrates the AXI DMA transfers (transmitting inputs and receiving outputs)
 *        with cache flushing and invalidation to maintain memory consistency.
 *     6. Unpacks the 64-bit streamed results (2 x int32 elements per u64 word) into the output C matrix.
 *     7. Measures execution time, computes the relative speedup, and performs bit-accurate verification.
 * ============================================================================
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "xaxidma.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "platform.h"
#include "xtime_l.h"

// Hardware Mapping & Offsets
#define DMA_DEV_ID   XPAR_AXIDMA_0_DEVICE_ID
#define ACCEL_BASE   XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR

// AXI4-Lite Register Offsets mapped to Custom PL IP
#define REG_CTRL        0x00 // Bit 0: Start execution
#define REG_STATUS      0x04 // Bit 0: Done flag, Bit 1: Busy flag
#define REG_M           0x08 // M dimension (rows of A / C)
#define REG_K           0x0C // K dimension (columns of A / rows of B)
#define REG_N           0x10 // N dimension (columns of B / C)
#define REG_NUM_KTILES  0x14 // Total K-tiles (e.g. 2 for 64x64 matrix tiled into 32x32)

// Matrix Dimension Configurations
#define FULL_SIZE       64   // Global matrix size (64x64 elements)
#define TILE            32   // Hardware BRAM tile dimension (32x32 elements)
#define NUM_TILES       (FULL_SIZE / TILE)   // Number of tiles along row/col dimension
#define NUM_KTILES      NUM_TILES            // Number of tiles along inner K dimension
#define NUM_OUT_TILES   (NUM_TILES * NUM_TILES) // Total output sub-blocks (4 tiles for 64x64)

// Memory Size and Sizing Computations
#define TILE_BYTES      (TILE * TILE)            // 32x32 = 1024 bytes per input tile
#define TILE_WORDS_64   ((TILE_BYTES + 7) / 8)   // 128 words of 64-bit (holds 1024 bytes)

// Input stream packet size: holds A tile + B tile per K-tile step.
// For K-tile 0, it holds [A0, B0], for K-tile 1 it holds [A1, B1], etc.
#define INPUT_WORDS_64  (NUM_KTILES * 2 * TILE_WORDS_64)

// Output stream packet size: holds C tile (1024 elements of int32 = 4096 bytes).
// Pack 2 x 32-bit integers into a single 64-bit beat = 512 words.
#define OUTPUT_WORDS_64 ((TILE * TILE) / 2)

// Safety limit to prevent software locks if hardware hangs
#define TIMEOUT_COUNT   10000000

// Memory Allocations
int8_t  A_full[FULL_SIZE * FULL_SIZE];
int8_t  B_full[FULL_SIZE * FULL_SIZE];
int32_t C_sw[FULL_SIZE * FULL_SIZE];
int32_t C_hw[FULL_SIZE * FULL_SIZE];

// Contiguous DDR Stream Buffers (64-byte aligned for optimal AXI DMA burst efficiency)
u64 input_streams[NUM_OUT_TILES][INPUT_WORDS_64] __attribute__((aligned(64)));
u64 output_tile[OUTPUT_WORDS_64] __attribute__((aligned(64)));

int8_t A_tile[TILE * TILE];
int8_t B_tile[TILE * TILE];

// LCG random generator seed
static unsigned int seed = 77777;

/*
 * Helper to compute elapsed seconds from hardware high-resolution timer cycles (XTime)
 */
double elapsed_seconds(XTime start, XTime end)
{
    return (double)(end - start) / (double)COUNTS_PER_SECOND;
}

/*
 * Linear Congruential Generator (LCG) to fill matrices with small signed integers (-5 to +5).
 * Small integers make debugging mismatches and identifying overflow/underflow points easier.
 */
int8_t my_rand(void)
{
    seed = seed * 1103515245 + 12345;
    return (int8_t)((seed >> 16) % 11) - 5;
}

/*
 * Pack 8 signed 8-bit integers into a single 64-bit unsigned word.
 * This matches the 64-bit stream width on the AXI-Stream bus.
 */
void pack_i8_64(const int8_t *src, u64 *dst, int num_bytes)
{
    int num_words = (num_bytes + 7) / 8;

    for (int w = 0; w < num_words; w++) {
        u64 word = 0;

        for (int b = 0; b < 8; b++) {
            int idx = w * 8 + b;

            if (idx < num_bytes) {
                word |= ((u64)(uint8_t)src[idx]) << (b * 8);
            }
        }

        dst[w] = word;
    }
}

/*
 * Unpack a single 32-bit signed integer from a 64-bit unsigned stream word.
 * Lane 0 represents the lower 32 bits, Lane 1 represents the upper 32 bits.
 */
static inline int32_t unpack_i32_from_u64(u64 word, int lane)
{
    if (lane == 0) {
        return (int32_t)(uint32_t)(word & 0xFFFFFFFFULL);
    }

    return (int32_t)(uint32_t)((word >> 32) & 0xFFFFFFFFULL);
}

/*
 * Extract a 32x32 submatrix (tile) from the full 64x64 row-major matrix.
 */
void extract_tile(const int8_t *full,
                  int8_t *tile,
                  int row_start,
                  int col_start,
                  int full_cols)
{
    for (int i = 0; i < TILE; i++) {
        for (int j = 0; j < TILE; j++) {
            tile[i * TILE + j] =
                full[(row_start + i) * full_cols + (col_start + j)];
        }
    }
}

/*
 * Pre-packages the tiles of A and B into the exact AXI-Stream 64-bit layout.
 * Moving this layout formatting out of the timed benchmark loop isolates the
 * raw hardware computation and DMA streaming times.
 */
void build_packed_streams(void)
{
    for (int ti = 0; ti < NUM_TILES; ti++) {
        for (int tj = 0; tj < NUM_TILES; tj++) {
            int out_tile_idx = ti * NUM_TILES + tj;

            for (int tk = 0; tk < NUM_KTILES; tk++) {
                int base = tk * 2 * TILE_WORDS_64;

                // Extract and pack tile A
                extract_tile(A_full,
                             A_tile,
                             ti * TILE,
                             tk * TILE,
                             FULL_SIZE);

                // Extract and pack tile B
                extract_tile(B_full,
                             B_tile,
                             tk * TILE,
                             tj * TILE,
                             FULL_SIZE);

                pack_i8_64(A_tile,
                           &input_streams[out_tile_idx][base],
                           TILE_BYTES);

                pack_i8_64(B_tile,
                           &input_streams[out_tile_idx][base + TILE_WORDS_64],
                           TILE_BYTES);
            }
        }
    }
}

/*
 * Process a single 32x32 output block C(ti, tj) through the hardware accelerator.
 * Handles the registers, cache coherency flushes/invalidates, and AXI DMA transfers.
 */
int run_one_output_tile(XAxiDma *dma, u64 *input_stream, int ti, int tj)
{
    int status;
    int timeout;

    // 1. Program the accelerator configuration registers
    Xil_Out32(ACCEL_BASE + REG_M, TILE);
    Xil_Out32(ACCEL_BASE + REG_K, TILE);
    Xil_Out32(ACCEL_BASE + REG_N, TILE);
    Xil_Out32(ACCEL_BASE + REG_NUM_KTILES, NUM_KTILES);

    // 2. Flush data cache to DDR for both input streams and output destination.
    //    Because the DMA engine directly accesses DDR, any modifications currently
    //    cached in the PS L1/L2 caches must be forced to DDR before the transfer starts.
    Xil_DCacheFlushRange((UINTPTR)input_stream,
                         INPUT_WORDS_64 * sizeof(u64));

    Xil_DCacheFlushRange((UINTPTR)output_tile,
                         OUTPUT_WORDS_64 * sizeof(u64));

    // 3. Initiate the Receive (S2MM) DMA channel.
    //    We MUST start the receive channel BEFORE the accelerator streams out any data
    //    to prevent FIFO lockups or back-pressure freezes.
    status = XAxiDma_SimpleTransfer(dma,
                                    (UINTPTR)output_tile,
                                    OUTPUT_WORDS_64 * sizeof(u64),
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: S2MM start ti=%d tj=%d status=%d\r\n",
                   ti, tj, status);
        return -1;
    }

    // 4. Reset and trigger the Hardware Accelerator FSM
    Xil_Out32(ACCEL_BASE + REG_CTRL, 0);
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);

    // 5. Initiate the Transmit (MM2S) DMA channel.
    //    Streams the packed A/B K-tile blocks from DDR to the accelerator.
    status = XAxiDma_SimpleTransfer(dma,
                                    (UINTPTR)input_stream,
                                    INPUT_WORDS_64 * sizeof(u64),
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: MM2S start ti=%d tj=%d status=%d\r\n",
                   ti, tj, status);
        return -1;
    }

    // 6. Wait for Transmit (MM2S) channel to finish streaming out inputs
    timeout = TIMEOUT_COUNT;
    while (XAxiDma_Busy(dma, XAXIDMA_DMA_TO_DEVICE) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: MM2S timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    // 7. Wait for Receive (S2MM) channel to finish storing results to DDR
    timeout = TIMEOUT_COUNT;
    while (XAxiDma_Busy(dma, XAXIDMA_DEVICE_TO_DMA) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: S2MM timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    // 8. Poll the Accelerator register until the Done bit is high
    timeout = TIMEOUT_COUNT;
    while (((Xil_In32(ACCEL_BASE + REG_STATUS) & 0x1) == 0) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: accelerator timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    // 9. Invalidate output memory cache lines.
    //    This forces the PS to read the fresh hardware outputs from physical DDR
    //    instead of hitting old cached values.
    Xil_DCacheInvalidateRange((UINTPTR)output_tile,
                              OUTPUT_WORDS_64 * sizeof(u64));

    return 0;
}

int main()
{
    init_platform();

    xil_printf("Phase 18B 64-bit stream tiled test (%dx%d, tile=%d)\r\n",
               FULL_SIZE, FULL_SIZE, TILE);

    // Initialize full matrices with pseudorandom data
    for (int i = 0; i < FULL_SIZE * FULL_SIZE; i++) {
        A_full[i] = my_rand();
    }

    for (int i = 0; i < FULL_SIZE * FULL_SIZE; i++) {
        B_full[i] = my_rand();
    }

    XTime sw_start, sw_end;
    XTime hw_start, hw_end;

    // ============================================================================
    // 1. Software Baseline Execution
    // ============================================================================
    XTime_GetTime(&sw_start);

    for (int i = 0; i < FULL_SIZE; i++) {
        for (int j = 0; j < FULL_SIZE; j++) {
            int32_t sum = 0;

            for (int k = 0; k < FULL_SIZE; k++) {
                sum += (int32_t)A_full[i * FULL_SIZE + k] *
                       (int32_t)B_full[k * FULL_SIZE + j];
            }

            C_sw[i * FULL_SIZE + j] = sum;
        }
    }

    XTime_GetTime(&sw_end);

    double sw_time = elapsed_seconds(sw_start, sw_end);

    xil_printf("Software time: %d us\r\n",
               (int)(sw_time * 1000000.0));

    // ============================================================================
    // 2. Stream Pre-Packing Phase
    // ============================================================================
    xil_printf("Pre-packing 64-bit tile streams...\r\n");
    build_packed_streams();

    memset(C_hw, 0, sizeof(C_hw));

    // ============================================================================
    // 3. AXI DMA Controller Setup
    // ============================================================================
    XAxiDma dma;
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_DEV_ID);

    if (!cfg) {
        xil_printf("FAIL: no DMA config\r\n");
        cleanup_platform();
        return -1;
    }

    int status = XAxiDma_CfgInitialize(&dma, cfg);

    if (status != XST_SUCCESS) {
        xil_printf("FAIL: DMA init status=%d\r\n", status);
        cleanup_platform();
        return -1;
    }

    if (XAxiDma_HasSg(&dma)) {
        xil_printf("FAIL: DMA is in SG mode\r\n");
        cleanup_platform();
        return -1;
    }

    // Disable interrupts to run in simple polling mode
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    // ============================================================================
    // 4. Hardware Accelerator Execution & Timing
    // ============================================================================
    xil_printf("Running hardware on 64-bit pre-packed streams...\r\n");

    XTime_GetTime(&hw_start);

    for (int ti = 0; ti < NUM_TILES; ti++) {
        for (int tj = 0; tj < NUM_TILES; tj++) {
            int out_tile_idx = ti * NUM_TILES + tj;

            // Zero out output receiver tile
            for (int i = 0; i < OUTPUT_WORDS_64; i++) {
                output_tile[i] = 0;
            }

            // Run hardware computation for tile sub-block
            if (run_one_output_tile(&dma,
                                    input_streams[out_tile_idx],
                                    ti,
                                    tj) != 0) {
                cleanup_platform();
                return -1;
            }

            // Unpack 64-bit hardware streams (2 x int32 per word) back into C_hw matrix
            for (int i = 0; i < TILE; i++) {
                for (int j = 0; j < TILE; j++) {
                    int elem = i * TILE + j;
                    u64 word = output_tile[elem / 2];
                    int lane = elem & 1;

                    C_hw[(ti * TILE + i) * FULL_SIZE + (tj * TILE + j)] =
                        unpack_i32_from_u64(word, lane);
                }
            }
        }
    }

    XTime_GetTime(&hw_end);

    double hw_time = elapsed_seconds(hw_start, hw_end);

    xil_printf("Hardware time, 64-bit pre-packed input: %d us\r\n",
               (int)(hw_time * 1000000.0));

    // ============================================================================
    // 5. Performance Speedup Report
    // ============================================================================
    if (hw_time > 0.0) {
        double speedup = sw_time / hw_time;

        xil_printf("Speedup: %d.%02d x\r\n",
                   (int)speedup,
                   (int)((speedup - (int)speedup) * 100.0));
    }

    // ============================================================================
    // 6. Bit-Accurate Verification
    // ============================================================================
    xil_printf("Comparing results...\r\n");

    int errors = 0;

    for (int i = 0; i < FULL_SIZE * FULL_SIZE; i++) {
        if (C_hw[i] != C_sw[i]) {
            if (errors < 10) {
                xil_printf("Mismatch %d: exp=%d got=%d\r\n",
                           i, (int)C_sw[i], (int)C_hw[i]);
            }

            errors++;
        }
    }

    if (errors == 0) {
        xil_printf("PHASE 18B 64-BIT STREAM %dx%d PASS\r\n",
                   FULL_SIZE, FULL_SIZE);
    } else {
        xil_printf("PHASE 18B 64-BIT STREAM %dx%d FAIL: %d errors\r\n",
                   FULL_SIZE, FULL_SIZE, errors);
    }

    cleanup_platform();
    return 0;
}
