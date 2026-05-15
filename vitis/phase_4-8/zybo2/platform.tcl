# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\zybo2\platform.tcl
# 
# OR launch xsct and run below command.
# source C:\Users\019130137\matrix_accel_project\matrix_accel_project\vitis\phase4_arm_matmul_workspace\zybo2\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {zybo2}\
-hw {C:\Users\019130137\matrix_accel_project\matrix_accel_project\vivado\phase4_arm_matmul\phase8-pass-through-accelerator.xsa}\
-proc {ps7_cortexa9_0} -os {standalone} -out {C:/Users/019130137/matrix_accel_project/matrix_accel_project/vitis/phase4_arm_matmul_workspace}

platform write
platform generate -domains 
platform active {zybo2}
platform generate
platform clean
platform generate
