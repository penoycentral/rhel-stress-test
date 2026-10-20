# Enterprise Stress Testing Suite for Red Hat Enterprise Linux (RHEL)

[![Linux](https://img.shields.io/badge/Platform-RHEL%207%20%7C%208%20%7C%209-red?logo=redhat)](https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux)
[![Bash](https://img.shields.io/badge/Language-Bash-green?logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A robust, enterprise-grade Bash script designed to stress test **Red Hat Enterprise Linux (RHEL 7, 8, 9)**, as well as downstream distributions (CentOS Stream, Rocky Linux, AlmaLinux, Oracle Linux, and Fedora).

The script provides complete flexibility to stress test individual subsystems (**CPU**, **Memory**, **Disk I/O**) or run all of them **concurrently**, via an interactive CLI menu or command-line flags.

---

## Table of Contents

- [Key Features](#key-features)
- [Requirements](#requirements)
- [File Overview](#file-overview)
- [Quick Start](#quick-start)
- [Command-Line Options](#command-line-options)
- [Tooling Architecture](#tooling-architecture)
- [Safety & Reliability](#safety--reliability)
- [License](#license)

---

## Key Features

- **Component Selection**: Test **CPU**, **Memory (RAM)**, **Disk I/O**, or **All** concurrently.
- **Dual Engine Architecture**:
  - **Enterprise Engine (`stress-ng`)**: Automatically detects or offers to install `stress-ng` via EPEL for advanced kernel stress testing.
  - **Zero-Dependency Native Fallback**: If third-party packages cannot be installed in locked-down production environments, it automatically falls back to native Linux kernel stressors (direct I/O writes, page-committed RAM allocations, arithmetic core burners).
- **Interactive & Automation Ready**:
  - Interactive menu when run without parameters.
  - Fully scriptable CLI arguments with non-interactive flag (`-y, --yes`) for CI/CD or automated burn-in testing.
- **Enterprise Safety & Signal Handling**:
  - Strict `trap` management (`SIGINT`, `SIGTERM`, `EXIT`) ensures all worker processes and temporary scratch files are reliably cleaned up if aborted (`Ctrl+C`).
  - Storage safety limits (caps test writes to 70% available capacity to prevent disk saturation).
  - Physical RAM page commitment (touches memory pages in 4KB strides to force true physical memory allocation rather than virtual uncommitted pages).
- **Live Terminal Metrics**: Real-time countdown timer showing load average and available memory.

---

## Requirements

- **Operating System**: Red Hat Enterprise Linux 7, 8, or 9 (or CentOS Stream / Rocky Linux / AlmaLinux)
- **Shell**: Bash 4.0+ (compatible with Bash 3.2+)
- **Privileges**: Root or `sudo` privileges recommended for full hardware stress and memory allocation capabilities.
- **Optional**: `stress-ng` (available via EPEL) for extended hardware stress metrics.

---

## File Overview

- [`rhel_stress_test.sh`](rhel_stress_test.sh): Main executable stress testing script.
- [`LICENSE`](LICENSE): MIT License.
- [`.gitignore`](.gitignore): Git ignore rules for temporary test files and artifacts.

---

## Quick Start

### 1. Make the script executable
```bash
chmod +x rhel_stress_test.sh
```

### 2. Run Interactively
Launch the interactive configuration menu:
```bash
sudo ./rhel_stress_test.sh
```

### 3. Run via CLI Flags

#### Stress Test All Components (Full System Burn-in)
```bash
# Run full system burn-in for 5 minutes
sudo ./rhel_stress_test.sh -t all -d 5m -y
```

#### Stress Test CPU Only
```bash
# Stress all CPU cores for 60 seconds (default)
sudo ./rhel_stress_test.sh -t cpu -d 60s

# Stress 4 specific cores for 10 minutes
sudo ./rhel_stress_test.sh -t cpu -c 4 -d 10m
```

#### Stress Test Memory (RAM) Only
```bash
# Stress 80% of available RAM for 2 minutes
sudo ./rhel_stress_test.sh -t mem -m 80 -d 2m
```

#### Stress Test Disk I/O Only
```bash
# Stress test disk I/O with 10 GB test cycles on /var/tmp for 5 minutes
sudo ./rhel_stress_test.sh -t disk -p /var/tmp -s 10G -d 5m
```

#### View Detected System Hardware
```bash
./rhel_stress_test.sh -i
```

---

## Command-Line Options

| Option | Long Option | Description | Default |
| :--- | :--- | :--- | :--- |
| `-t` | `--target` | Target component: `cpu`, `memory` (or `mem`), `disk`, `all` | *(Interactive Menu)* |
| `-d` | `--duration` | Duration of the test (e.g. `30s`, `5m`, `1h`) | `60s` |
| `-c` | `--cpus` | Number of CPU worker threads/cores | All online cores |
| `-m` | `--mem-percent` | Percentage of available RAM to stress (1-90%) | `75%` |
| `-p` | `--disk-path` | Target filesystem directory for disk test | `/var/tmp` |
| `-s` | `--disk-size` | Total disk test block size (e.g. `1G`, `4G`) | `4G` |
| `-y` | `--yes` | Non-interactive mode (auto-accepts prompts) | `false` |
| `-i` | `--info` | Display detected system specs and exit | - |
| `-h` | `--help` | Display command usage and help | - |

---

## Tooling Architecture

The script detects if `stress-ng` is available. If not, it can optionally install it via EPEL, or run using pure native Linux utilities:

### Subsystem Implementation Details

| Component | `stress-ng` Engine | Native Fallback Engine |
| :--- | :--- | :--- |
| **CPU** | `stress-ng --cpu <cores> --cpu-method all` | Multi-process arithmetic loops scaled to core count |
| **Memory** | `stress-ng --vm 2 --vm-bytes <size> --vm-keep` | Python 3 buffer allocator touching 4KB pages / `/dev/shm` tmpfs allocation |
| **Disk** | `stress-ng --hdd 2 --hdd-bytes <size> --temp-path <path>` | Direct I/O (`dd` with `oflag=direct,sync` or `conv=fdatasync`) bypassing cache |

### Installing `stress-ng` on RHEL (Optional)

#### RHEL 8 / RHEL 9
```bash
sudo dnf install -y epel-release
sudo dnf install -y stress-ng
```

#### RHEL 7
```bash
sudo yum install -y epel-release
sudo yum install -y stress-ng
```

---

## Safety & Reliability

- **Graceful Termination**: Captures `SIGINT` (Ctrl+C) and `SIGTERM` signals to terminate background worker PIDs immediately.
- **Disk Saturation Guard**: Disk tests calculate available free space before execution and cap block allocation at 70% of available space.
- **No Residual Scratch Files**: All disk and tmpfs test files are tracked in an internal manifest and unlinked upon completion or exit.

---

## License

This project is licensed under the [MIT License](LICENSE).
