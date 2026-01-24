# Regenerate GTX IP with 64-bit data width
# Run with: vivado -mode batch -source regen_64bit.tcl

# Open the managed IP project
open_project managed_ip_project/managed_ip_project.xpr

# Update the GTX IP configuration to 64-bit
# This requires modifying gt0_val_tx_data_width and gt0_val_rx_data_width
set_property -dict [list \
    CONFIG.gt0_val_tx_data_width {64} \
    CONFIG.gt0_val_rx_data_width {64} \
    CONFIG.gt0_val_int_data_width {0} \
] [get_ips gtx_10gbase_r]

# Generate the IP outputs
generate_target all [get_ips gtx_10gbase_r]

# Synthesize the IP
synth_ip [get_ips gtx_10gbase_r]

puts "GTX IP regenerated with 64-bit data width"
close_project
