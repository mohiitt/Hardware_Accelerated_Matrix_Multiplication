/*
 * Phase 6: Hardcoded PL Matrix Multiply Test (No DMA)
 *
 * The PL IP has hardcoded A[4][4] and B[4][4] matrices.
 * ARM sends start, waits for done, reads checksum from RESULT.
 *
 * EXPECTED OUTPUT:
 *   Hardcoded PL matrix multiply test
 *   Waiting for done...
 *   STATUS = 1
 *   HW checksum = 160
 *   SW checksum = 160
 *   PASS
 */

#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "platform.h"

#define ACCEL_BASE  XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR

#define REG_CTRL    0x00
#define REG_STATUS  0x04
#define REG_M       0x08
#define REG_K       0x0C
#define REG_N       0x10
#define REG_RESULT  0x14

int main()
{
    init_platform();

    xil_printf("Hardcoded PL matrix multiply test\r\n");

    /* --- Software golden reference (same matrices as hardcoded in PL) --- */
    int8_t A[4][4] = {
        {1, 2, 3, 4},
        {5, 6, 7, 8},
        {1, 1, 1, 1},
        {-1, 2, -3, 4}
    };
    int8_t B[4][4] = {
        {1, 0, 2, 1},
        {0, 1, 2, 1},
        {1, 1, 0, 1},
        {2, 0, 1, 1}
    };

    int32_t sw_checksum = 0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            int32_t sum = 0;
            for (int k = 0; k < 4; k++)
                sum += (int32_t)A[i][k] * (int32_t)B[k][j];
            sw_checksum += sum;
        }
    }

    /* --- Trigger hardware --- */
    Xil_Out32(ACCEL_BASE + REG_M, 4);
    Xil_Out32(ACCEL_BASE + REG_K, 4);
    Xil_Out32(ACCEL_BASE + REG_N, 4);
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);

    /* Wait for done (bit 0 of STATUS) */
    xil_printf("Waiting for done...\r\n");
    while ((Xil_In32(ACCEL_BASE + REG_STATUS) & 0x1) == 0);

    u32 status = Xil_In32(ACCEL_BASE + REG_STATUS);
    int32_t hw_checksum = (int32_t)Xil_In32(ACCEL_BASE + REG_RESULT);

    xil_printf("STATUS = %d\r\n", status);
    xil_printf("HW checksum = %d\r\n", (int)hw_checksum);
    xil_printf("SW checksum = %d\r\n", (int)sw_checksum);

    if (hw_checksum == sw_checksum)
        xil_printf("PASS\r\n");
    else
        xil_printf("FAIL\r\n");

    cleanup_platform();
    return 0;
}
