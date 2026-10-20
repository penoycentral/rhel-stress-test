#!/usr/bin/env bash
#
# ==============================================================================
# Enterprise Stress Testing Suite for Red Hat Enterprise Linux (RHEL 7/8/9)
#
# Supported Components: CPU, Memory, Disk I/O, or All concurrently
# Engines:              stress-ng (EPEL) with native zero-dependency fallbacks
# License:              MIT License
# ==============================================================================
#

set -o pipefail

# ANSI color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Default configuration values
DEFAULT_DURATION="60s"
DEFAULT_MEM_PCT=75
DEFAULT_DISK_PATH="/var/tmp"
DEFAULT_DISK_SIZE="4G"
# Detect CPU cores safely across all Linux architectures and virtual machines
DEFAULT_CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

# Runtime variables
TARGET=""
DURATION="$DEFAULT_DURATION"
CPU_CORES="$DEFAULT_CPU_CORES"
MEM_PCT="$DEFAULT_MEM_PCT"
DISK_PATH="$DEFAULT_DISK_PATH"
DISK_SIZE="$DEFAULT_DISK_SIZE"
NON_INTERACTIVE=false
CLEANUP_FILES=()
BACKGROUND_PIDS=()
CLEANUP_TRIGGERED=false

# -----------------------------------------------------------------------------
# Logging and Output Helpers
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_section() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"
}

# -----------------------------------------------------------------------------
# Cleanup and Signal Handling
# -----------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    # Prevent duplicate cleanup runs
    [[ "$CLEANUP_TRIGGERED" == true ]] && return
    CLEANUP_TRIGGERED=true

    local has_work_to_clean=false
    if [[ ${#BACKGROUND_PIDS[@]} -gt 0 || ${#CLEANUP_FILES[@]} -gt 0 ]]; then
        has_work_to_clean=true
    fi

    if [[ "$has_work_to_clean" == true || $exit_code -ne 0 ]]; then
        echo -e "\n${YELLOW}[!] Cleaning up resources and stopping background processes...${NC}"

        # Kill any registered background worker PIDs
        for pid in "${BACKGROUND_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                sleep 0.1
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done

        # Remove temporary test files
        for file in "${CLEANUP_FILES[@]}"; do
            if [[ -e "$file" ]]; then
                rm -rf "$file" 2>/dev/null || true
            fi
        done

        # Check for lingering stress/stress-ng processes spawned by this session
        pkill -P $$ 2>/dev/null || true

        if [[ $exit_code -eq 0 ]]; then
            log_success "Cleanup complete."
        else
            log_warn "Exited with code: $exit_code. Cleanup complete."
        fi
    fi
    exit "$exit_code"
}

trap cleanup SIGINT SIGTERM EXIT

# -----------------------------------------------------------------------------
# System & Pre-flight Checks
# -----------------------------------------------------------------------------
check_rhel() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        log_info "Detected OS: ${PRETTY_NAME:-$NAME $VERSION_ID}"
    elif [[ -f /etc/redhat-release ]]; then
        log_info "Detected OS: $(cat /etc/redhat-release)"
    else
        log_warn "This system does not appear to be Red Hat Enterprise Linux. Continuing anyway..."
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Script is NOT running as root (current UID: $EUID)."
        log_warn "Some kernel metrics, high-load memory allocations, or package installs may be restricted."
        echo -n "Do you want to continue without root? [y/N]: "
        if [[ "$NON_INTERACTIVE" == true ]]; then
            echo "y (non-interactive mode)"
        else
            read -r resp
            if [[ ! "$resp" =~ ^[yY]([eE][sS])?$ ]]; then
                log_error "Aborted by user. Please run with sudo or as root."
                exit 1
            fi
        fi
    fi
}

# Convert duration string like "60", "60s", "5m", "1h" to seconds
parse_duration_to_seconds() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([smhd]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            s|"") echo "$num" ;;
            m) echo $((num * 60)) ;;
            h) echo $((num * 3600)) ;;
            d) echo $((num * 86400)) ;;
        esac
    else
        log_error "Invalid duration format: '$input'. Examples: 30s, 5m, 1h."
        exit 1
    fi
}

