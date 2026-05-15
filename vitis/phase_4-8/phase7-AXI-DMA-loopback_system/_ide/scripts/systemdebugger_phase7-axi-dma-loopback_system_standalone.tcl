# Usage with Vitis IDE:
# In Vitis IDE create a Single Application Debug launch configuration,
# change the debug type to 'Attach to running target' and provide this 
# tcl script in 'Execute Script' option.
# Path of this script: C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\phase7-AXI-DMA-loopback_system\_ide\scripts\systemdebugger_phase7-axi-dma-loopback_system_standalone.tcl
# 
# 
# Usage with xsct:
# To debug using xsct, launch xsct and run below command
# source C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\phase7-AXI-DMA-loopback_system\_ide\scripts\systemdebugger_phase7-axi-dma-loopback_system_standalone.tcl
# 
connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~"APU*"}
rst -system
after 3000
targets -set -filter {jtag_cable_name =~ "Digilent Zybo Z7 210351BFAABCA" && level==0 && jtag_device_ctx=="jsn-Zybo Z7-210351BFAABCA-13722093-0"}
fpga -file C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace/phase7-AXI-DMA-loopback/_ide/bitstream/phase7-axi-dma-loopback.bit
targets -set -nocase -filter {name =~"APU*"}
loadhw -hw C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace/zybo_platform1/export/zybo_platform1/hw/phase7-axi-dma-loopback.xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
targets -set -nocase -filter {name =~"APU*"}
source C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace/phase7-AXI-DMA-loopback/_ide/psinit/ps7_init.tcl
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace/phase7-AXI-DMA-loopback/Debug/phase7-AXI-DMA-loopback.elf
configparams force-mem-access 0
targets -set -nocase -filter {name =~ "*A9*#0"}
con
