/*
 * Phase 13: Tiled Matrix Multiply Test
 * For matrices larger than tile size (32x32), the accelerator
 * processes tiles and accumulates partial sums.
 * Software sends tiles via DMA, reads partial C tiles back.
 *
 * This version does tiling in SOFTWARE (PS controls tile loop).
 * The PL accelerator still does one tile multiply at a time.
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

#define DMA_DEV_ID   XPAR_AXIDMA_0_DEVICE_ID
#define ACCEL_BASE   XPAR_MATRIX_ACCEL_0_S00_AXI_BASEADDR
#define REG_CTRL 0x00
#define REG_STATUS 0x04
#define REG_M 0x08
#define REG_K 0x0C
#define REG_N 0x10

#define FULL_SIZE 64
#define TILE 32

int8_t A_full[FULL_SIZE*FULL_SIZE];
int8_t B_full[FULL_SIZE*FULL_SIZE];
int32_t C_sw[FULL_SIZE*FULL_SIZE];
int32_t C_hw[FULL_SIZE*FULL_SIZE];

/* Tile buffers for DMA */
u32 input_tile[512]  __attribute__((aligned(64)));
u32 output_tile[1024] __attribute__((aligned(64)));

/* Tile scratch */
int8_t A_tile[TILE*TILE];
int8_t B_tile[TILE*TILE];

static unsigned int seed = 77777;
int8_t my_rand(void) { seed=seed*1103515245+12345; return (int8_t)((seed>>16)%11)-5; }

void pack_i8(const int8_t *s,u32 *d,int n) {
    for(int w=0;w<(n+3)/4;w++){u32 v=0;for(int b=0;b<4;b++){int i=w*4+b;if(i<n)v|=((u32)(uint8_t)s[i])<<(b*8);}d[w]=v;}
}

/* Extract a tile from a full matrix */
void extract_tile(const int8_t *full, int8_t *tile,
                  int row_start, int col_start,
                  int tile_rows, int tile_cols, int full_cols) {
    for (int i=0; i<tile_rows; i++)
        for (int j=0; j<tile_cols; j++)
            tile[i*tile_cols+j] = full[(row_start+i)*full_cols + col_start+j];
}

int main() {
    init_platform();
    xil_printf("Tiled Matrix Multiply Test (%dx%d, tile=%d)\r\n", FULL_SIZE, FULL_SIZE, TILE);

    /* Generate data */
    for(int i=0;i<FULL_SIZE*FULL_SIZE;i++) A_full[i]=my_rand();
    for(int i=0;i<FULL_SIZE*FULL_SIZE;i++) B_full[i]=my_rand();

    /* Software reference */
    for(int i=0;i<FULL_SIZE;i++)
        for(int j=0;j<FULL_SIZE;j++){
            int32_t s=0;
            for(int k=0;k<FULL_SIZE;k++) s+=(int32_t)A_full[i*FULL_SIZE+k]*(int32_t)B_full[k*FULL_SIZE+j];
            C_sw[i*FULL_SIZE+j]=s;
        }

    /* Clear HW result */
    memset(C_hw, 0, sizeof(C_hw));

    /* DMA init */
    XAxiDma dma; XAxiDma_Config *cfg=XAxiDma_LookupConfig(DMA_DEV_ID);
    XAxiDma_CfgInitialize(&dma,cfg);
    XAxiDma_IntrDisable(&dma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DEVICE_TO_DMA);

    int num_tiles = FULL_SIZE / TILE;

    /* Tiled multiply: C[ti][tj] += A[ti][tk] * B[tk][tj] */
    for (int ti=0; ti<num_tiles; ti++) {
        for (int tj=0; tj<num_tiles; tj++) {
            for (int tk=0; tk<num_tiles; tk++) {
                /* Extract tiles */
                extract_tile(A_full, A_tile, ti*TILE, tk*TILE, TILE, TILE, FULL_SIZE);
                extract_tile(B_full, B_tile, tk*TILE, tj*TILE, TILE, TILE, FULL_SIZE);

                /* Pack into DMA buffer */
                int a_bytes = TILE*TILE;
                int a_words = (a_bytes+3)/4;
                pack_i8(A_tile, input_tile, a_bytes);
                pack_i8(B_tile, &input_tile[a_words], a_bytes);
                int input_words = a_words*2;
                int output_words = TILE*TILE;
                for(int i=0;i<output_words;i++) output_tile[i]=0;

                /* Configure accelerator for tile size */
                Xil_Out32(ACCEL_BASE+REG_M, TILE);
                Xil_Out32(ACCEL_BASE+REG_K, TILE);
                Xil_Out32(ACCEL_BASE+REG_N, TILE);

                Xil_DCacheFlushRange((UINTPTR)input_tile, input_words*4);
                Xil_DCacheFlushRange((UINTPTR)output_tile, output_words*4);

                XAxiDma_SimpleTransfer(&dma,(UINTPTR)output_tile,output_words*4,XAXIDMA_DEVICE_TO_DMA);
                Xil_Out32(ACCEL_BASE+REG_CTRL,1);
                XAxiDma_SimpleTransfer(&dma,(UINTPTR)input_tile,input_words*4,XAXIDMA_DMA_TO_DEVICE);

                while(XAxiDma_Busy(&dma,XAXIDMA_DMA_TO_DEVICE));
                while(XAxiDma_Busy(&dma,XAXIDMA_DEVICE_TO_DMA));
                while((Xil_In32(ACCEL_BASE+REG_STATUS)&1)==0);
                Xil_DCacheInvalidateRange((UINTPTR)output_tile,output_words*4);

                /* Accumulate partial product into C_hw */
                int32_t *tile_result = (int32_t*)output_tile;
                for(int i=0;i<TILE;i++)
                    for(int j=0;j<TILE;j++)
                        C_hw[(ti*TILE+i)*FULL_SIZE + (tj*TILE+j)] += tile_result[i*TILE+j];
            }
        }
    }

    /* Compare */
    int errors=0;
    for(int i=0;i<FULL_SIZE*FULL_SIZE;i++)
        if(C_hw[i]!=C_sw[i]){if(errors<3) xil_printf("Mismatch %d: exp=%d got=%d\r\n",i,(int)C_sw[i],(int)C_hw[i]);errors++;}

    if(errors==0) xil_printf("TILED MATRIX MULTIPLY %dx%d PASS\r\n",FULL_SIZE,FULL_SIZE);
    else xil_printf("TILED MATRIX MULTIPLY FAIL: %d errors\r\n",errors);
    cleanup_platform();
    return 0;
}
