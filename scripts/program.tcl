# Program FPGA script (universal - works for all projects)
#
# Usage: vivado -mode batch -source program.tcl -tclargs <project_dir>
# Example: vivado -mode batch -source program.tcl -tclargs 05-uart-transmitter

# Get project directory from command line argument
if { $argc != 1 } {
    puts "ERROR: Usage: vivado -mode batch -source program.tcl -tclargs <project_dir>"
    puts "Example: vivado -mode batch -source program.tcl -tclargs 05-uart-transmitter"
    exit 1
}

set project_dir [lindex $argv 0]

# Find bitstream file (.bit) in the project's impl_1 directory
set bit_files [glob -nocomplain ${project_dir}/*.runs/impl_1/*.bit]
if { [llength $bit_files] == 0 } {
    puts "ERROR: No bitstream (.bit) file found in: ${project_dir}/*.runs/impl_1/"
    puts "Run the build script first."
    exit 1
}

set bitstream [lindex $bit_files 0]

puts "=========================================="
puts "Programming FPGA"
puts "Project: $project_dir"
puts "Bitstream: $bitstream"
puts "=========================================="

# Open hardware manager
open_hw_manager

# Connect to hardware server
connect_hw_server -allow_non_jtag

# Get the first available hardware target
set hw_target [lindex [get_hw_targets] 0]
if {$hw_target == ""} {
    puts "ERROR: No hardware targets found!"
    puts "Is the FPGA board connected and powered on?"
    disconnect_hw_server
    close_hw_manager
    exit 1
}

puts "\n>>> Found hardware target: $hw_target"
current_hw_target $hw_target
open_hw_target

# Get the first device
set hw_device [lindex [get_hw_devices] 0]
if {$hw_device == ""} {
    puts "ERROR: No hardware devices found!"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 1
}

puts ">>> Found hardware device: $hw_device"
current_hw_device $hw_device

# Program the device with the bitstream
puts ">>> Programming device with: $bitstream"
set_property PROGRAM.FILE $bitstream $hw_device
program_hw_devices $hw_device

puts "\n=========================================="
puts "FPGA programmed successfully!"
puts "=========================================="

# Close connections
close_hw_target
disconnect_hw_server
close_hw_manager
