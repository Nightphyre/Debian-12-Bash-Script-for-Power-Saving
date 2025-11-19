#!/bin/bash

# Intel Alder Lake-U15 CPU Control & Power Monitor v3
# Purpose: Disable processors, measure efficiency, and track Active Processor IDs.
# Usage: sudo ./cpu_control_v3.sh [status|powersave|restore|monitor|benchmark]

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

# Get list of currently online logical CPUs (e.g., "0-3,8-11")
get_active_cpus() {
    if [ -f "$CPU_DIR/online" ]; then
        cat "$CPU_DIR/online"
    else
        echo "0-$((NUM_CPUS-1))" # Fallback if file missing
    fi
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

    local energy_diff=$((end_energy - start_energy))
    local time_diff_ns=$((end_time - start_time))
    
    if [ "$time_diff_ns" -eq 0 ]; then time_diff_ns=1; fi

    # Watts = (uJ * 1000) / ns
    local watts=$(echo "scale=2; ($energy_diff * 1000) / $time_diff_ns" | bc)
    echo "$watts"
}

# --- CONTROL FUNCTIONS ---

set_cpu_state() {
    local cpu_id=$1
    local state=$2
    
    # Protect CPU0 (System Critical)
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
    echo "--- Real-Time Power Monitor v3 ---"
    echo "Tracking Package Power vs. Active Processor IDs"
    echo "Ctrl+C to exit."
    echo ""
    
    # Print Table Header
    printf "%-10s | %-18s | %-10s\n" "Time" "Active Processor IDs" "Power (W)"
    echo "--------------------------------------------"
    
    while true; do
        # Capture active CPUs BEFORE measurement to ensure correlation
        active_ids=$(get_active_cpus)
        
        # Measure power (blocking for 1 sec)
        watts=$(measure_watts 1)
        timestamp=$(date +%H:%M:%S)
        
        # Check if active IDs changed during measurement
        current_active_ids=$(get_active_cpus)
        if [ "$active_ids" != "$current_active_ids" ]; then
            active_ids="$active_ids*" # Mark with asterisk if state changed
        fi

        printf "%-10s | %-18s | %s W\n" "$timestamp" "$active_ids" "$watts"
    done
}

benchmark_efficiency() {
    echo "--- Power Conservation Efficiency Benchmark ---"
    echo "This test compares wattage between current active cores and full capacity."
    echo ""
    
    # 1. Restore defaults
    restore_all > /dev/null
    # Small sleep to let voltage regulators settle
    sleep 1 
    
    echo "1. Measuring BASELINE..."
    active_base=$(get_active_cpus)
    echo "   Active IDs: [$active_base]"
    base_watts=$(measure_watts 4)
    echo "   Avg Power:  $base_watts W"
    echo ""

    # 2. Apply powersave
    apply_powersave > /dev/null
    sleep 1
    
    echo "2. Measuring POWERSAVE..."
    active_save=$(get_active_cpus)
    echo "   Active IDs: [$active_save]"
    save_watts=$(measure_watts 4)
    echo "   Avg Power:  $save_watts W"
    
    # 3. Results
    echo "-----------------------------------------------"
    diff=$(echo "$base_watts - $save_watts" | bc)
    percent=$(echo "scale=2; ($diff / $base_watts) * 100" | bc)
    
    echo "RESULTS:"
    echo "Transition: [$active_base] -> [$active_save]"
    echo "Power Saved:      $diff W"
    echo "Efficiency Gain:  $percent %"
    echo "-----------------------------------------------"
}

# --- MAIN ---

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)."
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo "Error: 'bc' is required. Install with: sudo apt install bc"
    exit 1
fi

if [ ! -f "$RAPL_DIR/energy_uj" ]; then
    echo "Warning: Intel RAPL interface not found."
fi

case "$1" in
    status)
        get_topology
        echo "Active Processor IDs: $(get_active_cpus)"
        echo "Current Power Draw:   $(measure_watts 1) W"
        ;;
    powersave)
        apply_powersave
        echo "Powersave applied. Active IDs: $(get_active_cpus)"
        ;;
    restore)
        restore_all
        echo "Restored. Active IDs: $(get_active_cpus)"
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
