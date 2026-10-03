source "helpers.tcl"

read_lef sky130hd/sky130hd.tlef
read_lef sky130hd/sky130_fd_sc_hd_merged.lef
read_liberty sky130hd/sky130_fd_sc_hd__tt_025C_1v80.lib

read_verilog place_sort_sky130.v
link_design place_sort

create_clock -name main_clock -period 2.0000 -waveform {0.0000 1.0000} [get_ports {clock}]

set_dft_config -max_length 10

scan_replace

proc place_inst { inst x y } {
  set db_inst [[ord::get_db_block] findInst $inst]
  $db_inst setLocation $x $y
  $db_inst setOrient R0
  $db_inst setPlacementStatus PLACED
}

# Two rows of five cells. A greedy nearest-neighbor seed walks the bottom row
# left-to-right then snakes back along the top row; the 2-Opt and 3-Opt local
# search passes then refine the ordering. Exercises OptimizeScanWirelength
# (nearest-neighbor seed -> 2-Opt -> 3-Opt).
place_inst ff1_clk1_rising  2000 2000
place_inst ff2_clk1_rising  8000 3000
place_inst ff3_clk1_rising  3000 8000
place_inst ff4_clk1_rising  7000 7000
place_inst ff5_clk1_rising  1000 5000
place_inst ff6_clk1_rising  5000 1000
place_inst ff7_clk1_rising  6000 9000
place_inst ff8_clk1_rising  9000 6000
place_inst ff9_clk1_rising  4000 4000
place_inst ff10_clk1_rising 5000 5000

# Dedicated scan output: functional output ports must retain their Q nets.
set block [ord::get_db_block]
set so_net [odb::dbNet_create $block scan_out_0]
set so_port [odb::dbBTerm_create $so_net scan_out_0]
$so_port setIoType OUTPUT
$so_port setSigType SCAN
set functional_outputs {}
for {set i 1} {$i <= 10} {incr i} {
  dict set functional_outputs output$i [[$block findBTerm output$i] getNet]
}

execute_dft_plan

# Reorder the stitched chain to reduce wirelength and re-stitch in odb.
scan_opt

# Independently trace the optimized physical order to the original fixed SO.
set net [[$block findBTerm scan_in_0] getNet]
set so_net [$so_port getNet]
set order {}
set visited {}
while {$net != $so_net} {
  if {[lsearch -exact $visited $net] >= 0} { error "scan cycle" }
  lappend visited $net
  set successors {}
  foreach pin [$net getITerms] {
    if {[[$pin getMTerm] getName] == "SCD"} {
      lappend successors [$pin getInst]
    }
  }
  if {[llength $successors] != 1} { error "scan fork or missing fixed SO" }
  set inst [lindex $successors 0]
  lappend order [$inst getName]
  set net [[$inst findITerm Q] getNet]
}
if {[llength $order] != 10 || [llength [lsort -unique $order]] != 10} {
  error "scan membership changed or SO is interior"
}
foreach pin [$so_net getITerms] {
  if {[[$pin getMTerm] getName] == "SCD"} { error "SO is not the tail" }
}
dict for {name net} $functional_outputs {
  if {[[$block findBTerm $name] getNet] != $net} {
    error "functional output moved"
  }
}
set metadata {}
foreach chain [[$block getDft] getScanChains] {
  foreach partition [$chain getScanPartitions] {
    foreach scan_list [$partition getScanLists] {
      foreach scan_inst [$scan_list getScanInsts] {
        lappend metadata [[$scan_inst getInst] getName]
      }
    }
  }
}
if {[lreverse $metadata] != $order} { error "stale optimized scan metadata" }

set verilog_file [make_result_file scan_opt_sky130.v]
write_verilog $verilog_file
diff_files $verilog_file scan_opt_sky130.vok
