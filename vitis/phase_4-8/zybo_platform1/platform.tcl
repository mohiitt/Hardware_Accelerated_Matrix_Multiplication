# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\zybo_platform1\platform.tcl
# 
# OR launch xsct and run below command.
# source C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\zybo_platform1\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {zybo_platform1}\
-hw {C:\Users\019130137\matrix_accel_project\matrix_accel_project\vivado\phase4_arm_matmul\phase5_AXI_LITE.xsa}\
-proc {ps7_cortexa9_0} -os {standalone} -out {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace}

platform write
platform generate -domains 
platform active {zybo_platform1}
platform generate
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase5_AXI_LITE.xsa}
platform generate -domains 
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase6_tinyPL_hardcoded.xsa}
platform generate -domains 
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase7-axi-dma-loopback.xsa}
platform generate -domains 
platform active {zybo_platform1}
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase7-axi-dma-loopback.xsa}
platform generate
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase8-pass-through-accel.xsa}
platform generate -domains 
platform config -updatehw {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vivado/phase4_arm_matmul/phase8-pass-through-accelerator.xsa}
platform clean
platform generate
platform clean
platform generate
