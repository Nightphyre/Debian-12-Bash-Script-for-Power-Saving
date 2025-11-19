#!/bin/bash

# Intel Alder Lake-U15 CPU Control Script
# Purpose: Disable specific logical processors to reduce power consumption via C-state enforcement and leakage reduction.
# Usage: sudo ./cpu_control.sh [status|powersave|restore]

set -e

CPU_DIR="/sys/devices/system/cpu"
NUM_CPUS=$(nproc --all)

# Function to get CPU topology
get_topology() {
    echo "--- CPU Topology (Alder Lake Hybrid) ---"
    lscpu -e=CPU,CORE,NODE,SOCKET,MAXMHZ,MINMHZ | head -n 20
    echo "----------------------------------------"
}

# Function to set CPU online status
# $1: CPU ID (int)
# $2: State (0 for offline, 1 for online)
set_cpu_state() {
    local cpu_id=$1
    local state=$2
    
    # CPU0 is usually critical and cannot be offlined in many kernels
    if [ "$cpu_id" -eq 0 ]; then
        echo "Skipping CPU 0 (System Critical)"
        return
    fi

    if [ -f "$CPU_DIR/cpu$cpu_id/online" ]; then
        echo $state > "$CPU_DIR/cpu$cpu_id/online"
        status_text="Online"
        [ "$state" -eq 0 ] && status_text="Offline"
        echo "CPU $cpu_id -> $status_text"
    else
        echo "Error: Unable to control CPU $cpu_id"
    fi
}

# Function to apply aggressive power saving
# Strategy: 
# 1. Disable Hyper-Threading on P-Cores (reduce logic switching).
# 2. Disable half of the E-Cores (reduce leakage).
apply_powersave() {
    echo "Applying U15 Power Saving Profile..."
    
    # DETECT P-CORES vs E-CORES
    # On Alder Lake, P-cores usually come first. 
    # Setup for typical 2P+8E (12 threads):
    # P-Cores: 0,1 (Core 0) and 2,3 (Core 1)
    # E-Cores: 4 through 11
    
    # 1. Disable HT Siblings on P-Cores (Logical CPUs 1 and 3)
    # This forces single-thread per P-core, reducing contention and power.
    set_cpu_state 1 0
    set_cpu_state 3 0

    # 2. Disable the second P-Core entirely? (Optional - uncomment to go extreme)
    # set_cpu_state 2 0 
    
    # 3. Disable half the E-cores (e.g., 8, 9, 10, 11)
    # This leaves 4 E-cores active for background tasks.
    for i in {8..11}; do
        set_cpu_state $i 0
    done
    
    echo "Power save profile applied."
}

# Function to restore all cores
restore_all() {
    echo "Restoring all processors..."
    for ((i=1; i<NUM_CPUS; i++)); do
        set_cpu_state $i 1
    done
    echo "All processors online."
}

# Main Logic
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)."
    exit 1
fi

case "$1" in
    status)
        get_topology
        grep "processor\|physical id\|core id" /proc/cpuinfo | awk 'RS="\n\n" {print $0"\n"}' | grep "processor" | wc -l | xargs echo "Online Logical CPUs:"
        ;;
    powersave)
        apply_powersave
        ;;
    restore)
        restore_all
        ;;
    *)
        echo "Usage: sudo $0 {status|powersave|restore}"
        echo "  status    : Show current topology and active cores."
        echo "  powersave : Disable P-core HT and 50% of E-cores."
        echo "  restore   : Bring all cores back online."
        exit 1
        ;;
esac
