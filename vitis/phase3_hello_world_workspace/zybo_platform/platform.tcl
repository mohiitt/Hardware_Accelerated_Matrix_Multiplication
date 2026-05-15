# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct C:\Users\019130137\workspace\zybo_platform\platform.tcl
# 
# OR launch xsct and run below command.
# source C:\Users\019130137\workspace\zybo_platform\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {zybo_platform}\
-hw {C:\Users\019130137\zybo1\design_1_wrapper.xsa}\
-proc {ps7_cortexa9_0} -os {standalone} -out {C:/Users/019130137/workspace}

platform write
platform generate -domains 
platform active {zybo_platform}
platform generate
