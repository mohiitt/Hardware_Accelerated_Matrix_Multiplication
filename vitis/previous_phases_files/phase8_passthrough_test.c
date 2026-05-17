/*
 * Phase 8: Streaming Pass-Through Accelerator Test
 *
 * Same as DMA loopback but data passes through our custom IP.
 * Stream path: DDR → DMA MM2S → matrix_accel → DMA S2MM → DDR
 *
 * The accelerator just copies input stream to output stream (identity).
 *
 * EXPECTED OUTPUT:
 *   Pass-Through Accelerator Test
 *   DMA init OK
 *   Starting transfers...
 *   PASS-THROUGH ACCELERATOR PASS
 */

#include <stdio.h>
#include <stdint.h>
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "platform.h"

#define DMA_DEV_ID   XPAR_AXIDMA_0_DEVICE_ID
#define LEN          16

u32 tx_buffer[LEN] __attribute__((aligned(64)));
u32 rx_buffer[LEN] __attribute__((aligned(64)));

int main()
{
    init_platform();

    xil_printf("Pass-Through Accelerator Test\r\n");

    /* --- Initialize DMA --- */
    XAxiDma dma;
    XAxiDma_Config *cfg;
    int status;

    cfg = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (!cfg) {
        xil_printf("FAIL: DMA config not found\r\n");
        return -1;
    }

    status = XAxiDma_CfgInitialize(&dma, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: DMA init error %d\r\n", status);
        return -1;
    }

    if (XAxiDma_HasSg(&dma)) {
        xil_printf("FAIL: DMA is in SG mode\r\n");
        return -1;
    }

    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    xil_printf("DMA init OK\r\n");

    /* --- Fill TX buffer --- */
    for (int i = 0; i < LEN; i++) {
        tx_buffer[i] = 0xDEAD0000 | i;
        rx_buffer[i] = 0;
    }

    /* --- Cache ops --- */
    Xil_DCacheFlushRange((UINTPTR)tx_buffer, LEN * sizeof(u32));
    Xil_DCacheFlushRange((UINTPTR)rx_buffer, LEN * sizeof(u32));

    xil_printf("Starting transfers...\r\n");

    /* Start RX first */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)rx_buffer,
                                     LEN * sizeof(u32),
                                     XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: S2MM start error\r\n");
        return -1;
    }

    /* Start TX */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)tx_buffer,
                                     LEN * sizeof(u32),
                                     XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: MM2S start error\r\n");
        return -1;
    }

    /* Wait */
    while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)rx_buffer, LEN * sizeof(u32));

    /* Compare */
    int errors = 0;
    for (int i = 0; i < LEN; i++) {
        if (rx_buffer[i] != tx_buffer[i]) {
            xil_printf("FAIL at %d: tx=0x%08X rx=0x%08X\r\n",
                        i, (unsigned)tx_buffer[i], (unsigned)rx_buffer[i]);
            errors++;
            if (errors > 5) break;
        }
    }

    if (errors == 0)
        xil_printf("PASS-THROUGH ACCELERATOR PASS\r\n");
    else
        xil_printf("PASS-THROUGH ACCELERATOR FAIL: %d errors\r\n", errors);

    cleanup_platform();
    return 0;
}
