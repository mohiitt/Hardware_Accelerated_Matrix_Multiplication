/******************************************************************************
*
* Copyright (C) 2009 - 2014 Xilinx, Inc.  All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* Use of the Software is limited solely to applications:
* (a) running on a Xilinx device, or
* (b) that interact with a Xilinx device through a bus or interconnect.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* XILINX  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
* WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
* OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*
* Except as contained in this notice, the name of the Xilinx shall not be used
* in advertising or otherwise to promote the sale, use or other dealings in
* this Software without prior written authorization from Xilinx.
*
******************************************************************************/

/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"

/*
 * Phase 4: Software matrix multiply on Zybo ARM (PS)
 *
 * This is the same algorithm as software_model/main.c but adapted
 * for the Xilinx SDK / Vitis environment.
 *
 * USAGE:
 *   1. In Vitis, replace the hello_world main.c with this file.
 *   2. Build and run on Zybo.
 *   3. Check UART output matches the Mac golden reference.
 *
 * EXPECTED OUTPUT (must match Mac):
 *   C =
 *     12   5  10  10
 *     28  13  30  26
 *      4   2   5   4
 *      4  -1   6   2
 *   Checksum = 160
 */

#include <stdio.h>
#include <stdint.h>
#include "platform.h"
#include "xil_printf.h"

#define M 4
#define K 4
#define N 4

int main()
{
    init_platform();

    int8_t A[M][K] = {
        {1, 2, 3, 4},
        {5, 6, 7, 8},
        {1, 1, 1, 1},
        {-1, 2, -3, 4}
    };

    int8_t B[K][N] = {
        {1, 0, 2, 1},
        {0, 1, 2, 1},
        {1, 1, 0, 1},
        {2, 0, 1, 1}
    };

    int32_t C[M][N] = {0};

    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K; k++) {
                sum += (int32_t)A[i][k] * (int32_t)B[k][j];
            }
            C[i][j] = sum;
        }
    }

    xil_printf("C =\r\n");
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            /* xil_printf does not support %d for int32_t on all versions,
               so we use print for signed values */
            printf("%4d ", (int)C[i][j]);
        }
        xil_printf("\r\n");
    }

    int32_t checksum = 0;
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++)
            checksum += C[i][j];

    xil_printf("Checksum = %d\r\n", (int)checksum);

    cleanup_platform();
    return 0;
}
