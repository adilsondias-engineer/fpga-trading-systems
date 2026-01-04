# Minimal Linux Build Plan for FPGA Trading System

## Target System Specifications

| Component | Specification |
|-----------|---------------|
| CPU | Intel Core i9-14900KF (24 cores / 32 threads) |
| RAM | 128 GB DDR5 |
| GPU | NVIDIA GeForce RTX 5090 (32 GB VRAM) |
| Storage | NVMe (Samsung 970 EVO 250GB for OS, Crucial P3 4TB for data) |
| Network | Intel I226-V 2.5GbE Ethernet |
| PCIe | FPGA via XDMA (Xilinx DMA driver) |

## Build Approach

**Recommended Method**: Buildroot or Yocto-based custom build

**Alternative**: Debootstrap minimal Debian/Ubuntu + manual stripping

This plan uses **Buildroot** for maximum control and minimal footprint.

---

## Quick Reference: File Locations

All configuration files go under the Buildroot external tree:

| File | Path | Purpose |
|------|------|---------|
| **trading_defconfig** | `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig` | Main Buildroot config (BR2_* options) |
| **linux.config** | `/work/tos/trading-linux/buildroot-external/board/trading/linux.config` | Kernel config fragment (CONFIG_* options) |
| **busybox.config** | `/work/tos/trading-linux/buildroot-external/board/trading/busybox.config` | BusyBox configuration (optional) |
| **users.txt** | `/work/tos/trading-linux/buildroot-external/board/trading/users.txt` | User definitions for BR2_ROOTFS_USERS_TABLES |
| **post-build.sh** | `/work/tos/trading-linux/buildroot-external/board/trading/post-build.sh` | Post-build script |
| **overlay/** | `/work/tos/trading-linux/buildroot-external/board/trading/overlay/` | Files copied directly into rootfs |

**What goes where:**
- **Phase 1-3**: All `BR2_*` options → `trading_defconfig`
- **Phase 2**: All `CONFIG_*` kernel options → `linux.config`
- **Phase 7-8**: Systemd services, udev rules, configs → `overlay/etc/`
- **Phase 9**: grub.cfg → `overlay/boot/grub/`

---

## Phase 1: Buildroot Environment Setup

### 1.1 Prerequisites (Build Host)

```bash
# On current Ubuntu 25.10 system
sudo apt install -y \
    build-essential \
    libncurses5-dev \
    git \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    rsync \
    cpio \
    unzip \
    wget

# Clone Buildroot (LTS 2025.02.x - latest stable for Dec 2025)
# Buildroot releases quarterly: 20XX.02 (Feb), 20XX.05, 20XX.08, 20XX.11
# LTS branches are .02 releases with extended support
git clone https://github.com/buildroot/buildroot.git ~/buildroot
cd ~/buildroot
git checkout 2025.02.x  # Or latest point release: 2025.02.1, etc.

# Alternative: Use latest stable if 2025.02 LTS not yet available
# git checkout 2025.11  # November 2025 release
```

### 1.2 Base Configuration

Create custom defconfig for FPGA trading system.

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

```
# Target architecture
BR2_x86_64=y
BR2_x86_alderlake=y  # Closest to i9-14900KF (Raptor Lake Refresh)

# Toolchain
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_GCC_VERSION_13_X=y
BR2_BINUTILS_VERSION_2_42_X=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y

# Kernel (use latest LTS available in Dec 2025)
# 6.12.x is LTS, or use 6.14.x if available
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.12.10"  # LTS (or 6.14.x latest)
BR2_LINUX_KERNEL_DEFCONFIG="x86_64"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_TRADING_PATH)/board/trading/linux.config"

# Root filesystem
BR2_TARGET_ROOTFS_EXT4=y
BR2_TARGET_ROOTFS_EXT4_SIZE="4G"
BR2_TARGET_ROOTFS_SQUASHFS=y  # For RAM-based boot option
```

---

## Phase 2: Kernel Configuration

### 2.1 Required Kernel Modules

**File:** `/work/tos/trading-linux/buildroot-external/board/trading/linux.config`

This is a kernel config **fragment** that gets merged with the base x86_64 defconfig.
Referenced in `trading_defconfig` via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`.

```kconfig
# === CPU ===
CONFIG_SMP=y
CONFIG_NR_CPUS=32
CONFIG_X86_INTEL_PSTATE=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_PREEMPT=y  # Low latency
CONFIG_HZ_1000=y  # 1ms timer resolution

# === Memory ===
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_HUGETLBFS=y
CONFIG_MEMORY_ISOLATION=y

# === PCIe / DMA ===
CONFIG_PCI=y
CONFIG_PCIEPORTBUS=y
CONFIG_PCI_MSI=y
CONFIG_HOTPLUG_PCI_PCIE=y  # Not needed
CONFIG_DMA_ENGINE=y
CONFIG_DMADEVICES=y
CONFIG_INTEL_IOATDMA=n  # Not using IOAT

# === NVIDIA GPU ===
# Built as external module (NVIDIA proprietary driver)
CONFIG_DRM=y
CONFIG_DRM_FBDEV_EMULATION=n  # No framebuffer needed

# === Networking ===
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_NETFILTER=n  # No firewall complexity
CONFIG_BRIDGE=n
CONFIG_VLAN_8021Q=n  # No VLAN needed

# Intel I226-V driver
CONFIG_IGB=n  # Wrong driver
CONFIG_IGC=y  # Correct: Intel I225/I226 Ethernet

# === Storage ===
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
CONFIG_ATA=y
CONFIG_SATA_AHCI=y  # For SATA disks

# === Filesystems ===
CONFIG_EXT4_FS=y
CONFIG_SQUASHFS=y  # For RAM boot
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
```

### 2.2 Console Framebuffer (1080p+ Terminal)

```kconfig
# === Console Graphics (for high-res terminal) ===
CONFIG_FB=y
CONFIG_FB_VESA=y                    # Fallback before NVIDIA loads
CONFIG_FB_EFI=y                     # EFI framebuffer
CONFIG_FB_SIMPLE=y                  # Simple framebuffer
CONFIG_FRAMEBUFFER_CONSOLE=y        # Console on framebuffer
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_VGA_CONSOLE=y

# NVIDIA proprietary driver provides nvidia-drm.ko for console
# which enables high-resolution console (1080p, 4K)
# Kernel cmdline: nvidia-drm.modeset=1
```

### 2.3 Kernel Modules to REMOVE

```kconfig
# === Wireless/Bluetooth ===
CONFIG_WIRELESS=n
CONFIG_CFG80211=n
CONFIG_MAC80211=n
CONFIG_BT=n
CONFIG_RFKILL=n

# === Sound ===
CONFIG_SOUND=n

# === Other Graphics (not needed with NVIDIA) ===
CONFIG_DRM_I915=n
CONFIG_DRM_AMDGPU=n
CONFIG_DRM_RADEON=n
CONFIG_DRM_NOUVEAU=n  # Use proprietary NVIDIA instead

# === USB (minimal) ===
CONFIG_USB_STORAGE=n
CONFIG_USB_PRINTER=n
CONFIG_USB_SERIAL=y
CONFIG_USB_HID=y  # Keep for keyboard

# === Input (minimal) ===
CONFIG_INPUT_TOUCHSCREEN=n
CONFIG_INPUT_TABLET=n
CONFIG_INPUT_JOYSTICK=n
CONFIG_INPUT_MISC=n

# === Media/Camera ===
CONFIG_MEDIA_SUPPORT=n

# === Virtualization (not needed) ===
CONFIG_KVM=n
CONFIG_VHOST=n
CONFIG_VIRTIO=n

# === ARM/PowerPC/etc ===
# Already excluded by x86_64 config

# === Unused filesystems ===
CONFIG_NTFS3_FS=n
CONFIG_BTRFS_FS=n
CONFIG_XFS_FS=n
CONFIG_CIFS=n
CONFIG_NFS_FS=n
```

---

## Phase 3: Userspace Packages

### 3.1 Base System (Buildroot packages)

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

Add these BR2_PACKAGE_* options to the same defconfig file from Phase 1.2.

```
# Core
BR2_PACKAGE_BUSYBOX=y
BR2_PACKAGE_BUSYBOX_CONFIG="$(BR2_EXTERNAL_TRADING_PATH)/board/trading/busybox.config"

# Init system
BR2_INIT_SYSTEMD=y
BR2_PACKAGE_SYSTEMD_LOGIND=y
BR2_PACKAGE_SYSTEMD_NETWORKD=y

# Shell
BR2_PACKAGE_BASH=y

# SSH
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_OPENSSH_SERVER=y

# Networking
BR2_PACKAGE_IPROUTE2=y
BR2_PACKAGE_DHCP=n  # Use systemd-networkd
BR2_PACKAGE_LIBCURL=y
BR2_PACKAGE_LIBCURL_CURL=y  # Include curl binary
BR2_PACKAGE_WGET=y

# Editors
BR2_PACKAGE_VIM=y  # Or nano if smaller

# Utilities
BR2_PACKAGE_HTOP=y
BR2_PACKAGE_PROCPS_NG=y
BR2_PACKAGE_UTIL_LINUX=y

# Time sync
BR2_PACKAGE_CHRONY=y
```

### 3.2 Development Tools (for on-device compilation if needed)

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

```
# Compiler toolchain
BR2_PACKAGE_HOST_GCC=y
BR2_PACKAGE_MAKE=y
BR2_PACKAGE_CMAKE=y
BR2_PACKAGE_PKGCONF=y
BR2_PACKAGE_GIT=y

# C++ runtime
BR2_PACKAGE_LIBSTDCPP=y

# Debug tools
BR2_PACKAGE_GDB=y  # Optional, adds size
BR2_PACKAGE_STRACE=y
BR2_PACKAGE_LTRACE=n  # Not needed
```

### 3.3 Project 24-26 Dependencies

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

```
# Boost (needed for P25, P26)
BR2_PACKAGE_BOOST=y
BR2_PACKAGE_BOOST_SYSTEM=y
BR2_PACKAGE_BOOST_THREAD=y
BR2_PACKAGE_BOOST_ATOMIC=y

# JSON (nlohmann-json)
BR2_PACKAGE_NLOHMANN_JSON=y

# Logging (spdlog)
BR2_PACKAGE_SPDLOG=y

# XGBoost - must be built from source with CUDA
# (see Phase 5 for custom package)
```

### 3.4 Packages NOT Installed

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

These are explicitly disabled to reduce image size.

```
# Desktop/GUI
BR2_PACKAGE_XORG7=n
BR2_PACKAGE_WAYLAND=n
BR2_PACKAGE_QT5=n
BR2_PACKAGE_GTK=n

# Browsers
BR2_PACKAGE_FIREFOX=n
BR2_PACKAGE_CHROMIUM=n

# Office/Productivity
BR2_PACKAGE_LIBREOFFICE=n

# Multimedia
BR2_PACKAGE_FFMPEG=n
BR2_PACKAGE_GSTREAMER=n
BR2_PACKAGE_ALSA_LIB=n
BR2_PACKAGE_PULSEAUDIO=n

# Print/Scan
BR2_PACKAGE_CUPS=n

# Databases (unless needed)
BR2_PACKAGE_POSTGRESQL=n
BR2_PACKAGE_MYSQL=n
BR2_PACKAGE_SQLITE=y  # Small, may be useful

# Containerization
BR2_PACKAGE_DOCKER=n
BR2_PACKAGE_LXC=n

# Cloud tools
BR2_PACKAGE_AWSCLI=n
```

---

## Phase 4: NVIDIA Driver Integration

### 4.1 Driver Build

```bash
# Download NVIDIA driver (match current: 580.95.05)
wget https://download.nvidia.com/XFree86/Linux-x86_64/580.95.05/NVIDIA-Linux-x86_64-580.95.05.run

# Build as kernel module against custom kernel
# Note: Include DRM for console framebuffer support (1080p+ terminal)
./NVIDIA-Linux-x86_64-580.95.05.run \
    --kernel-source-path=/path/to/buildroot/output/build/linux-6.12.10 \
    --kernel-output-path=/path/to/buildroot/output/build/linux-6.12.10 \
    --no-opengl-files \
    --no-x-check \
    --no-nouveau-check \
    --silent

# Kernel modules installed:
# - nvidia.ko (main driver)
# - nvidia-modeset.ko (mode setting)
# - nvidia-drm.ko (DRM/KMS for console - IMPORTANT for 1080p console)
# - nvidia-uvm.ko (unified memory for CUDA)
```

### 4.2 Console Resolution Setup

```bash
# /etc/modprobe.d/nvidia.conf
options nvidia-drm modeset=1

# Kernel command line addition:
# nvidia-drm.modeset=1 video=efifb:off

# This enables nvidia-drm to take over console and provide
# high-resolution terminal (1080p, 1440p, 4K depending on monitor)
```

### 4.3 CUDA Toolkit (Minimal)

Only install runtime libraries needed for XGBoost:

```bash
# IMPORTANT: Use CUDA 13.0, NOT 13.1
# CUDA 13.1 ships CCCL 3.1.2 which has breaking API changes to CUB DeviceRunLengthEncode
# that are incompatible with XGBoost 3.x. CUDA 13.0 uses CCCL 3.0.1 which is compatible.

# Download CUDA 13.0 runfile
wget https://developer.download.nvidia.com/compute/cuda/13.0.0/local_installers/cuda_13.0.0_xxx.xx.xx_linux.run

# Install with:
./cuda_13.0.0_xxx.xx.xx_linux.run \
    --toolkit \
    --no-opengl-libs \
    --no-drm \
    --silent \
    --override

# Required components only:
# - libcudart.so (CUDA runtime)
# - libcublas.so (used by XGBoost)
# - libcurand.so (used by XGBoost)
```

### 4.4 glibc 2.42+ rsqrt Conflict Patch (Required for Ubuntu 25.04+)

glibc 2.42+ introduces `rsqrt()` with `noexcept(true)` (C23 IEC 60559) that conflicts
with CUDA's rsqrt device function. Apply this one-time patch after CUDA installation:

```bash
# Patch CUDA headers for glibc 2.42 compatibility
sudo sed -i.bak \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x) noexcept(true);/' \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x) noexcept(true);/' \
  /usr/local/cuda-13.0/targets/x86_64-linux/include/crt/math_functions.h

# To revert if needed:
# sudo mv /usr/local/cuda-13.0/targets/x86_64-linux/include/crt/math_functions.h.bak \
#         /usr/local/cuda-13.0/targets/x86_64-linux/include/crt/math_functions.h
```

### 4.5 Minimal CUDA Directory (~500 MB vs 5+ GB full install)

```
/opt/cuda/
├── lib64/
│   ├── libcudart.so.13.0
│   ├── libcublas.so.13
│   ├── libcublasLt.so.13
│   ├── libcurand.so.10
│   └── stubs/
├── include/  # Headers for compilation
└── bin/
    └── nvcc  # Only if on-device compilation needed
```

---

## Phase 5: XDMA Driver Integration

### 5.1 Build XDMA Driver (Cross-Compiled)

**IMPORTANT:** The XDMA driver must be cross-compiled using Buildroot's toolchain
and built against Buildroot's kernel source. Using the host system's kernel or
gcc will produce an incompatible module.

```bash
# Set up Buildroot environment variables
export BR2_OUTPUT=/work/tos/buildroot/output
export KDIR=$BR2_OUTPUT/build/linux-6.12.10  # Adjust kernel version
export CROSS_COMPILE=$BR2_OUTPUT/host/bin/x86_64-buildroot-linux-gnu-
export ARCH=x86_64

# Clone Xilinx DMA driver
git clone https://github.com/Xilinx/dma_ip_drivers.git
cd dma_ip_drivers/XDMA/linux-kernel/xdma

# Cross-compile against Buildroot kernel
# IMPORTANT: The XDMA Makefile uses BUILDSYSTEM_DIR, not KDIR!
# If you pass KDIR it will be ignored and it will use /lib/modules/$(uname -r)/build
make BUILDSYSTEM_DIR=$KDIR CROSS_COMPILE=$CROSS_COMPILE ARCH=$ARCH

# Verify the module is built for the correct kernel
modinfo xdma.ko | grep vermagic
# Should show: 6.12.10 (matches Buildroot kernel version)

# Result: xdma.ko (cross-compiled for target)
```

**Common Errors:**
- `Invalid module format`: Module built with wrong kernel version or compiler
- `Unknown symbol`: Kernel config mismatch (ensure CONFIG_PCI=y, CONFIG_DMA_ENGINE=y)
- Using host `make` without CROSS_COMPILE will use `/usr/bin/gcc` instead of Buildroot's cross-compiler
- **Using `KDIR=` instead of `BUILDSYSTEM_DIR=`**: The XDMA Makefile ignores KDIR and uses its own BUILDSYSTEM_DIR variable

### 5.2 Udev Rules

```bash
# /etc/udev/rules.d/60-xdma.rules
SUBSYSTEM=="xdma", MODE="0666"
KERNEL=="xdma*", MODE="0666"
```

### 5.3 Systemd Service for XDMA

```ini
# /etc/systemd/system/xdma.service
[Unit]
Description=XDMA Driver Load
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/sbin/modprobe xdma
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

---

## Phase 6: XGBoost with CUDA

### 6.1 Build XGBoost 3.2.0 from Source

**IMPORTANT:** Use XGBoost 3.2.0 (development/main branch) with CUDA 13.0. Do NOT use CUDA 13.1
due to CCCL 3.1.2 API breaking changes.

**Note:** Version 3.2.0 is the current development version on the main branch. The latest
tagged stable release is v3.1.2, but we use main for latest features and fixes.

```bash
# Clone XGBoost main branch (version 3.2.0-dev)
git clone --recursive https://github.com/dmlc/xgboost.git
cd xgboost
# Stay on main branch (3.2.0-dev) - do NOT checkout a tag
git submodule update --init --recursive

mkdir build && cd build

# RTX 5090 = Blackwell architecture (sm_100 or sm_90 for compatibility)
# CUDA 13.0 is required (13.1 has CCCL 3.1.2 breaking changes)
# Set NVCC flags via environment variable (CMAKE_CUDA_FLAGS doesn't always propagate)
export CUDAFLAGS="-allow-unsupported-compiler"
export NVCC_APPEND_FLAGS="-allow-unsupported-compiler"

# Option 1: Copy existing CUDA 13.0 install (recommended - simpler)
# cp -a /usr/local/cuda-13.0 /work/tos/cuda-13.0
CUDA_DIR=/work/tos/cuda-13.0

# Option 2: If using extracted .run file, set CUDA_DIR=/work/tos/cuda-extract/builds/cuda_nvcc
# and create symlink: ln -sf ../libnvvm/nvvm $CUDA_DIR/nvvm

cmake .. \
    -DUSE_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="90" \
    -DBUILD_STATIC_LIB=OFF \
    -DPLUGIN_DENSE_PARSER=OFF \
    -DPLUGIN_RMM=OFF \
    -DCMAKE_CUDA_COMPILER=$CUDA_DIR/bin/nvcc \
    -DCMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES=$CUDA_DIR/include \
    -DCUDA_TOOLKIT_ROOT_DIR=$CUDA_DIR \
    -DCMAKE_PREFIX_PATH="$CUDA_DIR/targets/x86_64-linux/lib/cmake"

make -j$(nproc)
# Result: libxgboost.so (~85 MB)
```

### 6.2 Minimal XGBoost Installation

```
/opt/xgboost/
├── lib/
│   └── libxgboost.so
└── include/
    └── xgboost/
        └── c_api.h
```

---

## Phase 7: System Configuration

### 7.1 Network Configuration (systemd-networkd)

```ini
# /etc/systemd/network/10-ethernet.network
[Match]
Name=enp7s0  # Intel I226-V interface name

[Network]
DHCP=yes
# Or static:
# Address=192.168.1.100/24
# Gateway=192.168.1.1
# DNS=8.8.8.8
```

### 7.2 SSH Hardening

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no  # Key-only
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding yes
```

### 7.3 User Setup

**Option 1: Buildroot User Tables (Recommended)**

Create a users table file that Buildroot will process during build:

```bash
# File: /work/tos/trading-linux/buildroot-external/board/trading/users.txt
# Format: username uid group gid password home shell groups comment

# Trading user with access to device groups AND sudo (wheel group)
# Note: Use /bin/sh for Busybox-based systems (not /bin/bash)
# IMPORTANT: Do NOT add root here - mkusers rejects "root" username!
trading 1000 trading 1000 = /home/trading /bin/sh video,dialout,input,wheel Trading User
```

**Setting Root Password:**

Root password cannot be set via users.txt (mkusers script rejects "root" username).
Use `BR2_TARGET_GENERIC_ROOT_PASSWD` in defconfig instead:

```bash
# In trading_defconfig:
# Option A: Plain text password (NOT recommended, but simple for development)
BR2_TARGET_GENERIC_ROOT_PASSWD="trading123"

# Option B: Pre-hashed password (more secure)
# Generate hash: mkpasswd -m sha-512 trading123
BR2_TARGET_GENERIC_ROOT_PASSWD="$6$xyz$hashedpassword..."
```

**Generating password hashes:**
```bash
# Install mkpasswd if needed
sudo apt install whois

# Generate SHA-512 hash for password "trading123"
mkpasswd -m sha-512 trading123
# Output: $6$randomsalt$longhash...

# Use this hash in the users.txt file for the password field
```

**Sudoers configuration:**

Create sudoers file in overlay to allow wheel group (includes trading user):

```bash
# File: $OVERLAY/etc/sudoers.d/trading
# Allow wheel group to run any command without password
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
```

Or with password prompt:
```bash
# Allow wheel group to run any command (prompts for password)
%wheel ALL=(ALL:ALL) ALL
```

**Important:** Set correct permissions for sudoers file:
```bash
mkdir -p $OVERLAY/etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > $OVERLAY/etc/sudoers.d/trading
chmod 440 $OVERLAY/etc/sudoers.d/trading
```

Add to your Buildroot defconfig.

**File:** `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`

```
BR2_ROOTFS_USERS_TABLES="$(BR2_EXTERNAL_TRADING_PATH)/board/trading/users.txt"
```

**Option 2: Static Files in Overlay**

Add user entries directly to overlay files:

```bash
# Create overlay files
mkdir -p $OVERLAY/etc

# /etc/passwd - append trading user
cat >> $OVERLAY/etc/passwd << 'EOF'
trading:x:1000:1000:Trading User:/home/trading:/bin/bash
EOF

# /etc/group - append trading group and add to existing groups
cat >> $OVERLAY/etc/group << 'EOF'
trading:x:1000:
EOF

# /etc/shadow - trading user with no password (use ! for locked)
cat >> $OVERLAY/etc/shadow << 'EOF'
trading:!:19700:0:99999:7:::
EOF

# Create home directory
mkdir -p $OVERLAY/home/trading
chmod 755 $OVERLAY/home/trading
```

**Option 3: Post-Build Script**

Add user creation to post-build.sh (runs in fakeroot):

```bash
# File: /work/tos/trading-linux/buildroot-external/board/trading/post-build.sh
#!/bin/bash
# This script runs with fakeroot, so we can modify passwd/group files

TARGET_DIR=$1

# Add trading user if not exists
if ! grep -q "^trading:" $TARGET_DIR/etc/passwd; then
    echo "trading:x:1000:1000:Trading User:/home/trading:/bin/bash" >> $TARGET_DIR/etc/passwd
    echo "trading:x:1000:" >> $TARGET_DIR/etc/group
    echo "trading:!:19700:0:99999:7:::" >> $TARGET_DIR/etc/shadow
    mkdir -p $TARGET_DIR/home/trading
fi

# Add trading to video and dialout groups
sed -i 's/^\(video:.*\)/\1,trading/' $TARGET_DIR/etc/group
sed -i 's/^\(dialout:.*\)/\1,trading/' $TARGET_DIR/etc/group
```

**Note:** For the trading system running as root (systemd service), user setup is optional.
The trading-system.service runs as root for RT scheduling and device access.

### 7.4 Real-Time Optimizations

```ini
# /etc/sysctl.d/99-trading.conf
# Reduce swap usage
vm.swappiness=1

# Increase max locked memory
vm.max_map_count=262144

# Network tuning
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000

# Disable transparent huge pages for latency
# (Done via kernel cmdline: transparent_hugepage=never)
```

### 7.5 CPU Isolation (Kernel Command Line)

```
# /etc/kernel/cmdline or GRUB
isolcpus=4-23 nohz_full=4-23 rcu_nocbs=4-23
intel_pstate=performance
mitigations=off
transparent_hugepage=never
```

This isolates cores 4-23 for trading applications, leaving cores 0-3 for OS.

---

## Phase 8: Trading Application Deployment

### 8.1 Directory Structure

```
/opt/trading/
├── bin/
│   ├── order_gateway       # P24
│   ├── market_maker        # P25
│   └── order_execution     # P26
├── config/
│   ├── p24_config.json
│   ├── p25_config.json
│   └── p26_config.json
├── model/
│   └── itch_predictor.ubj  # XGBoost model (36 MB)
└── lib/
    ├── libxgboost.so
    └── libspdlog.so
```

### 8.2 Systemd Service (Orchestrator)

Project 28 (trading_system_orchestrator) manages all components (P24, P25, P26), so we use a **single systemd service** instead of individual services per project.

**CPU affinity is handled by P28's config** (`performance.cpu_affinity`), not systemd. This allows runtime reconfiguration without editing service files.

```ini
# /etc/systemd/system/trading-system.service
[Unit]
Description=FPGA Trading System Orchestrator
After=network.target xdma.service nvidia-gpu.service
Requires=xdma.service
Wants=nvidia-gpu.service

[Service]
Type=simple
ExecStart=/opt/trading/bin/trading_system_orchestrator /opt/trading/config/system_config.json
ExecStop=/bin/kill -SIGTERM $MAINPID
WorkingDirectory=/opt/trading
Restart=on-failure
RestartSec=5
User=root

# Performance tuning (systemd level)
Nice=-20
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=90
LimitMEMLOCK=infinity
LimitRTPRIO=99

# Note: No CPUAffinity here - P28 manages per-process affinity via config:
#   "cpu_affinity": {
#     "project_24": [2, 3],
#     "project_25": [4, 5],
#     "project_26": [6, 7],
#     "orchestrator": [0]
#   }

# Environment
Environment="LD_LIBRARY_PATH=/opt/cuda/lib64:/opt/xgboost/lib"
Environment="CUDA_VISIBLE_DEVICES=0"

[Install]
WantedBy=multi-user.target
```

**Why root user?** The orchestrator needs root to:
- Set real-time scheduling priority (SCHED_FIFO)
- Set CPU affinity on child processes
- Access `/dev/xdma0_c2h_0` (PCIe DMA device)

The orchestrator can drop privileges for child processes if needed.

---

## Phase 9: Build Bootable ISO

Buildroot creates `rootfs.iso9660` automatically. You just need to add `grub.cfg` to the overlay.

### 9.1 Enable ISO Output in Defconfig

These settings should already be in your `trading_defconfig` (from Phase 1.2).
Verify they're present in `/work/tos/trading-linux/buildroot-external/configs/trading_defconfig`:

```
# Filesystem images (add to trading_defconfig if not present)
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_SQUASHFS=y
BR2_TARGET_ROOTFS_ISO9660=y
BR2_TARGET_ROOTFS_ISO9660_GRUB2=y
BR2_TARGET_ROOTFS_ISO9660_HYBRID=y
```

**Note:** Do NOT use the default Buildroot defconfig (i386). Always use your custom
`trading_defconfig` which is configured for x86_64 Raptor Lake.

### 9.2 Create GRUB Configuration in Overlay

```bash
# OVERLAY=/work/tos/trading-linux/buildroot-external/board/trading/overlay
mkdir -p $OVERLAY/boot/grub
cat > $OVERLAY/boot/grub/grub.cfg << 'EOF'
# GRUB2 Configuration for Trading Linux
set default=0
set timeout=5

insmod all_video
insmod gfxterm
terminal_output gfxterm

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Trading Linux (Normal Boot)" {
    linux /boot/bzImage root=/dev/sda2 ro quiet \
        isolcpus=4-23 nohz_full=4-23 rcu_nocbs=4-23 \
        intel_pstate=performance \
        mitigations=off \
        transparent_hugepage=never \
        nvidia-drm.modeset=1
}

menuentry "Trading Linux (Debug Mode)" {
    linux /boot/bzImage root=/dev/sda2 rw \
        isolcpus=4-23 nohz_full=4-23 rcu_nocbs=4-23 \
        intel_pstate=performance \
        loglevel=7 \
        systemd.log_level=debug
}

menuentry "Trading Linux (Recovery)" {
    linux /boot/bzImage root=/dev/sda2 rw single \
        systemd.unit=rescue.target
}

menuentry "UEFI Firmware Settings" {
    fwsetup
}
EOF
```

### 9.3 Rebuild and Write to USB

```bash
# Rebuild Buildroot (incorporates grub.cfg from overlay)
cd /work/tos/buildroot
make

# Output files in output/images/:
#   bzImage          - Linux kernel
#   rootfs.iso9660   - Bootable ISO with GRUB2 (use this!)
#   rootfs.squashfs  - Compressed rootfs (already included in ISO)
#   rootfs.ext4      - For NVMe installation later
#   rootfs.tar       - For manual extraction

# Write ISO to USB (CAUTION: replace /dev/sdX!)
sudo dd if=output/images/rootfs.iso9660 of=/dev/sdX bs=4M status=progress conv=fsync
```

### 9.4 Kernel Command Line Options

| Option | Purpose |
|--------|---------|
| `isolcpus=4-23` | Reserve CPUs 4-23 for trading apps |
| `nohz_full=4-23` | Disable timer ticks on isolated CPUs |
| `rcu_nocbs=4-23` | Move RCU callbacks off isolated CPUs |
| `intel_pstate=performance` | Lock CPU at max frequency |
| `mitigations=off` | Disable Spectre/Meltdown (performance vs security) |
| `transparent_hugepage=never` | Disable THP (reduces latency spikes) |
| `nvidia-drm.modeset=1` | NVIDIA kernel modesetting |

### 9.5 Test in QEMU (Optional)

```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -cpu host \
    -cdrom output/images/rootfs.iso9660 \
    -bios /usr/share/ovmf/OVMF.fd
```

### 9.6 Install to NVMe (After Booting from USB)

Once booted from USB, install to NVMe:

```bash
# Partition NVMe (CAUTION: erases data!)
NVME=/dev/nvme0n1

sudo parted $NVME --script mklabel gpt
sudo parted $NVME --script mkpart ESP fat32 1MiB 512MiB
sudo parted $NVME --script set 1 esp on
sudo parted $NVME --script mkpart primary ext4 512MiB 100%

sudo mkfs.vfat -F 32 -n TRADING_EFI ${NVME}p1
sudo mkfs.ext4 -L TRADING_ROOT ${NVME}p2

# Mount and copy
sudo mkdir -p /mnt/nvme/efi /mnt/nvme/root
sudo mount ${NVME}p1 /mnt/nvme/efi
sudo mount ${NVME}p2 /mnt/nvme/root

# Copy rootfs
sudo cp -a /* /mnt/nvme/root/ --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/mnt

# Install GRUB to NVMe EFI partition
sudo grub-install --target=x86_64-efi \
    --efi-directory=/mnt/nvme/efi \
    --boot-directory=/mnt/nvme/efi/boot \
    --removable

# Copy grub.cfg (update root= for NVMe)
sudo mkdir -p /mnt/nvme/efi/boot/grub
sudo sed 's|root=/dev/sda2|root=/dev/nvme0n1p2|g' /boot/grub/grub.cfg > /mnt/nvme/efi/boot/grub/grub.cfg

# Create fstab
sudo tee /mnt/nvme/root/etc/fstab << 'EOF'
/dev/nvme0n1p2  /     ext4  defaults,noatime  0  1
/dev/nvme0n1p1  /boot vfat  defaults          0  2
tmpfs           /tmp  tmpfs defaults,size=2G  0  0
EOF

sync
sudo umount /mnt/nvme/efi /mnt/nvme/root
sudo reboot
```

---

## Phase 10: Expected Size

| Component | Size |
|-----------|------|
| Linux Kernel (stripped) | ~8 MB |
| Root filesystem (SquashFS) | ~200-300 MB |
| NVIDIA Driver | ~150 MB |
| CUDA Runtime libs | ~500 MB |
| XGBoost + Model | ~120 MB |
| Trading Applications | ~50 MB |
| **Total ISO** | **~1-1.5 GB** |
| **RAM Required** | **~2 GB** |

Compare to full Ubuntu 25.10: ~15-20 GB installed

---

## Alternative Approach: Debootstrap (Faster, Less Optimized)

If Buildroot is too complex, use Debian debootstrap:

```bash
# Create minimal Debian
sudo debootstrap --variant=minbase --arch=amd64 bookworm /mnt/trading http://deb.debian.org/debian

# Chroot and install packages
sudo chroot /mnt/trading
apt install -y \
    linux-image-amd64 \
    systemd \
    openssh-server \
    iproute2 \
    curl wget \
    build-essential cmake git \
    libboost-all-dev \
    nlohmann-json3-dev

# Remove unnecessary packages
apt purge -y \
    wireless-tools wpasupplicant \
    bluez bluetooth \
    cups* \
    avahi-daemon \
    modemmanager
```

This results in ~1.5-2 GB but less optimized than Buildroot.

---

## Implementation Timeline

| Phase | Description | Effort |
|-------|-------------|--------|
| 1 | Buildroot setup | 2-4 hours |
| 2 | Kernel config | 4-8 hours (iterative) |
| 3 | Userspace packages | 2-4 hours |
| 4 | NVIDIA driver | 2-4 hours |
| 5 | XDMA driver | 1-2 hours |
| 6 | XGBoost build | 2-4 hours |
| 7 | System config | 2-4 hours |
| 8 | App deployment | 2-4 hours |
| 9 | ISO creation | 1-2 hours |
| 10 | Testing | 4-8 hours |
| **Total** | | **~24-40 hours** |

---

## Buildroot External Tree Structure

The external tree path is: `/work/tos/trading-linux/buildroot-external/`

```
/work/tos/trading-linux/buildroot-external/
├── Config.in                    # Empty or custom package includes
├── external.mk                  # Empty or custom package makefiles
├── external.desc                # "name: TRADING" + "desc: FPGA Trading System"
├── configs/
│   └── trading_defconfig        # Main Buildroot config (BR2_* options)
├── board/
│   └── trading/
│       ├── linux.config         # Kernel config fragment (replaces kernel-fragments/)
│       ├── busybox.config       # Custom BusyBox configuration (optional)
│       ├── post-build.sh        # Runs after each `make`
│       ├── users.txt            # User definitions for BR2_ROOTFS_USERS_TABLES
│       └── overlay/             # Files copied directly into rootfs
│           ├── boot/
│           │   └── grub/
│           │       └── grub.cfg
│           ├── etc/
│           │   ├── systemd/system/
│           │   │   ├── trading-system.service
│           │   │   └── xdma.service
│           │   ├── sysctl.d/
│           │   │   └── 99-trading.conf
│           │   ├── udev/rules.d/
│           │   │   └── 60-xdma.rules
│           │   ├── ld.so.conf.d/
│           │   │   ├── cuda.conf
│           │   │   └── xgboost.conf
│           │   ├── modprobe.d/
│           │   │   └── nvidia.conf
│           │   └── sudoers.d/
│           │       └── trading
│           ├── lib/
│           │   └── modules/     # NVIDIA, XDMA kernel modules (added post-build)
│           └── opt/
│               ├── cuda/        # CUDA runtime libs (added post-build)
│               ├── xgboost/     # XGBoost library (added post-build)
│               └── trading/     # Trading apps (added post-build)
│                   ├── bin/
│                   ├── config/
│                   └── model/
└── README.md

# Full overlay path for scripts:
OVERLAY=/work/tos/trading-linux/buildroot-external/board/trading/overlay
```

**Config files explained:**
- `configs/trading_defconfig` - Main Buildroot config with BR2_* options (toolchain, packages, kernel version)
- `board/trading/linux.config` - Kernel config fragment referenced by defconfig via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`

Both are required. The defconfig tells Buildroot what to build; the linux.config customizes the kernel.

---

## Next Steps

1. **Approve this plan** - review and adjust requirements
2. **Create Buildroot external tree** - implement the configuration
3. **Test kernel config** - iteratively build and test
4. **Build NVIDIA/CUDA** - integrate proprietary components
5. **Create ISO** - final packaging
6. **Hardware test** - boot on target system

---

## Post-Buildroot Workflow: When Do Phases 4-6 Happen?

This section clarifies the workflow after `make` completes in Buildroot.

### Buildroot Produces (Phase 1-3)

After running `make` in Buildroot with your external tree, you get:

```
buildroot/output/
├── images/
│   ├── bzImage              # Linux kernel
│   ├── rootfs.ext4          # Root filesystem (or rootfs.squashfs)
│   └── rootfs.tar           # For manual modification
├── build/
│   └── linux-6.12.x/        # Kernel source (needed for module builds)
└── target/
    └── ...                  # Staged filesystem (for overlay modifications)
```

At this point you have a **bootable base system** with kernel + userspace, but
**WITHOUT** the proprietary NVIDIA driver, CUDA, or external kernel modules.

### When Phases 4-6 Execute

Phases 4-6 are **post-build steps** executed AFTER Buildroot completes:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BUILDROOT BUILD (Phases 1-3)                      │
│  `make` in buildroot/ with BR2_EXTERNAL=trading-linux/               │
│  Output: bzImage, rootfs.ext4, kernel source tree                    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4: NVIDIA Driver (Post-Build)                                 │
│  1. Download NVIDIA-Linux-x86_64-580.xx.xx.run                       │
│  2. Build against: buildroot/output/build/linux-6.12.x/              │
│  3. Copy nvidia*.ko to rootfs overlay                                │
│  4. Add modprobe.d and udev rules                                    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4 (cont): CUDA 13.0 Installation                              │
│  1. Download CUDA 13.0 runfile (NOT 13.1 - CCCL compatibility)       │
│  2. Extract runtime libs (libcudart, libcublas, libcurand)           │
│  3. Apply glibc 2.42 rsqrt patch to headers                          │
│  4. Copy to rootfs overlay: /opt/cuda/                               │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 5: XDMA Driver (Post-Build)                                   │
│  1. Clone dma_ip_drivers                                             │
│  2. Build xdma.ko against: buildroot/output/build/linux-6.12.x/      │
│  3. Copy xdma.ko to rootfs overlay                                   │
│  4. Add udev rules and systemd service                               │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 6: XGBoost 3.2.0 (Post-Build)                                 │
│  1. Clone xgboost main branch (3.2.0-dev)                            │
│  2. Build with CUDA 13.0 (NOT 13.1)                                  │
│  3. Copy libxgboost.so to rootfs overlay: /opt/xgboost/lib/          │
│  4. Copy c_api.h headers                                             │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  REBUILD ROOTFS (After Phase 4-6)                                    │
│  Run `make` again in buildroot/ to incorporate overlays              │
│  Or manually pack: `tar cf rootfs.tar -C output/target .`            │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 8: Trading App Deployment                                     │
│  Cross-compile P24, P25, P26 on host                                 │
│  Copy binaries to /opt/trading/bin/                                  │
│  Copy model/itch_predictor.ubj to /opt/trading/model/                │
│  Add systemd services                                                │
└─────────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Post-Build Commands

```bash
# === After Buildroot completes ===
cd /work/tos/buildroot

# Set up environment for cross-compilation
export BR2_OUTPUT=$PWD/output
export KDIR=$BR2_OUTPUT/build/linux-6.12.10  # Adjust version as needed
export OVERLAY=/work/tos/trading-linux/buildroot-external/board/trading/overlay
export CROSS_COMPILE=$BR2_OUTPUT/host/bin/x86_64-buildroot-linux-gnu-
export ARCH=x86_64

# Get target kernel version (NOT host kernel)
KVER=$(cat $KDIR/include/config/kernel.release)
echo "Building for kernel: $KVER"

# === Phase 4: NVIDIA Driver (Cross-Compiled) ===
# Download driver (match version to your GPU)
wget https://download.nvidia.com/XFree86/Linux-x86_64/580.95.05/NVIDIA-Linux-x86_64-580.95.05.run

# Extract driver
chmod +x NVIDIA-Linux-x86_64-580.95.05.run
./NVIDIA-Linux-x86_64-580.95.05.run --extract-only
cd NVIDIA-Linux-x86_64-580.95.05/kernel

# IMPORTANT: Use Buildroot cross-compiler and kernel source
export CROSS_COMPILE=$BR2_OUTPUT/host/bin/x86_64-buildroot-linux-gnu-
export ARCH=x86_64
make SYSSRC=$KDIR SYSOUT=$KDIR CC="${CROSS_COMPILE}gcc" LD="${CROSS_COMPILE}ld" module

# Get kernel version from Buildroot kernel (NOT from host uname -r)
KVER=$(cat $KDIR/include/config/kernel.release)
mkdir -p $OVERLAY/usr/lib/modules/$KVER/kernel/drivers/video/nvidia
cp *.ko $OVERLAY/usr/lib/modules/$KVER/kernel/drivers/video/nvidia/

# === Phase 4: CUDA 13.0 (NOT 13.1) ===
# IMPORTANT: CUDA 13.1 has CCCL 3.1.2 which breaks XGBoost
cd /work/tos

# Download CUDA 13.0 (if not already present)
# wget https://developer.download.nvidia.com/compute/cuda/13.0.0/local_installers/cuda_13.0.0_580.65.06_linux.run

# NOTE: The --extract option may fail with "gzip: unexpected end of file"
# Use --tar instead to extract the archive:
chmod +x cuda_13.0.0_580.65.06_linux.run
mkdir -p cuda-extract && cd cuda-extract
../cuda_13.0.0_580.65.06_linux.run --tar xf 2>/dev/null || true
# The extraction may show errors but critical files are usually extracted

# Copy libraries from the extracted builds directory
mkdir -p $OVERLAY/opt/cuda/lib64
mkdir -p $OVERLAY/opt/cuda/include
mkdir -p $OVERLAY/opt/cuda/bin

# Runtime libraries
cp builds/cuda_cudart/targets/x86_64-linux/lib/libcudart.so* $OVERLAY/opt/cuda/lib64/
cp builds/libcublas/targets/x86_64-linux/lib/libcublas.so* $OVERLAY/opt/cuda/lib64/
cp builds/libcublas/targets/x86_64-linux/lib/libcublasLt.so* $OVERLAY/opt/cuda/lib64/
cp builds/libcurand/targets/x86_64-linux/lib/libcurand.so* $OVERLAY/opt/cuda/lib64/

# Headers (for compilation on target, if needed)
cp -r builds/cuda_cudart/targets/x86_64-linux/include/* $OVERLAY/opt/cuda/include/
cp -r builds/cuda_cccl/targets/x86_64-linux/include/* $OVERLAY/opt/cuda/include/

# NVCC compiler toolchain (required for XGBoost CUDA build)
# nvcc needs the full toolchain: nvcc, cicc, ptxas, fatbinary, nvlink, etc.
cp -r builds/cuda_nvcc/bin/* $OVERLAY/opt/cuda/bin/

# IMPORTANT: nvvm (containing cicc) is in libnvvm/, NOT cuda_nvcc/
# nvcc looks for cicc at ../nvvm/bin/cicc relative to its bin/ location
cp -r builds/libnvvm/nvvm $OVERLAY/opt/cuda/  # Contains cicc (CUDA IR compiler)

# Create symlink in cuda_nvcc so nvcc can find cicc during XGBoost build
# (nvcc is at cuda_nvcc/bin/nvcc and looks for ../nvvm/bin/cicc)
ln -sf ../libnvvm/nvvm builds/cuda_nvcc/nvvm

cd /work/tos

# Apply glibc 2.42 rsqrt patch to the extracted CUDA headers
# This is needed if building XGBoost on Ubuntu 25.04+ (glibc 2.42+)
sed -i.bak \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x) noexcept(true);/' \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x) noexcept(true);/' \
  builds/cuda_crt/targets/x86_64-linux/include/crt/math_functions.h

# Also patch the overlay copy
sed -i.bak \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double                 rsqrt(double x) noexcept(true);/' \
  -e 's/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x);/extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ float                  rsqrtf(float x) noexcept(true);/' \
  $OVERLAY/opt/cuda/include/crt/math_functions.h 2>/dev/null || true

# === Phase 5: XDMA Driver (Cross-Compiled) ===
cd /work/tos
git clone https://github.com/Xilinx/dma_ip_drivers.git
cd dma_ip_drivers/XDMA/linux-kernel/xdma

# IMPORTANT: Use Buildroot cross-compiler, NOT host gcc
# IMPORTANT: Use BUILDSYSTEM_DIR, not KDIR (the Makefile ignores KDIR!)
export CROSS_COMPILE=$BR2_OUTPUT/host/bin/x86_64-buildroot-linux-gnu-
export ARCH=x86_64
make BUILDSYSTEM_DIR=$KDIR CROSS_COMPILE=$CROSS_COMPILE ARCH=$ARCH

# Get kernel version from Buildroot kernel (NOT from host uname -r)
KVER=$(cat $KDIR/include/config/kernel.release)
mkdir -p $OVERLAY/usr/lib/modules/$KVER/kernel/drivers/misc/xdma
cp xdma.ko $OVERLAY/usr/lib/modules/$KVER/kernel/drivers/misc/xdma/

# === Phase 6: XGBoost 3.2.0 (main branch) ===
cd /work/tos
git clone --recursive https://github.com/dmlc/xgboost.git
cd xgboost
# Stay on main branch (3.2.0-dev) - no checkout needed
git submodule update --init --recursive
mkdir build && cd build

# Use CUDA from extracted files, NOT system /usr/local/cuda
# -allow-unsupported-compiler: Required for GCC 13+ with CUDA 13.0
# Set via environment variable (CMAKE_CUDA_FLAGS doesn't always propagate to nvcc)
export CUDAFLAGS="-allow-unsupported-compiler"
export NVCC_APPEND_FLAGS="-allow-unsupported-compiler"

# CUDA_EXTRACT points to the builds/ directory from --tar extraction
# nvcc looks for cicc at ../nvvm/bin/cicc relative to its location
CUDA_EXTRACT=/work/tos/cuda-extract/builds

# IMPORTANT: Create symlink so nvcc can find cicc
# nvvm is in libnvvm/, not cuda_nvcc/ - nvcc expects it at ../nvvm relative to bin/
ln -sf ../libnvvm/nvvm $CUDA_EXTRACT/cuda_nvcc/nvvm

cmake .. \
    -DUSE_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="90" \
    -DCMAKE_CUDA_COMPILER=$CUDA_EXTRACT/cuda_nvcc/bin/nvcc \
    -DCMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES=$CUDA_EXTRACT/cuda_cudart/targets/x86_64-linux/include \
    -DCUDA_TOOLKIT_ROOT_DIR=$CUDA_EXTRACT/cuda_nvcc
make -j$(nproc)

mkdir -p $OVERLAY/opt/xgboost/lib
mkdir -p $OVERLAY/opt/xgboost/include/xgboost
cp lib/libxgboost.so $OVERLAY/opt/xgboost/lib/
cp ../include/xgboost/c_api.h $OVERLAY/opt/xgboost/include/xgboost/

# === Rebuild Rootfs with Overlays ===
cd /work/tos/buildroot
make  # Incorporates overlay into rootfs

# === Phase 7: Deploy Trading Apps (P24, P25, P26, P28) ===
# Cross-compile all projects against buildroot toolchain

# Create target directories
mkdir -p $OVERLAY/opt/trading/bin
mkdir -p $OVERLAY/opt/trading/config
mkdir -p $OVERLAY/opt/trading/model

# --- Project 24: Order Gateway (PCIe + XGBoost) ---
cd /work/projects/fpga-trading-systems/24-order-gateway
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=/work/tos/buildroot/output/host/share/buildroot/toolchainfile.cmake
make -j$(nproc)
cp order_gateway $OVERLAY/opt/trading/bin/
cp ../config.json $OVERLAY/opt/trading/config/p24_config.json
cp ../model/itch_predictor.ubj $OVERLAY/opt/trading/model/

# --- Project 25: Market Maker ---
cd /work/projects/fpga-trading-systems/25-market-maker
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=/work/tos/buildroot/output/host/share/buildroot/toolchainfile.cmake
make -j$(nproc)
cp market_maker $OVERLAY/opt/trading/bin/
cp ../config.json $OVERLAY/opt/trading/config/p25_config.json

# --- Project 26: Order Execution ---
cd /work/projects/fpga-trading-systems/26-order-execution
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=/work/tos/buildroot/output/host/share/buildroot/toolchainfile.cmake
make -j$(nproc)
cp order_execution_engine $OVERLAY/opt/trading/bin/
cp ../config.json $OVERLAY/opt/trading/config/p26_config.json

# --- Project 28: System Orchestrator ---
cd /work/projects/fpga-trading-systems/28-complete-system
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=/work/tos/buildroot/output/host/share/buildroot/toolchainfile.cmake
make -j$(nproc)
cp trading_system_orchestrator $OVERLAY/opt/trading/bin/

# Create target-specific system config for orchestrator
cat > $OVERLAY/opt/trading/config/system_config.json << 'EOF'
{
  "system": {
    "name": "FPGA Trading System (PCIe + XGBoost)",
    "version": "2.0.0",
    "log_level": "INFO",
    "enable_prometheus": true,
    "enable_auto_restart": true,
    "healthcheck_interval_ms": 500,
    "startup_timeout_seconds": 30,
    "shutdown_timeout_seconds": 10
  },

  "project_24": {
    "name": "Order Gateway (PCIe + XGBoost)",
    "executable": "/opt/trading/bin/order_gateway",
    "config_file": "/opt/trading/config/p24_config.json",
    "working_directory": "/opt/trading",
    "startup_delay_ms": 0,
    "healthcheck": {
      "type": "process",
      "timeout_ms": 1000
    }
  },

  "project_25": {
    "name": "Market Maker (Disruptor Consumer)",
    "executable": "/opt/trading/bin/market_maker",
    "config_file": "/opt/trading/config/p25_config.json",
    "working_directory": "/opt/trading",
    "startup_delay_ms": 2000,
    "healthcheck": {
      "type": "process",
      "timeout_ms": 1000
    },
    "depends_on": ["project_24"]
  },

  "project_26": {
    "name": "Order Execution (Simulated Fills)",
    "executable": "/opt/trading/bin/order_execution_engine",
    "config_file": "/opt/trading/config/p26_config.json",
    "working_directory": "/opt/trading",
    "startup_delay_ms": 3000,
    "healthcheck": {
      "type": "process",
      "timeout_ms": 1000
    },
    "depends_on": ["project_25"]
  },

  "shared_memory": {
    "bbo_ring": {
      "path": "/dev/shm/bbo_ring_gateway",
      "size_bytes": 262144,
      "cleanup_on_start": true,
      "cleanup_on_stop": true
    },
    "order_ring": {
      "path": "/dev/shm/order_ring_mm",
      "size_bytes": 262144,
      "cleanup_on_start": true,
      "cleanup_on_stop": true
    },
    "fill_ring": {
      "path": "/dev/shm/fill_ring_oe",
      "size_bytes": 262144,
      "cleanup_on_start": true,
      "cleanup_on_stop": true
    }
  },

  "monitoring": {
    "orchestrator_prometheus_port": 9094,
    "enable_grafana_dashboard": false,
    "enable_alerts": false
  },

  "performance": {
    "enable_cpu_pinning": true,
    "cpu_affinity": {
      "project_24": [2, 3],
      "project_25": [4, 5],
      "project_26": [6, 7],
      "orchestrator": [0]
    },
    "enable_realtime_scheduling": true
  }
}
EOF

# Create systemd service for orchestrator
mkdir -p $OVERLAY/etc/systemd/system
cat > $OVERLAY/etc/systemd/system/trading-system.service << 'EOF'
[Unit]
Description=FPGA Trading System Orchestrator
After=network.target xdma.service nvidia-gpu.service
Requires=xdma.service
Wants=nvidia-gpu.service

[Service]
Type=simple
ExecStart=/opt/trading/bin/trading_system_orchestrator /opt/trading/config/system_config.json
ExecStop=/bin/kill -SIGTERM $MAINPID
WorkingDirectory=/opt/trading
Restart=on-failure
RestartSec=5
User=root

# Performance tuning
Nice=-20
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=90
LimitMEMLOCK=infinity
LimitRTPRIO=99

# Environment
Environment="LD_LIBRARY_PATH=/opt/cuda/lib64:/opt/xgboost/lib"
Environment="CUDA_VISIBLE_DEVICES=0"

[Install]
WantedBy=multi-user.target
EOF

# Enable service on boot
mkdir -p $OVERLAY/etc/systemd/system/multi-user.target.wants
ln -sf ../trading-system.service $OVERLAY/etc/systemd/system/multi-user.target.wants/trading-system.service

# Create LD_LIBRARY_PATH config for dynamic libraries
mkdir -p $OVERLAY/etc/ld.so.conf.d
echo "/opt/cuda/lib64" > $OVERLAY/etc/ld.so.conf.d/cuda.conf
echo "/opt/xgboost/lib" > $OVERLAY/etc/ld.so.conf.d/xgboost.conf

# Final rebuild
cd /work/tos/buildroot
make
```

### Directory Structure After All Phases

```
/work/tos/
├── buildroot/                          # Buildroot source
│   └── output/
│       ├── images/
│       │   ├── bzImage                 # Final kernel
│       │   ├── rootfs.iso9660          # Bootable ISO
│       │   ├── rootfs.ext4             # For NVMe install
│       │   └── rootfs.squashfs         # Compressed rootfs
│       └── build/
│           └── linux-6.12.x/           # Kernel source for module builds
│
├── trading-linux/
│   └── buildroot-external/             # Buildroot external tree
│       ├── Config.in
│       ├── external.mk
│       ├── external.desc
│       ├── configs/
│       │   └── trading_defconfig       # Main BR2_* config
│       └── board/trading/
│           ├── linux.config            # Kernel fragment
│           ├── busybox.config          # BusyBox config (optional)
│           ├── users.txt               # User table
│           ├── post-build.sh           # Post-build script
│           └── overlay/                # Copied into rootfs
│               ├── boot/grub/
│               │   └── grub.cfg
│               ├── lib/modules/        # NVIDIA, XDMA kernel modules
│               ├── etc/
│               │   ├── systemd/system/
│               │   │   ├── trading-system.service
│               │   │   └── xdma.service
│               │   ├── ld.so.conf.d/
│               │   │   ├── cuda.conf
│               │   │   └── xgboost.conf
│               │   ├── modprobe.d/
│               │   │   └── nvidia.conf
│               │   └── sudoers.d/
│               │       └── trading
│               └── opt/
│                   ├── cuda/           # CUDA 13.0 runtime libs
│                   ├── xgboost/        # XGBoost 3.2.0 library
│                   └── trading/
│                       ├── bin/
│                       │   ├── trading_system_orchestrator  # P28
│                       │   ├── order_gateway                # P24
│                       │   ├── market_maker                 # P25
│                       │   └── order_execution_engine       # P26
│                       ├── config/
│                       │   ├── system_config.json
│                       │   ├── p24_config.json
│                       │   ├── p25_config.json
│                       │   └── p26_config.json
│                       └── model/
│                           └── itch_predictor.ubj
│
├── cuda-extract/                       # Extracted CUDA 13.0 runfile
│   └── builds/                         # Runtime libs for XGBoost build
├── dma_ip_drivers/                     # XDMA driver source
└── xgboost/                            # XGBoost 3.2.0 source
```

### Target System Startup Flow

```
Boot
  │
  ▼
systemd
  │
  ├── xdma.service      → modprobe xdma
  ├── nvidia-gpu.service → modprobe nvidia
  │
  ▼
trading-system.service
  │
  ▼
trading_system_orchestrator (P28)
  │
  ├── 1. Cleanup stale shared memory
  ├── 2. Start order_gateway (P24)       ─── Waits for ready
  │      └── PCIe + XGBoost GPU
  ├── 3. Start market_maker (P25)        ─── Waits for P24
  │      └── Disruptor consumer
  └── 4. Start order_execution_engine (P26) ─── Waits for P25
         └── Simulated fills
  │
  ▼
System Running
  │
  Data Flow:
  FPGA → PCIe → P24 → Disruptor → P25 → Disruptor → P26 → Disruptor → P25
```

### Key Points

1. **Buildroot only builds open-source components** (kernel, busybox, systemd, etc.)
2. **Proprietary components (NVIDIA, CUDA) are added post-build** via overlays
3. **Kernel modules must be built against Buildroot's kernel source** (`output/build/linux-X.Y.Z/`)
4. **After modifying overlays, run `make` again** to regenerate rootfs
5. **CUDA 13.0 is REQUIRED** - CUDA 13.1 (CCCL 3.1.2) breaks XGBoost compilation
6. **Trading apps are cross-compiled** using Buildroot's toolchain
7. **Project 28 orchestrator starts everything** - single systemd service controls the entire trading system

### Manual Control (on target)

```bash
# Start trading system
sudo systemctl start trading-system

# Stop trading system
sudo systemctl stop trading-system

# View logs
sudo journalctl -u trading-system -f

# Check status
sudo systemctl status trading-system

# Prometheus metrics (when running)
curl http://localhost:9094/metrics
```

---

**Author**: for Adilson Dias
**Date**: December 2025
**Target**: Intel i9-14900KF + RTX 5090 + FPGA Trading System