# Check if stress-ng is available, optionally offer/attempt install on RHEL
ensure_tooling() {
    if command -v stress-ng &>/dev/null; then
        return 0
    fi

    log_warn "'stress-ng' is not installed."
    log_info "'stress-ng' is the recommended enterprise stress testing tool."

    local pkg_manager=""
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
    fi

    if [[ -n "$pkg_manager" && $EUID -eq 0 ]]; then
        echo -n "Would you like to install stress-ng (via EPEL if needed)? [Y/n]: "
        local reply="y"
        if [[ "$NON_INTERACTIVE" == true ]]; then
            reply="y"
            echo "y (auto-accepted)"
        else
            read -r reply
            reply="${reply:-y}"
        fi

        if [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]; then
            log_info "Attempting to install epel-release and stress-ng..."
            $pkg_manager install -y epel-release || true
            if $pkg_manager install -y stress-ng; then
                log_success "stress-ng installed successfully!"
                return 0
            else
                log_warn "Failed to install stress-ng automatically. Using native fallback routines."
            fi
        else
            log_info "Using built-in native Linux stress routines."
        fi
    else
        log_info "Proceeding with native built-in Linux stress routines (no third-party dependencies required)."
    fi

    return 1
}

# -----------------------------------------------------------------------------
# System Information Display
# -----------------------------------------------------------------------------
display_system_info() {
    log_section "System Resource Overview"
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)
    [[ -z "$cpu_model" ]] && cpu_model="Generic CPU / $(uname -m)"
    echo -e "${BOLD}CPU Model:${NC}       $cpu_model"
    echo -e "${BOLD}Logical Cores:${NC}   $DEFAULT_CPU_CORES"
    
    local mem_total_kb mem_avail_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ $mem_total_kb -gt 0 ]] 2>/dev/null; then
        echo -e "${BOLD}Total RAM:${NC}       $((mem_total_kb / 1024)) MB ($((mem_total_kb / 1024 / 1024)) GB)"
        echo -e "${BOLD}Available RAM:${NC}   $((mem_avail_kb / 1024)) MB ($((mem_avail_kb / 1024 / 1024)) GB)"
    else
        local alt_bytes
        alt_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        if [[ $alt_bytes -gt 0 ]] 2>/dev/null; then
            echo -e "${BOLD}Total RAM:${NC}       $((alt_bytes / 1024 / 1024)) MB ($((alt_bytes / 1024 / 1024 / 1024)) GB)"
        else
            echo -e "${BOLD}Total RAM:${NC}       N/A"
        fi
    fi

    local disk_info
    disk_info=$(df -h -P "$DISK_PATH" 2>/dev/null | tail -1)
    echo -e "${BOLD}Target Disk Path:${NC}$DISK_PATH"
    echo -e "${BOLD}Disk Capacity:${NC}   $(echo "$disk_info" | awk '{print "Size: " $2 ", Avail: " $4 ", Used: " $5 " (Mount: " $6 ")"}')"
    echo -e "${BOLD}Load Average:${NC}    $(uptime 2>/dev/null | awk -F'load averages?:' '{print $2}' | xargs)"
    echo ""
}

