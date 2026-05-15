/*
 * Phase 5: AXI-Lite Register Test
 *
 * Tests basic ARM ↔ PL register communication.
 * The PL IP computes RESULT = M + K + N when start is written.
 *
 * USAGE:
 *   1. Generate bitstream with matrix_accel AXI-Lite IP in block design.
 *   2. Export XSA, update Vitis platform.
 *   3. Replace application main.c with this file.
 *   4. Check xparameters.h for the actual base address macro name.
 *   5. Build, program FPGA, run.
 *
 * EXPECTED OUTPUT:
 *   AXI-Lite register test
 *   STATUS = 1
 *   RESULT = 12
 */

#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "platform.h"

/* 
 * NOTE: The actual macro name depends on your IP name in Vivado.
 * Check xparameters.h after generating the platform.
 * Common names:
 *   XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR
 *   XPAR_MATRIX_ACCEL_0_BASEADDR
 */
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

    xil_printf("AXI-Lite register test\r\n");

    /* Write dimensions */
    Xil_Out32(ACCEL_BASE + REG_M, 4);
    Xil_Out32(ACCEL_BASE + REG_K, 4);
    Xil_Out32(ACCEL_BASE + REG_N, 4);

    /* Trigger start */
    Xil_Out32(ACCEL_BASE + REG_CTRL, 1);

    /* Small delay for hardware to compute */
    for (volatile int i = 0; i < 100; i++);

    /* Read results */
    u32 status = Xil_In32(ACCEL_BASE + REG_STATUS);
    u32 result = Xil_In32(ACCEL_BASE + REG_RESULT);

    xil_printf("STATUS = %d\r\n", status);
    xil_printf("RESULT = %d\r\n", result);

    if (result == 12)
        xil_printf("PASS\r\n");
    else
        xil_printf("FAIL: expected 12\r\n");

    cleanup_platform();
    return 0;
}
