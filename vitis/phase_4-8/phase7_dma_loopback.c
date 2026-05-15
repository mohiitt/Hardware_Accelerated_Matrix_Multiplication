/*
 * Phase 7: DMA Loopback Test
 *
 * Sends data from DDR through AXI DMA and receives it back unchanged.
 * Stream path: DDR → DMA MM2S → loopback wire → DMA S2MM → DDR
 *
 * PREREQUISITES:
 *   - AXI DMA IP added in Vivado block design
 *   - Scatter Gather DISABLED (simple/direct mode)
 *   - MM2S and S2MM channels enabled
 *   - DMA stream output connected directly to stream input (loopback)
 *   - S_AXI_HP0 enabled on Zynq PS
 *   - DMA memory ports connected to HP0 via SmartConnect
 *
 * EXPECTED OUTPUT:
 *   DMA Loopback Test
 *   DMA init OK
 *   Starting transfers...
 *   DMA LOOPBACK PASS
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

/* Buffers must be cache-line aligned (64 bytes on Zynq) */
u32 tx_buffer[LEN] __attribute__((aligned(64)));
u32 rx_buffer[LEN] __attribute__((aligned(64)));

int main()
{
    init_platform();

    xil_printf("DMA Loopback Test\r\n");

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
        xil_printf("FAIL: DMA is in SG mode, expected simple mode\r\n");
        return -1;
    }

    /* Disable interrupts, we use polling */
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    xil_printf("DMA init OK\r\n");

    /* --- Fill TX buffer --- */
    for (int i = 0; i < LEN; i++) {
        tx_buffer[i] = i + 100;
        rx_buffer[i] = 0;
    }

    /* --- Flush caches --- */
    Xil_DCacheFlushRange((UINTPTR)tx_buffer, LEN * sizeof(u32));
    Xil_DCacheFlushRange((UINTPTR)rx_buffer, LEN * sizeof(u32));

    xil_printf("Starting transfers...\r\n");

    /* --- Start RX (S2MM) first --- */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)rx_buffer,
                                     LEN * sizeof(u32),
                                     XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: S2MM transfer start error %d\r\n", status);
        return -1;
    }

    /* --- Start TX (MM2S) --- */
    status = XAxiDma_SimpleTransfer(&dma,
                                     (UINTPTR)tx_buffer,
                                     LEN * sizeof(u32),
                                     XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("FAIL: MM2S transfer start error %d\r\n", status);
        return -1;
    }

    /* --- Wait for both channels --- */
    while (XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA));

    /* --- Invalidate RX cache before reading --- */
    Xil_DCacheInvalidateRange((UINTPTR)rx_buffer, LEN * sizeof(u32));

    /* --- Compare --- */
    int errors = 0;
    for (int i = 0; i < LEN; i++) {
        if (rx_buffer[i] != tx_buffer[i]) {
            xil_printf("FAIL at %d: tx=%d rx=%d\r\n",
                        i, (int)tx_buffer[i], (int)rx_buffer[i]);
            errors++;
            if (errors > 5) break;
        }
    }

    if (errors == 0)
        xil_printf("DMA LOOPBACK PASS\r\n");
    else
        xil_printf("DMA LOOPBACK FAIL: %d errors\r\n", errors);

    cleanup_platform();
    return 0;
}
