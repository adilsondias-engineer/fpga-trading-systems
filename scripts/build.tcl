# Vivado build script (universal - works for all projects)
#
# Usage: vivado -mode batch -source build.tcl -tclargs <project_dir>
# Example: vivado -mode batch -source build.tcl -tclargs 05-uart-transmitter

# Get project directory from command line argument
if { $argc != 1 } {
    puts "ERROR: Usage: vivado -mode batch -source build.tcl -tclargs <project_dir>"
    puts "Example: vivado -mode batch -source build.tcl -tclargs 05-uart-transmitter"
    exit 1
}

set project_dir [lindex $argv 0]

# Auto-increment build version
set version_file "${project_dir}/build_version.txt"
if {[file exists $version_file]} {
    set fp [open $version_file r]
    set build_version [read $fp]
    close $fp
    set build_version [string trim $build_version]
    if {![string is integer -strict $build_version]} {
        set build_version 0
    }
} else {
    set build_version 0
}

# Increment version
set build_version [expr {$build_version + 1}]

# Write back to file
set fp [open $version_file w]
puts $fp $build_version
close $fp

puts "=========================================="
puts "BUILD VERSION: $build_version"
puts "=========================================="

# Find .xpr file in the project directory
set xpr_files [glob -nocomplain -directory $project_dir *.xpr]
if { [llength $xpr_files] == 0 } {
    puts "ERROR: No .xpr file found in directory: $project_dir"
    exit 1
}

set_param general.maxThreads 1

set project_file [lindex $xpr_files 0]
puts "=========================================="
puts "Building project: $project_file"
puts "=========================================="

# Open the project
open_project $project_file

# Set build version as generic parameter for top-level entity
set_property generic "BUILD_VERSION=$build_version" [current_fileset]
puts "Setting generic BUILD_VERSION=$build_version"

# Reset runs to ensure clean build
reset_run synth_1
reset_run impl_1

# Launch synthesis
puts "\n>>> Starting synthesis..."
launch_runs synth_1 -jobs 1
wait_on_run synth_1

# Check synthesis status
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    close_project
    exit 1
}

if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: Synthesis did not complete successfully!"
    close_project
    exit 1
}

puts ">>> Synthesis completed successfully!"

# Launch implementation
puts "\n>>> Starting implementation..."
launch_runs impl_1 -jobs 1
wait_on_run impl_1

# Check implementation status
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    close_project
    exit 1
}

if {[get_property STATUS [get_runs impl_1]] != "route_design Complete!"} {
    puts "ERROR: Implementation did not complete successfully!"
    close_project
    exit 1
}

puts ">>> Implementation completed successfully!"

# Generate bitstream
puts "\n>>> Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1

puts "\n=========================================="
puts "Build finished successfully!"
puts "Project: $project_dir"
puts "=========================================="

# Close project
close_project
