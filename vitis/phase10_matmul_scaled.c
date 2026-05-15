/*
 * Phase 10: Scaled Matrix Multiply (8x8, 16x16)
 *
 * Tests larger matrices through DMA. Uses random small values (-5 to +5).
 * Prints full matrix for 8x8, only PASS/FAIL + first mismatch for 16x16.
 *
 * Change TEST_SIZE to 8 or 16 to test each size.
 *
 * EXPECTED OUTPUT:
 *   Matrix Multiply NxN through DMA
 *   ...
 *   MATRIX MULTIPLY NxN PASS
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "xaxidma.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "platform.h"

#define DMA_DEV_ID   XPAR_AXIDMA_0_DEVICE_ID
#define ACCEL_BASE   XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR

#define REG_CTRL    0x00
#define REG_STATUS  0x04
#define REG_M       0x08
#define REG_K       0x0C
#define REG_N       0x10
#define REG_RESULT  0x14

/* ---- CHANGE THIS TO TEST DIFFERENT SIZES ---- */
#define TEST_SIZE   8
/* Options: 8, 16 */

#define M_DIM TEST_SIZE
#define K_DIM TEST_SIZE
#define N_DIM TEST_SIZE

#define A_BYTES   (M_DIM * K_DIM)
#define B_BYTES   (K_DIM * N_DIM)
#define A_WORDS   ((A_BYTES + 3) / 4)
#define B_WORDS   ((B_BYTES + 3) / 4)
#define INPUT_WORDS  (A_WORDS + B_WORDS)
#define OUTPUT_WORDS (M_DIM * N_DIM)

u32 input_buffer[INPUT_WORDS]   __attribute__((aligned(64)));
u32 output_buffer[OUTPUT_WORDS] __attribute__((aligned(64)));

int8_t A[M_DIM * K_DIM];
int8_t B[K_DIM * N_DIM];
int32_t C_sw[M_DIM * N_DIM];

/* Simple pseudo-random generator (no stdlib rand on bare metal) */
static unsigned int seed = 12345;
int8_t my_rand_int8(void) {
    seed = seed * 1103515245 + 12345;
    return (int8_t)((seed >> 16) % 11) - 5;  /* range -5 to +5 */
}

void pack_int8_to_u32(const int8_t *src, u32 *dst, int num_bytes) {
    int num_words = (num_bytes + 3) / 4;
    for (int w = 0; w < num_words; w++) {
        u32 word = 0;
        for (int b = 0; b < 4; b++) {
            int idx = w * 4 + b;
            if (idx < num_bytes)
                word |= ((u32)(uint8_t)src[idx]) << (b * 8);
        }
        dst[w] = word;
    }
}

int main()
{
    init_platform();

    xil_printf("Matrix Multiply %dx%d through DMA\r\n", TEST_SIZE, TEST_SIZE);

    /* --- Generate test data --- */
    for (int i = 0; i < M_DIM * K_DIM; i++) A[i] = my_rand_int8();
    for (int i = 0; i < K_DIM * N_DIM; i++) B[i] = my_rand_int8();

    /* --- Software golden reference --- */
    for (int i = 0; i < M_DIM; i++) {
        for (int j = 0; j < N_DIM; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K_DIM; k++)
                sum += (int32_t)A[i * K_DIM + k] * (int32_t)B[k * N_DIM + j];
            C_sw[i * N_DIM + j] = sum;
        }
    }

    /* --- Pack input --- */
    pack_int8_to_u32(A, &input_buffer[0], A_BYTES);
    pack_int8_to_u32(B, &input_buffer[A_WORDS], B_BYTES);
    for (int i = 0; i < OUTPUT_WORDS; i++) output_buffer[i] = 0;

    /* --- DMA init --- */
    XAxiDma dma;
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_DEV_ID);
    XAxiDma_CfgInitialize(&dma, cfg);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* --- Configure & run --- */
    Xil_Out32(ACCEL_BASE + REG_M, M_DIM);
    Xil_Out32(ACCEL_BASE + REG_K, K_DIM);
    Xil_Out32(ACCEL_BASE + REG_N, N_DIM);

    Xil_DCacheFlushRange((UINTPTR)input_buffer, INPUT_WORDS * sizeof(u32));
    Xil_DCacheFlushRange((UINTPTR)output_buffer, OUTPUT_WORDS * sizeof(u32));

    XAxiDma_SimpleTransfer(&dma, (UINTPTR)output_buffer,
                            OUTPUT_WORDS * sizeof(u32), XAXIDMA_DEVICE_TO_DMA);
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);
    XAxiDma_SimpleTransfer(&dma, (UINTPTR)input_buffer,
                            INPUT_WORDS * sizeof(u32), XAXIDMA_DMA_TO_DEVICE);

    while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));
    while ((Xil_In32(ACCEL_BASE + REG_STATUS) & 0x1) == 0);

    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, OUTPUT_WORDS * sizeof(u32));

    /* --- Compare --- */
    int32_t *C_hw = (int32_t *)output_buffer;
    int errors = 0;

    for (int i = 0; i < M_DIM * N_DIM; i++) {
        if (C_hw[i] != C_sw[i]) {
            if (errors == 0) {
                xil_printf("First mismatch: idx=%d expected=%d actual=%d\r\n",
                            i, (int)C_sw[i], (int)C_hw[i]);
            }
            errors++;
        }
    }

    /* Print full matrix for small sizes */
    if (TEST_SIZE <= 8) {
        xil_printf("HW result:\r\n");
        for (int i = 0; i < M_DIM; i++) {
            for (int j = 0; j < N_DIM; j++)
                printf("%5d ", (int)C_hw[i * N_DIM + j]);
            xil_printf("\r\n");
        }
    }

    if (errors == 0)
        xil_printf("MATRIX MULTIPLY %dx%d PASS\r\n", TEST_SIZE, TEST_SIZE);
    else
        xil_printf("MATRIX MULTIPLY %dx%d FAIL: %d errors\r\n",
                    TEST_SIZE, TEST_SIZE, errors);

    cleanup_platform();
    return 0;
}
