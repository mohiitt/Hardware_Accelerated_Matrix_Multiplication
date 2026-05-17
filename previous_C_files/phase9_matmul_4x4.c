/*
 * Phase 9: 4x4 Matrix Multiply Through DMA
 *
 * Stream path:
 *   DDR input_buffer → DMA MM2S → matrix_accel → DMA S2MM → DDR output_buffer
 *
 * Input buffer layout (32-bit words, int8 packed 4 per word):
 *   Words 0-3:  A[0..15] as int8  (16 bytes = 4 words)
 *   Words 4-7:  B[0..15] as int8  (16 bytes = 4 words)
 *   Total: 8 words = 32 bytes
 *
 * Output buffer layout:
 *   Words 0-15: C[0..15] as int32 (16 words = 64 bytes)
 *
 * EXPECTED OUTPUT:
 *   Matrix Multiply 4x4 through DMA
 *   DMA init OK
 *   ...
 *   MATRIX MULTIPLY 4x4 PASS
 */

#include <stdio.h>
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

#define M_DIM 4
#define K_DIM 4
#define N_DIM 4

#define INPUT_BYTES  ((M_DIM * K_DIM + K_DIM * N_DIM) * sizeof(int8_t))
#define OUTPUT_BYTES (M_DIM * N_DIM * sizeof(int32_t))

/* Round up to multiple of 4 bytes for stream alignment */
#define INPUT_WORDS  ((INPUT_BYTES + 3) / 4)
#define OUTPUT_WORDS (M_DIM * N_DIM)

u32 input_buffer[INPUT_WORDS]   __attribute__((aligned(64)));
u32 output_buffer[OUTPUT_WORDS] __attribute__((aligned(64)));

/* Pack int8 array into 32-bit words (little-endian: byte 0 in bits [7:0]) */
void pack_int8_to_u32(const int8_t *src, u32 *dst, int num_bytes) {
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

int main()
{
    init_platform();

    xil_printf("Matrix Multiply 4x4 through DMA\r\n");

    /* --- Matrices --- */
    int8_t A[M_DIM * K_DIM] = {
        1, 2, 3, 4,
        5, 6, 7, 8,
        1, 1, 1, 1,
        -1, 2, -3, 4
    };

    int8_t B[K_DIM * N_DIM] = {
        1, 0, 2, 1,
        0, 1, 2, 1,
        1, 1, 0, 1,
        2, 0, 1, 1
    };

    /* --- Software golden reference --- */
    int32_t C_sw[M_DIM * N_DIM] = {0};
    for (int i = 0; i < M_DIM; i++) {
        for (int j = 0; j < N_DIM; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K_DIM; k++) {
                sum += (int32_t)A[i * K_DIM + k] * (int32_t)B[k * N_DIM + j];
            }
            C_sw[i * N_DIM + j] = sum;
        }
    }

    /* --- Pack A and B into input buffer --- */
    int a_bytes = M_DIM * K_DIM;
    int b_bytes = K_DIM * N_DIM;
    int a_words = (a_bytes + 3) / 4;

    pack_int8_to_u32(A, &input_buffer[0], a_bytes);
    pack_int8_to_u32(B, &input_buffer[a_words], b_bytes);

    /* Clear output */
    for (int i = 0; i < OUTPUT_WORDS; i++)
        output_buffer[i] = 0;

    /* --- Initialize DMA --- */
    XAxiDma dma;
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (!cfg) { xil_printf("FAIL: no DMA config\r\n"); return -1; }

    int status = XAxiDma_CfgInitialize(&dma, cfg);
    if (status != XST_SUCCESS) { xil_printf("FAIL: DMA init\r\n"); return -1; }

    if (XAxiDma_HasSg(&dma)) { xil_printf("FAIL: SG mode\r\n"); return -1; }

    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    xil_printf("DMA init OK\r\n");

    /* --- Configure accelerator dimensions --- */
    Xil_Out32(ACCEL_BASE + REG_M, M_DIM);
    Xil_Out32(ACCEL_BASE + REG_K, K_DIM);
    Xil_Out32(ACCEL_BASE + REG_N, N_DIM);

    /* --- Flush caches --- */
    Xil_DCacheFlushRange((UINTPTR)input_buffer, INPUT_WORDS * sizeof(u32));
    Xil_DCacheFlushRange((UINTPTR)output_buffer, OUTPUT_WORDS * sizeof(u32));

    /* --- Start S2MM (receive) first --- */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)output_buffer,
                                     OUTPUT_WORDS * sizeof(u32),
                                     XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) { xil_printf("FAIL: S2MM start\r\n"); return -1; }

    /* --- Start accelerator --- */
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);

    /* --- Start MM2S (send) --- */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)input_buffer,
                                     INPUT_WORDS * sizeof(u32),
                                     XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) { xil_printf("FAIL: MM2S start\r\n"); return -1; }

    /* --- Wait --- */
    xil_printf("Waiting for DMA...\r\n");
    while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));

    xil_printf("Waiting for accelerator done...\r\n");
    while ((Xil_In32(ACCEL_BASE + REG_STATUS) & 0x1) == 0);

    /* --- Invalidate output cache --- */
    Xil_DCacheInvalidateRange((UINTPTR)output_buffer, OUTPUT_WORDS * sizeof(u32));

    /* --- Compare --- */
    int errors = 0;
    int32_t *C_hw = (int32_t *)output_buffer;

    xil_printf("Results:\r\n");
    for (int i = 0; i < M_DIM; i++) {
        for (int j = 0; j < N_DIM; j++) {
            int idx = i * N_DIM + j;
            printf("%4d ", (int)C_hw[idx]);
            if (C_hw[idx] != C_sw[idx]) {
                errors++;
            }
        }
        xil_printf("\r\n");
    }

    if (errors == 0) {
        xil_printf("MATRIX MULTIPLY 4x4 PASS\r\n");
    } else {
        xil_printf("MATRIX MULTIPLY 4x4 FAIL: %d mismatches\r\n", errors);
        for (int i = 0; i < M_DIM * N_DIM; i++) {
            if (C_hw[i] != C_sw[i]) {
                xil_printf("  idx=%d expected=%d actual=%d\r\n",
                            i, (int)C_sw[i], (int)C_hw[i]);
            }
        }
    }

    cleanup_platform();
    return 0;
}
