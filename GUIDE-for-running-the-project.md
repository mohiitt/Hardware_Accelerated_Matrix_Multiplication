# 🚀 Portable GitHub Project Structure & Vivado Commands

This guide provides a comprehensive walkthrough for rebuilding, programming, and running the **Phase 18B (5.15× Speedup)** matrix multiplier accelerator on the **Zybo Z7-10** board. It has been specifically designed to be highly portable, allowing teammates to clone the repository on any laptop and successfully run the project in minutes.

> [!NOTE]
> This guide is optimized for **Vivado 2021.1** and **Vitis 2021.1**. Ensure your tools are set up in a 64-bit Windows or Linux environment.

---

## 📁 Final GitHub File Structure

To guarantee portability, ensure that your repository directory matches the following structure. The packed custom AXI-Stream IP files must reside directly inside `vivado/ip_repo/` (without any extra nested folders) so that the Tcl scripts can resolve dependencies automatically.

```text
matrix_accel_project/
|
|-- README.md
|
|-- vivado/
|   |-- design_1_final.tcl            # Exported block design Tcl script
|   |-- phase18B_final.xsa            # Generated hardware handoff file (pre-built)
|   |
|   |-- ip_repo/                      # Packaged Custom IP Repository
|   |   |-- component.xml             # IP Metadata/Packaging Definition
|   |   |
|   |   |-- hdl/                      # Verilog Source Files
|   |   |   |-- matrix_accel_v1_0.v            # Top-level IP wrapper
|   |   |   |-- matrix_accel_v1_0_S00_AXI.v    # Core FSM & PE compute engine
|   |   |
|   |   |-- xgui/                     # Vivado IP Customization GUI script
|   |       |-- matrix_accel_axis64_v1_0.tcl
|   |
|-- vitis/
    |-- phase18B_final.c              # Core bare-metal C benchmark application
```

---

## 🖥️ Vivado Tcl Commands (Rebuilding from Scratch)

Launch **Vivado 2021.1**, then run the following commands sequentially in the **Tcl Console** located at the bottom of the interface.

### 1️⃣ Set Up Workspace Directory
Update this path to match the absolute directory where the GitHub repository is cloned on your local machine:
```tcl
cd C:/path/to/matrix_accel_project/vivado
```

### 2️⃣ Create a Clean Vivado Project
Creates a fresh project target for the Zynq-7010 SoC inside a short, safe local path (e.g., `C:/vivado/demo`) to prevent Windows MAX_PATH character limits:
```tcl
create_project demo C:/vivado/demo -part xc7z010clg400-1 -force
```

### 3️⃣ Set Board Properties
Configure the project specifically to target the Digilent Zybo Z7-10:
```tcl
set_property board_part digilentinc.com:zybo-z7-10:part0:1.0 [current_project]
```

### 4️⃣ Import Custom AXI IP Repository
Add the custom 64-bit matrix accelerator IP folder to the project’s search path and update the catalog:
```tcl
set_property ip_repo_paths [file normalize "./ip_repo"] [current_project]
update_ip_catalog
```

### 5️⃣ Verify Custom IP Detection
Ensure that Vivado has found and cataloged your custom matrix accelerator IP:
```tcl
get_ipdefs -all xilinx.com:user:matrix_accel_axis64:1.0
```
> [!IMPORTANT]
> If the command above prints the IP definition path (`xilinx.com:user:matrix_accel_axis64:1.0`), proceed. If it returns empty, check the [If the IP Is Not Found](#-if-the-ip-is-not-found) troubleshooting section below.

### 6️⃣ Source the Block Design Tcl
Generate the entire Zynq system, including the ARM PS, AXI DMA, Interconnect, Clock Reset blocks, and the custom accelerator IP:
```tcl
source ./design_1_final.tcl
update_compile_order -fileset sources_1
```

### 7️⃣ Validate and Wrap Block Design
Validate the block design and generate the top-level HDL wrapper securely (this avoids hardcoded build paths):
```tcl
validate_bd_design
generate_target all [get_files design_1.bd]
set wrapper_path [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_path
```

### 8️⃣ Generate Bitstream
Compile the block design, run synthesis, and generate the final hardware bitstream:
```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

### 9️⃣ Export Hardware Handoff (XSA)
Export the finalized hardware platform along with the compiled bitstream to feed into Vitis:
```tcl
write_hw_platform -fixed -include_bit -force -file phase18B_final.xsa
```

---

## 🔍 If the IP Is Not Found

If `get_ipdefs` returns empty, perform these quick sanity checks:
1. Ensure the following XML metadata file exists:
   ```text
   matrix_accel_project/vivado/ip_repo/component.xml
   ```
2. Verify that `component.xml` defines the exact VLNV version requested:
   ```text
   xilinx.com:user:matrix_accel_axis64:1.0
   ```

---

## 🧠 Vitis Software Setup & Execution

### 1️⃣ Launch Vitis 2021.1
1. Open **Vitis 2021.1**.
2. Select a clean directory as your workspace path (e.g., `C:/vitis_workspace`).

### 2️⃣ Create Platform Project
1. Go to **File ➡️ New ➡️ Platform Project**.
2. Set the Platform Project name to `design_1_wrapper`.
3. Under **Hardware Specification**, select the exported `.xsa` file:
   ```text
   matrix_accel_project/vivado/phase18B_final.xsa
   ```
4. Click **Finish**, then right-click the platform project in the explorer and select **Build Project**.

### 3️⃣ Create Application Project
1. Go to **File ➡️ New ➡️ Application Project**.
2. Select `design_1_wrapper` as the target hardware platform.
3. Name the application `matrix_accel_app` and target the `ps7_cortexa9_0` processor core running bare-metal.
4. Select the **Hello World** template, then click **Finish**.

### 4️⃣ Import Phase 18B Benchmark C File
1. In the Vitis Explorer, navigate to:
   ```text
   matrix_accel_app ➡️ src ➡️ helloworld.c
   ```
2. Right-click and delete or clear the contents of `helloworld.c`.
3. Open `matrix_accel_project/vitis/phase18B_final.c` in any editor, copy the entire file contents, and paste them into `helloworld.c`.
4. Press `Ctrl+S` to save.

### 5️⃣ Build and Program
1. Right-click `matrix_accel_app` and select **Build Project**.
2. Connect your Zybo Z7-10 board via USB and power it on.
3. Click **Xilinx ➡️ Program FPGA** to download the bitstream onto the Programmable Logic (PL).

### 6️⃣ Run on Hardware
1. Open your favorite serial console terminal (e.g., PuTTY, Tera Term, or the built-in Vitis Serial Terminal).
2. Configure the port connection:
   * **Baud Rate**: `115200`
   * **Data Bits**: `8`
   * **Stop Bits**: `1`
3. Right-click `matrix_accel_app` in Vitis, then select **Run As ➡️ Launch on Hardware (Single Application Debug)**.

---

## 📈 Expected Terminal Output

When the application runs, it will output the timed benchmarks for the software golden model vs. the DMA-streamed, double-buffered hardware accelerator:

```text
Phase 18B 64-bit stream tiled test (64x64, tile=32)
Software time: 10073 us
Pre-packing 64-bit tile streams...
Running hardware on 64-bit pre-packed streams...
Hardware time, 64-bit pre-packed input: 1952 us
Speedup: 5.15 x
Comparing results...
PHASE 18B 64-BIT STREAM 64x64 PASS
```
