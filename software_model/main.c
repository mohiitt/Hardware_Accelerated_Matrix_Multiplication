#include <stdio.h>
#include <stdint.h>

#define M 4
#define K 4
#define N 4

int main() {
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

    // Triple-nested loop: standard matrix multiply
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K; k++) {
                sum += (int32_t)A[i][k] * (int32_t)B[k][j];
            }
            C[i][j] = sum;
        }
    }

    printf("C =\n");
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            printf("%4d ", C[i][j]);
        }
        printf("\n");
    }

    // Print checksum for later hardware verification
    int32_t checksum = 0;
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            checksum += C[i][j];
        }
    }
    printf("\nChecksum (sum of all C): %d\n", checksum);

    return 0;
}
