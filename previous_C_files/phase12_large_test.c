/*
 * Phase 12: Large Matrix Test (32x32, 64x64)
 * Same DMA flow as Phase 11 but larger. Change TEST_SIZE below.
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
#define REG_CTRL 0x00
#define REG_STATUS 0x04
#define REG_M 0x08
#define REG_K 0x0C
#define REG_N 0x10

#define TEST_SIZE 32
#define M_DIM TEST_SIZE
#define K_DIM TEST_SIZE
#define N_DIM TEST_SIZE
#define A_BYTES (M_DIM*K_DIM)
#define B_BYTES (K_DIM*N_DIM)
#define A_WORDS ((A_BYTES+3)/4)
#define B_WORDS ((B_BYTES+3)/4)
#define INPUT_WORDS (A_WORDS+B_WORDS)
#define OUTPUT_WORDS (M_DIM*N_DIM)

u32 input_buffer[2048] __attribute__((aligned(64)));
u32 output_buffer[4096] __attribute__((aligned(64)));
int8_t A_mat[4096];
int8_t B_mat[4096];
int32_t C_sw[4096];

static unsigned int seed = 99999;
int8_t my_rand(void) { seed=seed*1103515245+12345; return (int8_t)((seed>>16)%11)-5; }
void pack_i8(const int8_t *s,u32 *d,int n) {
    for(int w=0;w<(n+3)/4;w++){u32 v=0;for(int b=0;b<4;b++){int i=w*4+b;if(i<n)v|=((u32)(uint8_t)s[i])<<(b*8);}d[w]=v;}
}

int main() {
    init_platform();
    xil_printf("Large Matrix Test (%dx%d)\r\n",TEST_SIZE,TEST_SIZE);

    for(int i=0;i<A_BYTES;i++) A_mat[i]=my_rand();
    for(int i=0;i<B_BYTES;i++) B_mat[i]=my_rand();
    for(int i=0;i<M_DIM;i++)
        for(int j=0;j<N_DIM;j++){int32_t s=0;for(int k=0;k<K_DIM;k++) s+=(int32_t)A_mat[i*K_DIM+k]*(int32_t)B_mat[k*N_DIM+j];C_sw[i*N_DIM+j]=s;}

    pack_i8(A_mat,input_buffer,A_BYTES);
    pack_i8(B_mat,&input_buffer[A_WORDS],B_BYTES);
    for(int i=0;i<OUTPUT_WORDS;i++) output_buffer[i]=0;

    XAxiDma dma; XAxiDma_Config *cfg=XAxiDma_LookupConfig(DMA_DEV_ID);
    XAxiDma_CfgInitialize(&dma,cfg);
    XAxiDma_IntrDisable(&dma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DEVICE_TO_DMA);

    Xil_Out32(ACCEL_BASE+REG_M,M_DIM);
    Xil_Out32(ACCEL_BASE+REG_K,K_DIM);
    Xil_Out32(ACCEL_BASE+REG_N,N_DIM);
    Xil_DCacheFlushRange((UINTPTR)input_buffer,INPUT_WORDS*4);
    Xil_DCacheFlushRange((UINTPTR)output_buffer,OUTPUT_WORDS*4);

    XAxiDma_SimpleTransfer(&dma,(UINTPTR)output_buffer,OUTPUT_WORDS*4,XAXIDMA_DEVICE_TO_DMA);
    Xil_Out32(ACCEL_BASE+REG_CTRL,1);
    XAxiDma_SimpleTransfer(&dma,(UINTPTR)input_buffer,INPUT_WORDS*4,XAXIDMA_DMA_TO_DEVICE);

    while(XAxiDma_Busy(&dma,XAXIDMA_DMA_TO_DEVICE));
    while(XAxiDma_Busy(&dma,XAXIDMA_DEVICE_TO_DMA));
    while((Xil_In32(ACCEL_BASE+REG_STATUS)&1)==0);
    Xil_DCacheInvalidateRange((UINTPTR)output_buffer,OUTPUT_WORDS*4);

    int32_t *C_hw=(int32_t*)output_buffer; int errors=0;
    for(int i=0;i<M_DIM*N_DIM;i++)
        if(C_hw[i]!=C_sw[i]){if(errors<3) xil_printf("Mismatch %d: exp=%d got=%d\r\n",i,(int)C_sw[i],(int)C_hw[i]);errors++;}

    if(errors==0) xil_printf("LARGE MATRIX %dx%d PASS\r\n",TEST_SIZE,TEST_SIZE);
    else xil_printf("LARGE MATRIX %dx%d FAIL: %d errors\r\n",TEST_SIZE,TEST_SIZE,errors);
    cleanup_platform();
    return 0;
}