# -----------------------------------------------------------------------------
# Live Stress Monitor (Countdown + Stats)
# -----------------------------------------------------------------------------
monitor_progress() {
    local duration_sec="$1"
    local desc="$2"
    local elapsed=0

    echo -e "${CYAN}Running $desc for ${duration_sec}s... (Press Ctrl+C to abort safely)${NC}"

    while [[ $elapsed -lt $duration_sec ]]; do
        local remaining=$((duration_sec - elapsed))
        local load_avg
        load_avg=$(uptime 2>/dev/null | sed -E 's/.*load averages?:[ ]*//' | xargs)
        local free_mem
        free_mem=$(awk '/MemAvailable/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || free -m 2>/dev/null | awk '/Mem:/ {print $4 "MB"}' || echo 'N/A')
        
        printf "\r${YELLOW}[PROGRESS]${NC} Remaining: %3ds | Load Avg: %s | Free Mem: %s  " "$remaining" "$load_avg" "$free_mem"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    printf "\r${GREEN}[PROGRESS]${NC} Stress test cycle completed. Finalizing...                          \n"
}

# -----------------------------------------------------------------------------
# Stress Routines: CPU
# -----------------------------------------------------------------------------
stress_cpu() {
    local duration_sec="$1"
    local cores="$2"
    local show_monitor="${3:-true}"

    if [[ "$show_monitor" == true ]]; then
        log_section "Initiating CPU Stress Test"
        log_info "Target Cores: $cores / $DEFAULT_CPU_CORES"
        log_info "Duration:     ${duration_sec}s"
    fi

    if command -v stress-ng &>/dev/null; then
        [[ "$show_monitor" == true ]] && log_info "Engine: stress-ng (matrix & complex arithmetic stressors)"
        stress-ng --cpu "$cores" \
                  --cpu-method all \
                  --timeout "${duration_sec}s" \
                  --metrics-brief &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        [[ "$show_monitor" == true ]] && monitor_progress "$duration_sec" "CPU stress via stress-ng"
        wait "$pid" 2>/dev/null || true
    else
        [[ "$show_monitor" == true ]] && log_info "Engine: Native fallback (parallel computation burner loops)"
        local worker_pids=()
        for ((i = 0; i < cores; i++)); do
            (
                while true; do
                    : $(( 123456789 * 987654321 ))
                done
            ) &
            local w_pid=$!
            worker_pids+=("$w_pid")
            BACKGROUND_PIDS+=("$w_pid")
        done
        if [[ "$show_monitor" == true ]]; then
            monitor_progress "$duration_sec" "CPU stress via native workers"
        else
            sleep "$duration_sec"
        fi
        # Stop workers after duration
        for pid in "${worker_pids[@]}"; do
            kill -TERM "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
    fi
    [[ "$show_monitor" == true ]] && log_success "CPU stress test finished."
}

# -----------------------------------------------------------------------------
# Stress Routines: Memory
# -----------------------------------------------------------------------------
stress_memory() {
    local duration_sec="$1"
    local pct="$2"
    local show_monitor="${3:-true}"

    local total_kb avail_kb target_kb target_mb target_bytes
    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    
    if [[ $avail_kb -eq 0 ]]; then
        target_mb=1024
        target_bytes=$(( target_mb * 1024 * 1024 ))
        [[ "$show_monitor" == true ]] && log_warn "Could not read available memory from /proc/meminfo. Defaulting to 1024 MB."
    else
        target_kb=$(( (avail_kb * pct) / 100 ))
        target_mb=$(( target_kb / 1024 ))
        target_bytes=$(( target_kb * 1024 ))
    fi

    if [[ "$show_monitor" == true ]]; then
        log_section "Initiating Memory Stress Test"
        log_info "Total RAM:     $((total_kb / 1024)) MB"
        log_info "Available RAM: $((avail_kb / 1024)) MB"
        log_info "Target Stress: $target_mb MB ($pct% of available RAM)"
        log_info "Duration:      ${duration_sec}s"
    fi

    if command -v stress-ng &>/dev/null; then
        [[ "$show_monitor" == true ]] && log_info "Engine: stress-ng (VM stressor, write & read verify)"
        stress-ng --vm 2 \
                  --vm-bytes "${target_mb}M" \
                  --vm-keep \
                  --timeout "${duration_sec}s" \
                  --metrics-brief &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        [[ "$show_monitor" == true ]] && monitor_progress "$duration_sec" "Memory stress via stress-ng"
        wait "$pid" 2>/dev/null || true
    elif command -v python3 &>/dev/null; then
        [[ "$show_monitor" == true ]] && log_info "Engine: Native Python3 memory allocator (touching 4KB pages)"
        local py_quiet="False"
        [[ "$show_monitor" == false ]] && py_quiet="True"
        python3 -c "
import time, sys
bytes_to_alloc = $target_bytes
quiet = $py_quiet
if not quiet:
    print(f'Committing {bytes_to_alloc / (1024*1024):.1f} MB in physical RAM...')
try:
    data = bytearray(bytes_to_alloc)
    for i in range(0, bytes_to_alloc, 4096):
        data[i] = 170
    if not quiet:
        print('Memory committed. Holding allocation...')
    time.sleep($duration_sec)
except MemoryError:
    if not quiet:
        print('Safety limit reached: OS refused further allocation.', file=sys.stderr)
" &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        if [[ "$show_monitor" == true ]]; then
            monitor_progress "$duration_sec" "Memory stress via Python3 allocator"
        fi
        wait "$pid" 2>/dev/null || true
    else
        [[ "$show_monitor" == true ]] && log_info "Engine: Native tmpfs/ramfs allocation fallback"
        local tmp_ram_dir="/dev/shm/rhel_mem_stress_$$"
        mkdir -p "$tmp_ram_dir"
        CLEANUP_FILES+=("$tmp_ram_dir")

        dd if=/dev/zero of="$tmp_ram_dir/block.dat" bs=1M count=$target_mb status=none 2>/dev/null &
        local dd_pid=$!
        BACKGROUND_PIDS+=("$dd_pid")
        wait "$dd_pid" 2>/dev/null || true

        if [[ "$show_monitor" == true ]]; then
            monitor_progress "$duration_sec" "Memory hold via tmpfs"
        else
            sleep "$duration_sec"
        fi
        rm -rf "$tmp_ram_dir"
    fi
    [[ "$show_monitor" == true ]] && log_success "Memory stress test finished."
}

# -----------------------------------------------------------------------------
# Stress Routines: Disk
# -----------------------------------------------------------------------------
stress_disk() {
    local duration_sec="$1"
    local path="$2"
    local size_str="$3"
    local show_monitor="${4:-true}"

    if [[ ! -d "$path" ]]; then
        mkdir -p "$path" || {
            log_error "Cannot create directory '$path'."
            exit 1
        }
    fi

    local avail_kb
    avail_kb=$(df -k -P "$path" 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ "$show_monitor" == true ]]; then
        log_section "Initiating Disk I/O Stress Test"
        log_info "Target Directory: $path"
        log_info "Available Space:  $((avail_kb / 1024)) MB"
    fi

    if command -v stress-ng &>/dev/null; then
        [[ "$show_monitor" == true ]] && log_info "Engine: stress-ng (hdd sequential + random I/O sync stressor)"
        stress-ng --hdd 2 \
                  --hdd-bytes "$size_str" \
                  --temp-path "$path" \
                  --timeout "${duration_sec}s" \
                  --metrics-brief &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        [[ "$show_monitor" == true ]] && monitor_progress "$duration_sec" "Disk I/O stress via stress-ng"
        wait "$pid" 2>/dev/null || true
    else
        [[ "$show_monitor" == true ]] && log_info "Engine: Native direct I/O writer (dd with oflag=direct,sync)"
        local test_file="$path/rhel_stress_disk_test_$$.tmp"
        CLEANUP_FILES+=("$test_file")

        local mb_count=1024
        if [[ "$size_str" =~ ^([0-9]+)[gG]$ ]]; then
            mb_count=$(( ${BASH_REMATCH[1]} * 1024 ))
        elif [[ "$size_str" =~ ^([0-9]+)[mM]$ ]]; then
            mb_count="${BASH_REMATCH[1]}"
        fi

        local safe_max_mb=$(( (avail_kb * 70) / (100 * 1024) ))
        if [[ $mb_count -gt $safe_max_mb ]]; then
            [[ "$show_monitor" == true ]] && log_warn "Requested size ($mb_count MB) exceeds safety threshold. Lowering to $safe_max_mb MB."
            mb_count=$safe_max_mb
        fi

        local oflag_opt="oflag=direct,sync"
        if ! dd if=/dev/zero of="$test_file" bs=1M count=1 oflag=direct,sync status=none 2>/dev/null; then
            oflag_opt="conv=fdatasync"
            [[ "$show_monitor" == true ]] && log_info "Direct I/O not supported by target filesystem. Using conv=fdatasync."
        fi
        rm -f "$test_file" 2>/dev/null || true

        [[ "$show_monitor" == true ]] && log_info "Writing and reading $mb_count MB blocks repeatedly for ${duration_sec}s..."
        (
            end_time=$((SECONDS + duration_sec))
            while [[ $SECONDS -lt $end_time ]]; do
                dd if=/dev/urandom of="$test_file" bs=1M count="$mb_count" $oflag_opt status=none 2>/dev/null || true
                dd if="$test_file" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null || \
                dd if="$test_file" of=/dev/null bs=1M status=none 2>/dev/null || true
                rm -f "$test_file" 2>/dev/null || true
            done
        ) &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        if [[ "$show_monitor" == true ]]; then
            monitor_progress "$duration_sec" "Disk write/read I/O cycles"
        fi
        wait "$pid" 2>/dev/null || true
        rm -f "$test_file" 2>/dev/null || true
    fi
    [[ "$show_monitor" == true ]] && log_success "Disk stress test finished."
}

