# Hardware-Accelerated Matrix Multiplication

## Project Overview

This project implements a progressively optimized hardware-software co-design for matrix multiplication on the **Zybo Z7 (Zynq-7000)** FPGA platform.

The system accelerates matrix multiplication:

\[
C = A \times B
\]

by offloading computation from the ARM Cortex-A9 Processing System (PS) to a custom accelerator implemented in the FPGA Programmable Logic (PL).

The final accelerator supports:

- 64×64 matrix multiplication
- 32×32 tiled execution
- int8 input matrices
- int32 accumulation/output
- AXI DMA streaming
- 64-bit AXI-Stream
- 16-column parallel compute path
- BRAM-based tile buffers
- Ping-pong buffering
- True overlapped load/compute scheduling

The project evolved incrementally through multiple hardware and software optimization phases, beginning with a pure software implementation and ending with a fully pipelined tiled accelerator achieving over **5× speedup** versus the ARM software baseline.

---

# Final Performance

| Configuration | Software Time | Hardware Time | Speedup |
|---|---|---|---|
| Phase 13 initial tiled | 10048 us | 14879 us | 0.67× |
| Phase 14 PL accumulation | 10072 us | 8760 us | 1.14× |
| Phase 15 pre-packed streams | 10049 us | 3178 us | 3.16× |
| Phase 16 64-bit AXI stream | 10072 us | 3293 us | 3.05× |
| Phase 17C fast output path | 10073 us | 3171 us | 3.17× |
| Phase 18A 16-column PE path | 10073 us | 2136 us | 4.71× |
| Phase 18B true overlap | 10073 us | 1952 us | 5.15× |

---

# Final Accelerator Features

- AXI-Lite control interface
- AXI DMA integration
- 64-bit AXI-Stream
- BRAM-based tile buffers
- Ping-pong A/B buffering
- PL-side K-tile accumulation
- 16-column parallel MAC datapath
- 16-bank B tile BRAM organization
- 16-bank C accumulator BRAM organization
- Fast dual-output packing path
- True overlapped prefetch + compute scheduling

---

# Phase Evolution

## Phase 1 — Software Matrix Multiplication
- Pure software matrix multiplication reference implementation in C
- Correctness validation
- Timing baseline

## Phase 2 — Processing Element (PE) Simulation
- Single multiply-accumulate PE in Verilog
- int8 multiplication
- int32 accumulation

## Phase 3 — Zybo Bring-Up
- Base Zynq block design
- ARM execution validation
- UART verification

## Phase 4 — ARM Software Matmul
- Matrix multiplication running on ARM Cortex-A9
- On-board software timing

## Phase 5 — AXI-Lite Register Interface
- Custom AXI-Lite IP
- ARM ↔ PL communication
- Control/status registers

## Phase 6 — Hardcoded PL Matrix Multiply
- Small FSM-based matrix multiplication in PL
- No DMA yet
- End-to-end PL compute verification

## Phase 7 — DMA Loopback
- AXI DMA verification
- DDR → DMA → PL → DMA → DDR
- AXI-Stream testing

## Phase 8 — Streaming Pass-Through Accelerator
- Custom AXI-Stream accelerator block
- Stream handshaking validation

## Phase 9 — First Real DMA Matrix Multiply
Configuration:
- 4×4 matrix multiply
- 32-bit AXI stream
- Single compute path

Result:
```text
MATRIX MULTIPLY 4x4 PASS
```

## Phase 10 — Scaling to Larger Dimensions
Tested:
- 8×8
- 16×16

Result:
```text
MATRIX MULTIPLY 16x16 PASS
```

## Phase 11 — 8 Parallel Processing Elements
- 8 output columns computed simultaneously
- 8 accumulators
- Parallel MAC datapath

Result:
```text
8-PE MATRIX MULTIPLY PASS
```

## Phase 12 — BRAM-Based Tile Buffers
- BRAM A tile buffer
- Banked B BRAMs
- Banked C accumulator BRAMs
- Reduced LUT over-utilization

Result:
```text
32×32 BRAM MATRIX MULTIPLY PASS
```

## Phase 13 — 64×64 Software-Controlled Tiling
- 32×32 tiled execution
- Software-managed tile extraction
- PS-side partial accumulation

Result:
```text
TILED MATRIX MULTIPLY 64x64 PASS
```

## Phase 14 — PL-Side K-Tile Accumulation
- Partial accumulation moved into PL
- NUM_KTILES support
- Reduced PS overhead

Result:
```text
PL-SIDE KTILE ACCUMULATION 64x64 PASS
```

## Phase 15 — Pre-Packed Tile Streams
- Tile extraction/packing moved outside timed section
- Pre-packed DMA streams
- Major timing improvement

Result:
```text
PRE-PACKED TILE INPUT 64x64 PASS
```

## Phase 16 — 64-Bit AXI-Stream
- 32-bit → 64-bit AXI-Stream
- 8 int8 values per beat
- 2 int32 outputs per beat
- u64 software buffers

Result:
```text
PHASE 16 64-BIT STREAM 64x64 PASS
```

## Phase 17A — Ping-Pong Buffer Infrastructure
- A0/A1 tile buffers
- Duplicated B banks
- Buffer selectors

## Phase 17C — Faster Output Packing
- Shared-address dual-bank output read
- Reduced output FSM latency

Result:
```text
PHASE 17C 64-BIT STREAM 64x64 PASS
```

## Phase 18A — 16-Column Parallelism
- 16 B banks
- 16 C banks
- 16 MAC paths

Result:
```text
PHASE 18A 64-BIT STREAM 64x64 PASS
```

## Phase 18B — True K-Tile Prefetch Overlap
- Compute current K-tile while loading next K-tile
- Independent prefetch FSM
- True overlap scheduling

Result:
```text
PHASE 18B 64-BIT STREAM 64x64 PASS
```

---

# Technologies Used

- Zybo Z7 FPGA Board
- Xilinx Vivado
- Xilinx Vitis
- Verilog HDL
- AXI4-Lite
- AXI4-Stream
- AXI DMA
- Bare-metal C
- BRAM-based accelerator design

---

# Final Outcome

The final accelerator achieved:

```text
~5.15× speedup
```

over the ARM software baseline while maintaining full correctness.
