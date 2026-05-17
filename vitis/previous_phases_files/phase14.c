/*
 * Phase 14: PL-side K-tile accumulation
 * 64x64 using 32x32 tiles.
 *
 * For each output tile C[ti][tj], PS sends both K tile-pairs:
 *   A[ti][0], B[0][tj], A[ti][1], B[1][tj]
 *
 * PL accumulates both partial products internally and returns one final C tile.
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

#define DMA_DEV_ID   XPAR_AXIDMA_0_DEVICE_ID
#define ACCEL_BASE   XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR

#define REG_CTRL        0x00
#define REG_STATUS      0x04
#define REG_M           0x08
#define REG_K           0x0C
#define REG_N           0x10
#define REG_NUM_KTILES  0x14

#define FULL_SIZE       64
#define TILE            32
#define NUM_KTILES      (FULL_SIZE / TILE)

#define TILE_BYTES      (TILE * TILE)
#define TILE_WORDS      ((TILE_BYTES + 3) / 4)

#define INPUT_WORDS     (NUM_KTILES * 2 * TILE_WORDS)
#define OUTPUT_WORDS    (TILE * TILE)

#define TIMEOUT_COUNT   10000000

int8_t  A_full[FULL_SIZE * FULL_SIZE];
int8_t  B_full[FULL_SIZE * FULL_SIZE];
int32_t C_sw[FULL_SIZE * FULL_SIZE];
int32_t C_hw[FULL_SIZE * FULL_SIZE];

u32 input_tile[INPUT_WORDS]    __attribute__((aligned(64)));
u32 output_tile[OUTPUT_WORDS]  __attribute__((aligned(64)));

int8_t A_tile[TILE * TILE];
int8_t B_tile[TILE * TILE];

static unsigned int seed = 77777;

double elapsed_seconds(XTime start, XTime end)
{
    return (double)(end - start) / (double)COUNTS_PER_SECOND;
}

int8_t my_rand(void)
{
    seed = seed * 1103515245 + 12345;
    return (int8_t)((seed >> 16) % 11) - 5;
}

void pack_i8(const int8_t *src, u32 *dst, int num_bytes)
{
    int num_words = (num_bytes + 3) / 4;

    for (int w = 0; w < num_words; w++) {
        u32 word = 0;

        for (int b = 0; b < 4; b++) {
            int idx = w * 4 + b;

            if (idx < num_bytes) {
                word |= ((u32)(uint8_t)src[idx]) << (b * 8);
            }
        }

        dst[w] = word;
    }
}

void extract_tile(const int8_t *full,
                  int8_t *tile,
                  int row_start,
                  int col_start,
                  int tile_rows,
                  int tile_cols,
                  int full_cols)
{
    for (int i = 0; i < tile_rows; i++) {
        for (int j = 0; j < tile_cols; j++) {
            tile[i * tile_cols + j] =
                full[(row_start + i) * full_cols + (col_start + j)];
        }
    }
}

int run_one_output_tile(XAxiDma *dma, int ti, int tj)
{
    int status;
    int timeout;

    Xil_Out32(ACCEL_BASE + REG_M, TILE);
    Xil_Out32(ACCEL_BASE + REG_K, TILE);
    Xil_Out32(ACCEL_BASE + REG_N, TILE);
    Xil_Out32(ACCEL_BASE + REG_NUM_KTILES, NUM_KTILES);

    Xil_DCacheFlushRange((UINTPTR)input_tile, INPUT_WORDS * sizeof(u32));
    Xil_DCacheFlushRange((UINTPTR)output_tile, OUTPUT_WORDS * sizeof(u32));

    status = XAxiDma_SimpleTransfer(dma,
                                    (UINTPTR)output_tile,
                                    OUTPUT_WORDS * sizeof(u32),
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: S2MM start ti=%d tj=%d status=%d\r\n",
                   ti, tj, status);
        return -1;
    }

    Xil_Out32(ACCEL_BASE + REG_CTRL, 0);
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);

    status = XAxiDma_SimpleTransfer(dma,
                                    (UINTPTR)input_tile,
                                    INPUT_WORDS * sizeof(u32),
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: MM2S start ti=%d tj=%d status=%d\r\n",
                   ti, tj, status);
        return -1;
    }

    timeout = TIMEOUT_COUNT;
    while (XAxiDma_Busy(dma, XAXIDMA_DMA_TO_DEVICE) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: MM2S timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    timeout = TIMEOUT_COUNT;
    while (XAxiDma_Busy(dma, XAXIDMA_DEVICE_TO_DMA) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: S2MM timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    timeout = TIMEOUT_COUNT;
    while (((Xil_In32(ACCEL_BASE + REG_STATUS) & 0x1) == 0) && timeout--);

    if (timeout <= 0) {
        xil_printf("FAIL: accelerator timeout ti=%d tj=%d STATUS=0x%08x\r\n",
                   ti, tj, Xil_In32(ACCEL_BASE + REG_STATUS));
        return -1;
    }

    Xil_DCacheInvalidateRange((UINTPTR)output_tile,
                              OUTPUT_WORDS * sizeof(u32));

    return 0;
}

int main()
{
    init_platform();

    xil_printf("PL-side K-tile accumulation test (%dx%d, tile=%d)\r\n",
               FULL_SIZE, FULL_SIZE, TILE);

    for (int i = 0; i < FULL_SIZE * FULL_SIZE; i++) {
        A_full[i] = my_rand();
    }

    for (int i = 0; i < FULL_SIZE * FULL_SIZE; i++) {
        B_full[i] = my_rand();
    }

    XTime sw_start, sw_end;
    XTime hw_start, hw_end;

    xil_printf("Computing software reference...\r\n");
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
    xil_printf("Software time: %d us\r\n", (int)(sw_time * 1000000.0));

    memset(C_hw, 0, sizeof(C_hw));

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

    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    int num_tiles = FULL_SIZE / TILE;

    xil_printf("Running tiled hardware multiply...\r\n");
    XTime_GetTime(&hw_start);

    for (int ti = 0; ti < num_tiles; ti++) {
        for (int tj = 0; tj < num_tiles; tj++) {

            xil_printf("Output tile ti=%d tj=%d\r\n", ti, tj);

            for (int tk = 0; tk < NUM_KTILES; tk++) {
                int base = tk * 2 * TILE_WORDS;

                extract_tile(A_full,
                             A_tile,
                             ti * TILE,
                             tk * TILE,
                             TILE,
                             TILE,
                             FULL_SIZE);

                extract_tile(B_full,
                             B_tile,
                             tk * TILE,
                             tj * TILE,
                             TILE,
                             TILE,
                             FULL_SIZE);

                pack_i8(A_tile, &input_tile[base], TILE_BYTES);
                pack_i8(B_tile, &input_tile[base + TILE_WORDS], TILE_BYTES);
            }

            for (int i = 0; i < OUTPUT_WORDS; i++) {
                output_tile[i] = 0;
            }

            if (run_one_output_tile(&dma, ti, tj) != 0) {
                cleanup_platform();
                return -1;
            }

            int32_t *tile_result = (int32_t *)output_tile;

            for (int i = 0; i < TILE; i++) {
                for (int j = 0; j < TILE; j++) {
                    C_hw[(ti * TILE + i) * FULL_SIZE + (tj * TILE + j)] =
                        tile_result[i * TILE + j];
                }
            }
        }
    }

    XTime_GetTime(&hw_end);

    double hw_time = elapsed_seconds(hw_start, hw_end);
    xil_printf("Hardware tiled time: %d us\r\n", (int)(hw_time * 1000000.0));

    if (hw_time > 0.0) {
        double speedup = sw_time / hw_time;
        xil_printf("Speedup: %d.%02d x\r\n",
                   (int)speedup,
                   (int)((speedup - (int)speedup) * 100.0));
    }

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
        xil_printf("PL-SIDE KTILE ACCUMULATION %dx%d PASS\r\n",
                   FULL_SIZE, FULL_SIZE);
    } else {
        xil_printf("PL-SIDE KTILE ACCUMULATION %dx%d FAIL: %d errors\r\n",
                   FULL_SIZE, FULL_SIZE, errors);
    }

    cleanup_platform();
    return 0;
}