# -----------------------------------------------------------------------------
# Stress Routines: All (Concurrent CPU + Memory + Disk)
# -----------------------------------------------------------------------------
stress_all() {
    local duration_sec="$1"
    local cores="$2"
    local mem_pct="$3"
    local disk_p="$4"
    local disk_s="$5"

    log_section "Initiating ALL-COMPONENT Stress Test (CPU + Memory + Disk)"
    log_info "Duration:     ${duration_sec}s"
    log_info "CPU Cores:    $cores"
    log_info "Memory Load:  $mem_pct% of available RAM"
    log_info "Disk Path:    $disk_p (Size: $disk_s)"

    if command -v stress-ng &>/dev/null; then
        local avail_kb target_mb
        avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/ {print $2}' /proc/meminfo)
        target_mb=$(( (avail_kb * mem_pct) / (100 * 1024) ))

        log_info "Engine: stress-ng unified multi-stressor matrix"
        stress-ng --cpu "$cores" \
                  --cpu-method all \
                  --vm 2 \
                  --vm-bytes "${target_mb}M" \
                  --vm-keep \
                  --hdd 2 \
                  --hdd-bytes "$disk_s" \
                  --temp-path "$disk_p" \
                  --timeout "${duration_sec}s" \
                  --metrics-brief &
        local pid=$!
        BACKGROUND_PIDS+=("$pid")
        monitor_progress "$duration_sec" "Full System Stress (CPU + RAM + Disk)"
        wait "$pid" 2>/dev/null || true
    else
        log_info "Engine: Coordinated Native Background Stress Workers"
        # Run CPU stress in subshell quietly
        ( stress_cpu "$duration_sec" "$cores" false ) &
        local cpu_pid=$!
        BACKGROUND_PIDS+=("$cpu_pid")

        # Run Memory stress in subshell quietly
        ( stress_memory "$duration_sec" "$mem_pct" false ) &
        local mem_pid=$!
        BACKGROUND_PIDS+=("$mem_pid")

        # Run Disk stress in subshell quietly
        ( stress_disk "$duration_sec" "$disk_p" "$disk_s" false ) &
        local disk_pid=$!
        BACKGROUND_PIDS+=("$disk_pid")

        monitor_progress "$duration_sec" "Concurrent Native Workers (CPU, Memory, Disk)"

        wait "$cpu_pid" "$mem_pid" "$disk_pid" 2>/dev/null || true
    fi
    log_success "All stress tests completed successfully."
}

