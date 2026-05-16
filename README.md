# Hardware-Accelerated Matrix Multiplication

## Project Overview
This project implements a hardware-software co-design on the Zybo Z7 FPGA board to accelerate matrix multiplication ($C = A \times B$). It offloads the intensive computation to the FPGA's Programmable Logic (PL) using a custom pipelined Processing Element (PE) array, while the ARM Cortex-A9 Processing System (PS) handles control, data setup, and correctness verification. 

The PS writes input matrices (8-bit integers) to DDR memory, configures the PL accelerator via AXI-Lite registers, and triggers an AXI DMA transfer. Data streams into the PL, gets accumulated into 32-bit integers to prevent overflow, and the result is streamed back to DDR. Finally, the PS verifies the hardware output against a pure software baseline.

## Completed Phases
- **Phase 1: Software Matrix Multiply** - Created a pure C software reference implementation on Mac.
- **Phase 2: PE Simulation** - Wrote and simulated the smallest hardware block: a single multiply-accumulate Processing Element (PE) in Verilog.
- **Phase 3: Zybo Hello World** - Built the base Zynq block design and verified PS execution on the board.
- **Phase 4: ARM Software Matmul** - Validated the software reference implementation on the Zybo ARM processor.
- **Phase 5: AXI-Lite Register Test** - Created a custom PL IP with memory-mapped registers to allow ARM to send control signals.
- **Phase 6: Hardcoded PL Matmul** - Implemented a small, hardcoded matrix multiplication FSM in the PL to verify computation without DMA complexity.
- **Phase 7: DMA Loopback** - Connected and verified AXI DMA by streaming data from DDR, looping it back, and receiving it in DDR.
- **Phase 8: Pass-Through Accelerator** - Replaced the loopback with a custom streaming PL block to verify AXI-Stream handshaking.
- **Phase 9: Real Matmul Accelerator** - Integrate the 4x4 matrix multiplication FSM with the AXI DMA data streams.

## Remaining Phases
- **Phase 10: Scaling Dimensions** - Scale the single-PE design to handle larger matrix sizes incrementally (8x8, 16x16, 32x32, 64x64).
- **Phase 11: 8-PE Array** - Add 8 Processing Elements operating in parallel to compute multiple columns simultaneously.
- **Phase 12: Larger Matrix Support** - Test the 8-PE array on larger matrix dimensions, observing BRAM and resource usage.
- **Phase 13: Tiling & Double Buffering** - Implement BRAM tile buffers (e.g., 32x32 blocks) and ping-pong buffering to efficiently process matrices that exceed on-chip memory limits.
