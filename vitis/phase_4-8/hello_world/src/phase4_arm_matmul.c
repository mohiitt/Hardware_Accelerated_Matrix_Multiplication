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