# -----------------------------------------------------------------------------
# Usage & Help
# -----------------------------------------------------------------------------
show_help() {
    cat << EOF
Enterprise Stress Testing Suite for Red Hat Enterprise Linux
Usage: $(basename "$0") [OPTIONS]

Options:
  -t, --target TYPE       Stress test target: 'cpu', 'memory' (or 'mem'), 'disk', 'all'
  -d, --duration DURATION Duration of the test (e.g. 30s, 2m, 1h; default: $DEFAULT_DURATION)
  -c, --cpus NUM          Number of CPU worker cores (default: all cores = $DEFAULT_CPU_CORES)
  -m, --mem-percent PCT   Percentage of available RAM to stress (default: $DEFAULT_MEM_PCT%)
  -p, --disk-path PATH    Target filesystem path for disk stress (default: $DEFAULT_DISK_PATH)
  -s, --disk-size SIZE    Target disk test block size (e.g. 1G, 4G; default: $DEFAULT_DISK_SIZE)
  -y, --yes               Non-interactive mode (auto-confirm prompts)
  -i, --info              Display system specifications and exit
  -h, --help              Display this help message and exit

Interactive Mode:
  If invoked without '--target', the script launches a friendly interactive menu.

Examples:
  # Stress test all components for 60 seconds
  sudo $(basename "$0") -t all -d 60s

  # Stress CPU across 4 cores for 5 minutes
  sudo $(basename "$0") -t cpu -c 4 -d 5m

  # Stress memory using 80% of available RAM for 2 minutes
  sudo $(basename "$0") -t mem -m 80 -d 2m

  # Stress test disk I/O on /opt partition
  sudo $(basename "$0") -t disk -p /opt -s 5G -d 120s

EOF
}

