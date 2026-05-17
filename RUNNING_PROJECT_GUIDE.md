# Running the Hardware-Accelerated Matrix Multiplication Project

## 1. Requirements

- Vivado 2021.1
- Vitis 2021.1
- Zybo Z7 FPGA board

## 2. Required Files

### Vivado Files
```text
design_1_final.tcl
phase18B_final.xsa
matrix_accel_v1_0.v
matrix_accel_v1_0_S00_AXI.v
```

### Vitis Files
```text
phase18B_main.c
```

## 3. Create Vivado Project

1. Open Vivado 2021.1
2. Create New Project
3. Select RTL Project
4. Enable:

```text
Do not specify sources at this time
```

5. Select Zybo Z7-10 board

## 4. Recreate Block Design

Open Tcl Console and run:

```tcl
source design_1_final.tcl
```

This recreates:
- Zynq PS
- AXI DMA
- AXI interconnects
- AXI Stream FIFO
- matrix_accel IP

## 5. Add RTL Files

Go to:

```text
Project Manager → Add Sources
```

Add:

```text
matrix_accel_v1_0.v
matrix_accel_v1_0_S00_AXI.v
```

## 6. Package Custom IP

Go to:

```text
Tools → Create and Package New IP
```

Choose:

```text
Package your current project
```

Add IP repository:

```text
Tools → Settings → IP → Repository
```

Refresh IP catalog:

```tcl
update_ip_catalog
```

## 7. Generate Bitstream

1. Open design_1.bd
2. Validate Design
3. Generate Output Products
4. Create HDL Wrapper
5. Generate Bitstream

## 8. Export Hardware

Go to:

```text
File → Export → Export Hardware
```

Enable:

```text
Include bitstream
```

Export:

```text
phase18B_final.xsa
```

Note: The repository already contains the exported XSA file.

## 9. Open Vitis

1. Launch Vitis 2021.1
2. Create workspace

## 10. Create Platform Project

Go to:

```text
File → New → Platform Project
```

Select:

```text
phase18B_final.xsa
```

## 11. Create Hello World Project

Go to:

```text
File → New → Application Project
```

Template:

```text
Hello World
```

## 12. Replace helloworld.c

Open:

```text
src/helloworld.c
```

Delete contents and copy:

```text
phase18B_main.c
```

into:

```text
helloworld.c
```

## 13. Build Project

Click:

```text
Build Project
```

## 14. Program FPGA

Go to:

```text
Xilinx → Program FPGA
```

## 15. Run on Hardware

Right click application:

```text
Run As → Launch on Hardware
```

Open UART terminal:
- 115200 baud
- correct COM port

## 16. Expected Output

```text
Phase 18B 64-bit stream tiled test (64x64, tile=32)
Software time: ~10073 us
Hardware time: ~1952 us
Speedup: ~5.15x
PHASE 18B 64-BIT STREAM 64x64 PASS
```
