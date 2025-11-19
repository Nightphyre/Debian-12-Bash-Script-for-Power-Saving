#!/bin/bash

# Intel Alder Lake-U15 CPU Control & Power Monitor
# Purpose: Disable processors to save power AND measure real-time efficiency in Watts.
# Usage: sudo ./cpu_control_v2.sh [status|powersave|restore|monitor|benchmark]

set -e

CPU_DIR="/sys/devices/system/cpu"
RAPL_DIR="/sys/class/powercap/intel-rapl/intel-rapl:0"
NUM_CPUS=$(nproc --all)

# --- UTILITY FUNCTIONS ---

get_topology() {
    echo "--- CPU Topology (Alder Lake Hybrid) ---"
    lscpu -e=CPU,CORE,NODE,SOCKET,MAXMHZ,MINMHZ | head -n 20
    echo "----------------------------------------"
}

# Read energy in microjoules
read_energy_uj() {
    if [ -f "$RAPL_DIR/energy_uj" ]; then
        cat "$RAPL_DIR/energy_uj"
    else
        echo "0"
    fi
}

# Calculate Watts over a duration
measure_watts() {
    local duration=$1
    local start_energy=$(read_energy_uj)
    local start_time=$(date +%s%N)
    
    sleep $duration
    
    local end_energy=$(read_energy_uj)
    local end_time=$(date +%s%N)

    # Math: (Delta_Energy_uJ / 1,000,000) / Duration_Seconds
    # Using bc for floating point precision
    local energy_diff=$((end_energy - start_energy))
    local time_diff_ns=$((end_time - start_time))
    
    # Avoid divide by zero
    if [ "$time_diff_ns" -eq 0 ]; then time_diff_ns=1; fi

    # Calculate Watts: (uJ / 1000000) / (ns / 1000000000)
    # Simplified: (uJ * 1000) / ns
    local watts=$(echo "scale=2; ($energy_diff * 1000) / $time_diff_ns" | bc)
    echo "$watts"
}

# --- CONTROL FUNCTIONS ---

set_cpu_state() {
    local cpu_id=$1
    local state=$2
    
    # Protect CPU0
    if [ "$cpu_id" -eq 0 ]; then return; fi

    if [ -f "$CPU_DIR/cpu$cpu_id/online" ]; then
        echo $state > "$CPU_DIR/cpu$cpu_id/online"
    fi
}

apply_powersave() {
    # Disable P-Core Hyper-threading (Siblings 1, 3)
    set_cpu_state 1 0
    set_cpu_state 3 0
    
    # Disable 50% of E-Cores (8, 9, 10, 11)
    for i in {8..11}; do set_cpu_state $i 0; done
}

restore_all() {
    for ((i=1; i<NUM_CPUS; i++)); do set_cpu_state $i 1; done
}

# --- MONITORING MODES ---

monitor_loop() {
    echo "--- Real-Time Power Monitor (Ctrl+C to exit) ---"
    echo "Measuring Package Power (CPU + Integrated Graphics)..."
    printf "%-10s | %-10s\n" "Time" "Power (W)"
    echo "-----------------------"
    
    while true; do
        watts=$(measure_watts 1)
        timestamp=$(date +%H:%M:%S)
        printf "%-10s | %s W\n" "$timestamp" "$watts"
    done
}

benchmark_efficiency() {
    echo "--- Power Conservation Efficiency Benchmark ---"
    echo "This test takes approx 10 seconds."
    echo ""
    
    # 1. Restore defaults and measure
    restore_all > /dev/null
    echo "1. Measuring BASELINE power (All Cores Online, Idle)..."
    base_watts=$(measure_watts 4)
    echo "   Baseline: $base_watts W"
    
    # 2. Apply powersave and measure
    apply_powersave > /dev/null
    echo "2. Applying POWERSAVE profile and measuring..."
    save_watts=$(measure_watts 4)
    echo "   Powersave: $save_watts W"
    
    # 3. Calculate Efficiency
    echo "-----------------------------------------------"
    diff=$(echo "$base_watts - $save_watts" | bc)
    percent=$(echo "scale=2; ($diff / $base_watts) * 100" | bc)
    
    echo "RESULTS:"
    echo "Power Saved:      $diff W"
    echo "Efficiency Gain:  $percent %"
    echo "-----------------------------------------------"
    echo "Note: Measurements reflect IDLE savings. Load savings may vary."
}

# --- MAIN ---

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)."
    exit 1
fi

# Check for BC (Calculator)
if ! command -v bc &> /dev/null; then
    echo "Error: 'bc' is required for calculations. Install with: sudo apt install bc"
    exit 1
fi

# Check for RAPL support
if [ ! -f "$RAPL_DIR/energy_uj" ]; then
    echo "Warning: Intel RAPL interface not found. Power monitoring will not work."
    echo "Ensure 'intel_rapl_common' and 'intel_rapl_msr' kernel modules are loaded."
    # We can still allow core control, but disable monitoring functions
fi

case "$1" in
    status)
        get_topology
        echo "Current Power Draw: $(measure_watts 1) W"
        ;;
    powersave)
        apply_powersave
        echo "Powersave profile applied."
        ;;
    restore)
        restore_all
        echo "All processors restored."
        ;;
    monitor)
        monitor_loop
        ;;
    benchmark)
        benchmark_efficiency
        ;;
    *)
        echo "Usage: sudo $0 {status|powersave|restore|monitor|benchmark}"
        exit 1
        ;;
esac
