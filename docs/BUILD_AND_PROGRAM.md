# FPGA Build and Programming Guide

Universal TCL scripts for building and programming any FPGA project in this repository.

## Scripts

- **[../scripts/build.tcl](../scripts/build.tcl)** - Synthesizes, implements, and generates bitstream for any project
- **[../scripts/program.tcl](../scripts/program.tcl)** - Programs FPGA with generated bitstream

## Usage

### Building a Project

From the repository root directory:

```bash
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl -tclargs <project_dir>
```

**Examples:**

```bash
# Build project 01
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl -tclargs 01-led-blink

# Build project 05
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl -tclargs 05-fpga-uart-transmitter

# Build any numbered project
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl -tclargs 06-next-project
```

### Programming FPGA

From the repository root directory:

```bash
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/program.tcl -tclargs <project_dir>
```

**Examples:**

```bash
# Program with project 01 bitstream
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/program.tcl -tclargs 01-led-blink

# Program with project 05 bitstream
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/program.tcl -tclargs 05-fpga-uart-transmitter
```

## How It Works

### build.tcl

1. Accepts project directory as command-line argument
2. Automatically finds the `.xpr` file in that directory
3. Runs full build flow: synthesis -> implementation -> bitstream generation
4. Reports errors if build fails at any stage

### program.tcl

1. Accepts project directory as command-line argument
2. Automatically finds the `.bit` file in `<project_dir>/*.runs/impl_1/`
3. Connects to FPGA hardware
4. Programs the device
5. Reports errors if hardware not found or programming fails

## Error Handling

Both scripts include comprehensive error checking:

- **Missing project directory** - Shows usage instructions
- **No .xpr file found** - Reports error and exits
- **No bitstream found** - Reminder to build first
- **Hardware not connected** - Shows helpful error message
- **Build failures** - Reports which stage failed (synthesis/implementation/bitstream)

## Requirements

- Xilinx Vivado installed (tested with 2025.1)
- FPGA board connected via USB (for programming)
- Project must have a `.xpr` file in its directory
- Bitstream must exist (run build first before programming)

## Advantages Over Project-Specific Scripts

- **Single source of truth** - One script works for all projects
- **Auto-discovery** - No need to hardcode file names
- **Better error messages** - Comprehensive error checking
- **Easier maintenance** - Update once, benefits all projects
- **Consistent workflow** - Same commands for all projects, just change the directory name

## Quick Reference

```bash
# Full workflow for any project:

# 1. Build
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/build.tcl -tclargs <project_dir>

# 2. Program
"C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts/program.tcl -tclargs <project_dir>
```

Replace `<project_dir>` with:

- `01-led-blink`
- `02-counter`
- `03-pwm-led`
- `04-button-debounce`
- `05-fpga-uart-transmitter`
- `06-next-project`
- etc.
