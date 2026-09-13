# Pure Verilog-2001 synthesis check using the locally installed Vivado.
# Run: vivado -mode batch -nojournal -log build/raw_transport_no_sram/synth/vivado.log \
#       -source <absolute-path>/scripts/synth_check.tcl \
#       -tclargs <absolute-project-directory> [--keep-temp]
# FPGA mapping is a synthesizability/resource check, not an ASIC PPA estimate.
# The 10 ns clock is an arbitrary verification constraint, not a timing claim.
# --keep-temp is a Vivado 2023.2 host workaround: preserve synthesis temporary
# files when Windows Tcl path normalization makes final cleanup fail. It does
# not suppress synthesis errors or modify RTL or installed tool settings.

if {[llength $argv] > 0} {
    # Keep the supplied absolute Windows path: normalizing junctions can move
    # the spelling outside a sandbox's authorized workspace path.
    set project_dir [string map {\\ /} [lindex $argv 0]]
} else {
    set project_dir [file normalize [file join [file dirname [info script]] ..]]
}
puts "SYNTH_CHECK_PROJECT_DIR=$project_dir"
set output_dir [file join $project_dir build raw_transport_no_sram synth]
file mkdir $output_dir
cd $output_dir
puts "SYNTH_CHECK_OUTPUT_DIR=[pwd]"
set output_dir .

set status_file [file join $output_dir synthesis_status.txt]
set status_handle [open $status_file w]
puts $status_handle "RUNNING"
close $status_handle

if {[catch {
    set_param general.maxThreads 4
    set preserve_temp 0
    if {[llength $argv] > 1 && [lindex $argv 1] eq "--keep-temp"} {
        set_param synth.elaboration.rodinMoreOptions {rt::set_parameter parallelDebug true}
        set preserve_temp 1
        puts "SYNTH_CHECK_KEEP_TEMP=1 (Windows Tcl cleanup workaround)"
    }
    set selected_part ""
    # The installed Virtex-7 690T part requires an unavailable synthesis
    # license on this host. Use the installed Artix-7 200T alternative.
    foreach candidate {xc7a200tfbg484-2 xc7a200tsbg484-1} {
        if {[llength [get_parts -quiet $candidate]] != 0} {
            set selected_part $candidate
            break
        }
    }
    if {$selected_part eq ""} {
        error "No supported Artix-7 200T part is installed."
    }
    puts "SYNTH_CHECK_PART=$selected_part"

    # Do not use -sv: this flow deliberately checks pure Verilog sources.
    foreach rtl_file {isa_residue.v isa_pe.v isa_stream_checker.v integrity_sa_32x32.v} {
        set rtl_path [file join $project_dir rtl $rtl_file]
        if {![file isfile $rtl_path]} { error "Missing RTL source: $rtl_path" }
        read_verilog $rtl_path
    }

    synth_design -top integrity_sa_32x32 -part $selected_part -mode out_of_context
    create_clock -name verification_clock -period 10.000 [get_ports clk]

    # Record surviving shadow accumulator registers after optimization. This
    # checks logical structure only, not physical common-mode independence.
    set residue_handle [open [file join $output_dir residue_registers.rpt] w]
    puts $residue_handle "Post-synthesis residue accumulator register inventory"
    puts $residue_handle "This is not a physical separation or common-mode fault proof."
    foreach residue_name {s7_out s15_out} {
        set residue_cells [get_cells -quiet -hierarchical -filter "REF_NAME =~ FD* && NAME =~ *${residue_name}_reg*"]
        puts $residue_handle "${residue_name}_TOTAL_FF=[llength $residue_cells]"
        set per_parent [dict create]
        foreach residue_cell $residue_cells {
            set cell_name [get_property NAME $residue_cell]
            set parent_path [string range $cell_name 0 [expr {[string last / $cell_name] - 1}]]
            dict incr per_parent $parent_path
        }
        foreach parent_path [lsort [dict keys $per_parent]] {
            puts $residue_handle "$residue_name $parent_path [dict get $per_parent $parent_path]"
        }
    }
    close $residue_handle
    write_checkpoint -force [file join $output_dir integrity_sa_32x32_synth.dcp]
    report_utilization -file [file join $output_dir utilization.rpt]
    report_utilization -hierarchical -file [file join $output_dir utilization_hierarchical.rpt]
    check_timing -verbose -file [file join $output_dir check_timing.rpt]
    report_timing_summary -file [file join $output_dir timing_summary.rpt]
    report_drc -file [file join $output_dir drc.rpt]

    set latches [get_cells -quiet -hierarchical -filter {REF_NAME =~ LD*}]
    set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
    set checks_handle [open [file join $output_dir structural_checks.rpt] w]
    puts $checks_handle "TOP=integrity_sa_32x32"
    puts $checks_handle "PART=$selected_part"
    puts $checks_handle "RTL_LANGUAGE=Verilog (read_verilog without -sv)"
    puts $checks_handle "CLOCK_PERIOD_NS=10.000 (arbitrary verification constraint)"
    puts $checks_handle "PRESERVE_SYNTH_TEMP=$preserve_temp"
    puts $checks_handle "MAPPED_LATCH_COUNT=[llength $latches]"
    puts $checks_handle "BLACKBOX_COUNT=[llength $blackboxes]"
    foreach cell $latches { puts $checks_handle "LATCH=$cell" }
    foreach cell $blackboxes { puts $checks_handle "BLACKBOX=$cell" }
    puts $checks_handle "RESOURCE_SCOPE=FPGA synthesis only; not ASIC PPA or placed-and-routed timing"
    close $checks_handle

    if {[llength $latches] != 0} { error "Unexpected inferred latch cells were found." }
    if {[llength $blackboxes] != 0} { error "Unresolved black boxes were found." }
} error_message]} {
    set status_handle [open $status_file w]
    puts $status_handle "FAIL"
    puts $status_handle $error_message
    close $status_handle
    puts stderr "SYNTH_CHECK_FAIL: $error_message"
    exit 1
}

set status_handle [open $status_file w]
puts $status_handle "PASS"
puts $status_handle "PART=$selected_part"
puts $status_handle "Verilog synthesis completed with no mapped latches or unresolved black boxes."
puts $status_handle "See check_timing, timing_summary, and drc reports for timing and constraints."
puts $status_handle "The 10 ns verification clock is arbitrary; no ASIC PPA claim is made."
close $status_handle
puts "SYNTH_CHECK_PASS"
exit 0