# -----------------------------------------------------------------------------
# Interactive Menu
# -----------------------------------------------------------------------------
interactive_menu() {
    while true; do
        clear
        echo -e "${BOLD}${BLUE}===================================================================${NC}"
        echo -e "${BOLD}${CYAN}      Red Hat Enterprise Linux Server Stress Testing Utility       ${NC}"
        echo -e "${BOLD}${BLUE}===================================================================${NC}"
        display_system_info

        echo -e "${BOLD}Select a stress test option:${NC}"
        echo -e "  ${GREEN}1)${NC} Stress CPU"
        echo -e "  ${GREEN}2)${NC} Stress Memory (RAM)"
        echo -e "  ${GREEN}3)${NC} Stress Disk I/O"
        echo -e "  ${GREEN}4)${NC} Stress ALL (CPU + Memory + Disk concurrently)"
        echo -e "  ${GREEN}5)${NC} Configure Parameters (Duration, Cores, Paths)"
        echo -e "  ${GREEN}6)${NC} Exit"
        echo ""
        echo -e "Current Configuration: Duration=${YELLOW}${DURATION}${NC}, Cores=${YELLOW}${CPU_CORES}${NC}, MemPct=${YELLOW}${MEM_PCT}%${NC}, DiskPath=${YELLOW}${DISK_PATH}${NC}"
        echo ""
        read -r -p "Enter selection [1-6]: " choice

        case "$choice" in
            1)
                local dur_sec
                dur_sec=$(parse_duration_to_seconds "$DURATION")
                stress_cpu "$dur_sec" "$CPU_CORES"
                read -r -p "Press Enter to return to menu..."
                ;;
            2)
                local dur_sec
                dur_sec=$(parse_duration_to_seconds "$DURATION")
                stress_memory "$dur_sec" "$MEM_PCT"
                read -r -p "Press Enter to return to menu..."
                ;;
            3)
                local dur_sec
                dur_sec=$(parse_duration_to_seconds "$DURATION")
                stress_disk "$dur_sec" "$DISK_PATH" "$DISK_SIZE"
                read -r -p "Press Enter to return to menu..."
                ;;
            4)
                local dur_sec
                dur_sec=$(parse_duration_to_seconds "$DURATION")
                stress_all "$dur_sec" "$CPU_CORES" "$MEM_PCT" "$DISK_PATH" "$DISK_SIZE"
                read -r -p "Press Enter to return to menu..."
                ;;
            5)
                echo ""
                read -r -p "Enter test duration (e.g. 30s, 5m, 1h) [current: $DURATION]: " input_dur
                [[ -n "$input_dur" ]] && DURATION="$input_dur"

                read -r -p "Enter number of CPU cores to stress [current: $CPU_CORES]: " input_cores
                [[ -n "$input_cores" ]] && CPU_CORES="$input_cores"

                read -r -p "Enter Memory percentage (1-90%) [current: $MEM_PCT]: " input_mem
                [[ -n "$input_mem" ]] && MEM_PCT="$input_mem"

                read -r -p "Enter Target Disk path [current: $DISK_PATH]: " input_path
                [[ -n "$input_path" ]] && DISK_PATH="$input_path"

                read -r -p "Enter Disk file size (e.g. 2G, 5G) [current: $DISK_SIZE]: " input_size
                [[ -n "$input_size" ]] && DISK_SIZE="$input_size"
                ;;
            6|q|Q)
                echo -e "\nExiting. Good luck with your RHEL server testing!\n"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main Entrypoint & CLI Parsing
# -----------------------------------------------------------------------------
main() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target)
                TARGET="$2"
                shift 2
                ;;
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -c|--cpus)
                CPU_CORES="$2"
                shift 2
                ;;
            -m|--mem-percent)
                MEM_PCT="$2"
                shift 2
                ;;
            -p|--disk-path)
                DISK_PATH="$2"
                shift 2
                ;;
            -s|--disk-size)
                DISK_SIZE="$2"
                shift 2
                ;;
            -y|--yes)
                NON_INTERACTIVE=true
                shift
                ;;
            -i|--info)
                check_rhel
                display_system_info
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    check_rhel
    check_root
    ensure_tooling || true

    # If no target specified, launch interactive menu
    if [[ -z "$TARGET" ]]; then
        interactive_menu
        exit 0
    fi

    # CLI Execution Mode
    local duration_sec
    duration_sec=$(parse_duration_to_seconds "$DURATION")

    display_system_info

    local target_clean
    target_clean=$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')

    case "$target_clean" in
        cpu)
            stress_cpu "$duration_sec" "$CPU_CORES"
            ;;
        mem|memory)
            stress_memory "$duration_sec" "$MEM_PCT"
            ;;
        disk|io|hdd)
            stress_disk "$duration_sec" "$DISK_PATH" "$DISK_SIZE"
            ;;
        all)
            stress_all "$duration_sec" "$CPU_CORES" "$MEM_PCT" "$DISK_PATH" "$DISK_SIZE"
            ;;
        *)
            log_error "Invalid target '$TARGET'. Must be one of: cpu, memory, disk, all."
            exit 1
            ;;
    esac
}

main "$@"
